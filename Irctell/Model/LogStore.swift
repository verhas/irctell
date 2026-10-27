import Foundation
import Observation
import SQLite3

/// Every line of every conversation, kept in SQLite with a full-text index,
/// so a conversation's history is there after a restart, can be searched, and
/// private chats with a nick can be read across networks.
///
/// Used from the main actor only: a line is written as it is shown, which
/// for the volume of IRC takes well under a millisecond.
@MainActor
final class LogStore {
    /// Which lines a transcript shows.
    enum Scope: Hashable, Sendable {
        /// One conversation on one network.
        case buffer(network: UUID, key: String)
        /// The private chats on one network with any of the nicks, lowercased:
        /// one person's, under the nicks the user said are theirs.
        case query(network: UUID, nicks: [String])
        /// The private chats with any of the nicks, lowercased, on every network.
        case nicks([String])

        static func nick(_ nick: String) -> Scope { .nicks([nick.lowercased()]) }
    }

    private nonisolated(unsafe) var db: OpaquePointer?
    private nonisolated(unsafe) var insertStatement: OpaquePointer?
    private nonisolated(unsafe) var noteNickStatement: OpaquePointer?
    private let feeds = NSHashTable<AnyObject>.weakObjects()
    /// The newest row, for Clear.
    private(set) var lastInsertedID: Int64 = 0
    let fileURL: URL
    /// Changes when the log was changed underneath the transcripts -- an
    /// import -- so they read it again.
    let revision = LogRevision()
    /// While an import writes to the log: the lines to write after it.
    private var held: [(line: ChatLine, networkID: UUID, networkName: String, bufferName: String,
                        bufferKind: ChatBuffer.Kind)]?

    struct OpenError: Error, CustomStringConvertible {
        var description: String
    }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(db)
            db = nil
            throw OpenError(description: message)
        }
        // Another connection may be writing for a moment -- the maintenance
        // below, an import -- and a line must wait for it, not be lost.
        sqlite3_busy_timeout(db, 2_000)
        try execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS lines (
                id INTEGER PRIMARY KEY,
                network_id TEXT NOT NULL,
                network TEXT NOT NULL,
                buffer TEXT NOT NULL,
                buffer_kind TEXT NOT NULL,
                time REAL NOT NULL,
                kind TEXT NOT NULL,
                sender TEXT,
                text TEXT NOT NULL,
                is_self INTEGER NOT NULL DEFAULT 0,
                is_highlight INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS lines_by_buffer ON lines (network_id, buffer, id);
            CREATE INDEX IF NOT EXISTS lines_by_nick ON lines (buffer_kind, buffer, id);
            CREATE INDEX IF NOT EXISTS lines_highlighted ON lines (id) WHERE is_highlight = 1;

            CREATE VIRTUAL TABLE IF NOT EXISTS lines_fts USING fts5 (
                text, sender, content = 'lines', content_rowid = 'id',
                tokenize = 'unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS lines_indexed AFTER INSERT ON lines BEGIN
                INSERT INTO lines_fts (rowid, text, sender) VALUES (new.id, new.text, coalesce(new.sender, ''));
            END;
            """)
        // Added after the first version: logs from before have no such column.
        let columns = try query("PRAGMA table_info(lines)") { LogStore.text($0, 1) ?? "" }
        if !columns.contains("ignored") {
            try execute("ALTER TABLE lines ADD COLUMN ignored INTEGER NOT NULL DEFAULT 0")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS channel_lists (
                network_id TEXT PRIMARY KEY,
                fetched REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS listed_channels (
                network_id TEXT NOT NULL,
                name TEXT NOT NULL,
                users INTEGER NOT NULL,
                topic TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS listed_channels_by_network ON listed_channels (network_id);
            CREATE TABLE IF NOT EXISTS media (
                url TEXT PRIMARY KEY,
                mime TEXT,
                width INTEGER NOT NULL DEFAULT 0,
                height INTEGER NOT NULL DEFAULT 0,
                data BLOB,
                fetched REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS line_media (
                line_id INTEGER NOT NULL,
                url TEXT NOT NULL,
                collapsed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (line_id, url)
            );
            """)
        let mediaColumns = try query("PRAGMA table_info(line_media)") { LogStore.text($0, 1) ?? "" }
        if !mediaColumns.contains("display_width") {
            try execute("ALTER TABLE line_media ADD COLUMN display_width REAL")
        }
        // Every nick seen saying something, for completing nicks: kept by a
        // trigger, so lines written by the import scripts count too.
        let hadNicks = try query("SELECT 1 FROM sqlite_master WHERE name = 'nicks'") { _ in true }.isEmpty == false
        try execute("""
            CREATE TABLE IF NOT EXISTS nicks (
                nick TEXT PRIMARY KEY COLLATE NOCASE,
                last_seen REAL NOT NULL
            );
            CREATE TRIGGER IF NOT EXISTS lines_nick AFTER INSERT ON lines
            WHEN new.sender IS NOT NULL AND new.kind IN ('message', 'action', 'notice')
                 AND instr(new.sender, '.') = 0
            BEGIN
                INSERT INTO nicks (nick, last_seen) VALUES (new.sender, new.time)
                ON CONFLICT (nick) DO UPDATE SET last_seen = max(last_seen, excluded.last_seen);
            END;
            """)
        // Every nick seen on each network, with what is known of them: for
        // the private chat box, and for the people met over the years.
        let hadNetworkNicks = try query("SELECT 1 FROM sqlite_master WHERE name = 'network_nicks'") { _ in true }
            .isEmpty == false
        try execute("""
            CREATE TABLE IF NOT EXISTS network_nicks (
                network_id TEXT NOT NULL,
                nick TEXT NOT NULL COLLATE NOCASE,
                user TEXT,
                host TEXT,
                account TEXT,
                real_name TEXT,
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL,
                private_chat INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (network_id, nick)
            );
            """)
        noteNickStatement = try prepare("""
            INSERT INTO network_nicks (network_id, nick, user, host, account, real_name, first_seen, last_seen,
                                       private_chat)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (network_id, nick) DO UPDATE SET
                nick = excluded.nick,
                user = coalesce(excluded.user, user), host = coalesce(excluded.host, host),
                account = coalesce(excluded.account, account), real_name = coalesce(excluded.real_name, real_name),
                last_seen = max(last_seen, excluded.last_seen),
                private_chat = max(private_chat, excluded.private_chat)
            """)
        // A new log has no history to take nicks from.
        let hasLines = try query("SELECT 1 FROM lines LIMIT 1") { _ in true }.isEmpty == false
        LogStore.maintainInBackground(fileURL, fillNicks: !hadNicks,
                                      fillNetworkNicks: !hadNetworkNicks && hasLines)
        insertStatement = try prepare("""
            INSERT INTO lines (network_id, network, buffer, buffer_kind, time, kind, sender, text, is_self, is_highlight, ignored)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        lastInsertedID = try query("SELECT coalesce(max(id), 0) FROM lines") { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    /// Work on a large log that would hold up the start: done on a
    /// connection of its own, the app reading and writing meanwhile.
    private nonisolated static func maintainInBackground(_ fileURL: URL, fillNicks: Bool, fillNetworkNicks: Bool) {
        let path = fileURL.path
        Thread.detachNewThread {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close_v2(db) }
            sqlite3_busy_timeout(db, 10_000)
            sqlite3_exec(db, """
                CREATE INDEX IF NOT EXISTS lines_private ON lines (id)
                WHERE buffer_kind = 'query' AND is_self = 0 AND kind IN ('message', 'action', 'notice');
                """, nil, nil, nil)
            if fillNicks {
                // The nicks of a log from before the table existed.
                sqlite3_exec(db, """
                    INSERT INTO nicks (nick, last_seen)
                    SELECT sender, max(time) FROM lines
                    WHERE sender IS NOT NULL AND kind IN ('message', 'action', 'notice') AND instr(sender, '.') = 0
                    GROUP BY sender COLLATE NOCASE
                    ON CONFLICT (nick) DO UPDATE SET last_seen = max(last_seen, excluded.last_seen);
                    """, nil, nil, nil)
            }
            if fillNetworkNicks { fillNetworkNicksFromHistory(path) }
        }
    }

    /// The nicks of a log from before the table: everyone who said or did
    /// something, and everyone a private chat was had with. Read first, then
    /// written in small pieces: one statement doing both would hold the log's
    /// lock for the whole read, and new lines would wait for it.
    private nonisolated static func fillNetworkNicksFromHistory(_ path: String) {
        guard let db = try? SQLiteDatabase(path: path) else { return }
        struct Seen { var network: String, nick: String, first: Double, last: Double, privateChat: Bool }
        var seen: [Seen] = []
        try? db.forEach("""
            SELECT network_id, sender, min(time), max(time) FROM lines
            WHERE sender IS NOT NULL AND instr(sender, '.') = 0
              AND kind IN ('message', 'action', 'notice', 'join', 'part', 'quit', 'nick')
            GROUP BY network_id, sender COLLATE NOCASE
            """) { row in
            seen.append(Seen(network: SQLiteDatabase.text(row, 0) ?? "", nick: SQLiteDatabase.text(row, 1) ?? "",
                             first: sqlite3_column_double(row, 2), last: sqlite3_column_double(row, 3),
                             privateChat: false))
        }
        try? db.forEach("""
            SELECT network_id, buffer, min(time), max(time) FROM lines WHERE buffer_kind = 'query'
            GROUP BY network_id, buffer
            """) { row in
            seen.append(Seen(network: SQLiteDatabase.text(row, 0) ?? "", nick: SQLiteDatabase.text(row, 1) ?? "",
                             first: sqlite3_column_double(row, 2), last: sqlite3_column_double(row, 3),
                             privateChat: true))
        }
        guard let insert = try? db.prepare("""
            INSERT INTO network_nicks (network_id, nick, first_seen, last_seen, private_chat) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (network_id, nick) DO UPDATE SET
                first_seen = min(first_seen, excluded.first_seen), last_seen = max(last_seen, excluded.last_seen),
                private_chat = max(private_chat, excluded.private_chat)
            """) else { return }
        defer { sqlite3_finalize(insert) }
        for start in stride(from: 0, to: seen.count, by: 2_000) {
            guard (try? db.execute("BEGIN IMMEDIATE")) != nil else { return }
            for entry in seen[start..<min(start + 2_000, seen.count)] where !entry.nick.isEmpty {
                db.bind(insert, [entry.network, entry.nick, entry.first, entry.last, entry.privateChat])
                try? db.step(insert)
            }
            try? db.execute("COMMIT")
        }
        AppLog.info("log", "\(seen.count) nicks taken from the history into the nick list")
    }

    deinit {
        sqlite3_finalize(insertStatement)
        sqlite3_finalize(noteNickStatement)
        sqlite3_close_v2(db)
    }

    /// The log in Irctell's home, or nil -- logged -- when it cannot be opened.
    /// A restore asked for last time is done first.
    static func openStandard() -> LogStore? {
        LogStore.restorePendingBackup()
        do {
            return try LogStore(fileURL: IrctellHome.logFile)
        } catch {
            AppLog.error("log", "no message log: \(error)")
            return nil
        }
    }

    /// The name a buffer is filed under: case-folded, and empty for the
    /// server's own messages.
    static func key(for name: String, kind: ChatBuffer.Kind) -> String {
        kind == .server ? "" : name.lowercased()
    }

    // MARK: - Writing

    /// Writes the line and hands it, with its row, to the transcripts showing
    /// that conversation. Returns the line as written.
    @discardableResult
    func append(_ line: ChatLine, networkID: UUID, networkName: String,
                bufferName: String, bufferKind: ChatBuffer.Kind) -> ChatLine {
        guard let statement = insertStatement else { return line }
        if held != nil {
            held?.append((line, networkID, networkName, bufferName, bufferKind))
            return line
        }
        let key = LogStore.key(for: bufferName, kind: bufferKind)
        sqlite3_reset(statement)
        bind(statement, 1, networkID.uuidString)
        bind(statement, 2, networkName)
        bind(statement, 3, key)
        bind(statement, 4, bufferKind.rawValue)
        sqlite3_bind_double(statement, 5, line.time.timeIntervalSince1970)
        bind(statement, 6, line.kind.rawValue)
        bind(statement, 7, line.sender)
        bind(statement, 8, line.text)
        sqlite3_bind_int(statement, 9, line.isSelf ? 1 : 0)
        sqlite3_bind_int(statement, 10, line.isHighlight ? 1 : 0)
        sqlite3_bind_int(statement, 11, line.isIgnored ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            AppLog.error("log", "could not log a line: \(errorMessage)")
            return line
        }
        var logged = line
        logged.logID = sqlite3_last_insert_rowid(db)
        logged.network = networkName
        lastInsertedID = logged.logID ?? lastInsertedID
        for case let feed as LogSubscriber in feeds.allObjects {
            feed.logged(logged, networkID: networkID, key: key, kind: bufferKind)
        }
        return logged
    }

    func subscribe(_ feed: LogSubscriber) {
        feeds.add(feed)
    }

    // MARK: - Imports

    /// Holds the lines coming in while an import writes to the log on a
    /// connection of its own; they are written after it.
    func holdWrites() {
        if held == nil { held = [] }
    }

    /// Writes the lines held meanwhile, and has the transcripts read the
    /// log again.
    func resumeWrites() {
        let waiting = held ?? []
        held = nil
        lastInsertedID = (try? query("SELECT coalesce(max(id), 0) FROM lines") { sqlite3_column_int64($0, 0) }.first)
            ?? lastInsertedID
        revision.value += 1
        for entry in waiting {
            append(entry.line, networkID: entry.networkID, networkName: entry.networkName,
                   bufferName: entry.bufferName, bufferKind: entry.bufferKind)
        }
    }

    // MARK: - Backup

    /// Copies the whole log to `destination`, consistent as of one moment,
    /// on a connection of its own: lines go on being written meanwhile.
    nonisolated static func backUp(_ source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let db = try SQLiteDatabase(path: source.path, readOnly: true)
        try db.run("VACUUM INTO ?", [temporary.path])
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// Whether the file is an Irctell log that is in one piece; the reason
    /// it cannot be used when not.
    nonisolated static func checkBackup(_ file: URL) -> String? {
        do {
            let db = try SQLiteDatabase(path: file.path, readOnly: true)
            let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'") {
                SQLiteDatabase.text($0, 0) ?? ""
            }
            guard tables.contains("lines") else { return "\(file.lastPathComponent) is not an Irctell log." }
            let check = try db.query("PRAGMA quick_check") { SQLiteDatabase.text($0, 0) ?? "" }
            guard check == ["ok"] else { return "\(file.lastPathComponent) is damaged: \(check.prefix(3).joined(separator: "; "))" }
            return nil
        } catch {
            return "\(file.lastPathComponent) cannot be read: \(error.localizedDescription)"
        }
    }

    /// Where the backup to restore at the next launch is named.
    nonisolated static var pendingRestoreFile: URL { IrctellHome.directory.appending(path: "restore-log-from") }

    /// Puts the backup in place of the log at the next launch: the log in use
    /// cannot be swapped under the running app.
    nonisolated static func restoreAtNextLaunch(_ backup: URL) throws {
        try FileManager.default.createDirectory(at: IrctellHome.directory, withIntermediateDirectories: true)
        try backup.path.write(to: pendingRestoreFile, atomically: true, encoding: .utf8)
    }

    /// The restore asked for: the log so far is kept beside it, renamed.
    nonisolated static func restorePendingBackup(log: URL = IrctellHome.logFile) {
        let marker = pendingRestoreFile
        guard let path = try? String(contentsOf: marker, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: marker)
        let backup = URL(filePath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        guard checkBackup(backup) == nil else {
            AppLog.error("log", "not restoring \(backup.path): \(checkBackup(backup) ?? "")")
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: .now)
        let manager = FileManager.default
        var setAside: [(URL, URL)] = []
        for suffix in ["", "-wal", "-shm"] {
            let current = URL(filePath: log.path + suffix)
            guard manager.fileExists(atPath: current.path) else { continue }
            let kept = URL(filePath: log.path + ".before-restore-\(stamp)" + suffix)
            do {
                try manager.moveItem(at: current, to: kept)
                setAside.append((current, kept))
            } catch {
                AppLog.error("log", "could not set the log aside for the restore: \(error)")
                for (current, kept) in setAside { try? manager.moveItem(at: kept, to: current) }
                return
            }
        }
        do {
            try manager.copyItem(at: backup, to: log)
        } catch {
            AppLog.error("log", "could not restore \(backup.path): \(error)")
            try? manager.removeItem(at: log)
            for (current, kept) in setAside { try? manager.moveItem(at: kept, to: current) }
        }
    }

    // MARK: - Reading

    /// The newest `limit` lines of the scope older than `before` and newer
    /// than `after`, oldest first; with `search`, only those matching it.
    /// With `oldestFirst`, the oldest `limit` of them instead; with `since`,
    /// only those from that time on.
    func lines(in scope: Scope, matching search: String? = nil, before: Int64? = nil, after: Int64? = nil,
               since: Date? = nil, oldestFirst: Bool = false,
               ignoring ignores: [IgnoreRule] = [], limit: Int) -> [ChatLine] {
        var sql = "SELECT l.id, l.network, l.time, l.kind, l.sender, l.text, l.is_self, l.is_highlight, l.ignored FROM lines l"
        var conditions: [String] = []
        var arguments: [Any] = []
        if let search, let match = LogStore.ftsQuery(search) {
            sql += " JOIN lines_fts f ON f.rowid = l.id"
            conditions.append("lines_fts MATCH ?")
            arguments.append(match)
        }
        LogStore.limit(to: scope, conditions: &conditions, arguments: &arguments)
        if let before {
            conditions.append("l.id < ?")
            arguments.append(before)
        }
        if let after {
            conditions.append("l.id > ?")
            arguments.append(after)
        }
        if let since {
            conditions.append("l.time >= ?")
            arguments.append(since.timeIntervalSince1970)
        }
        LogStore.exclude(ignores, conditions: &conditions, arguments: &arguments)
        sql += " WHERE " + conditions.joined(separator: " AND ")
            + (oldestFirst ? " ORDER BY l.id ASC LIMIT ?" : " ORDER BY l.id DESC LIMIT ?")
        arguments.append(Int64(limit))

        let rows = (try? query(sql, arguments) { (row: OpaquePointer) -> ChatLine in
            var line = LogStore.line(from: row)
            line.logID = sqlite3_column_int64(row, 0)
            return line
        }) ?? []
        return oldestFirst ? rows : Array(rows.reversed())
    }

    /// When the scope's first and last lines were written; nil for none.
    func timeSpan(of scope: Scope) -> ClosedRange<Date>? {
        guard let first = lines(in: scope, oldestFirst: true, limit: 1).first?.time,
              let last = lines(in: scope, limit: 1).first?.time else { return nil }
        return first...max(first, last)
    }

    /// The mentions on every network, newest first, older than `before`;
    /// with `privateMessages`, also what others wrote in private chats. Two
    /// queries, each on its own index, merged: one query with an OR reads the
    /// whole log.
    func mentions(includingPrivateMessages privateMessages: Bool, matching search: String? = nil,
                  before: Int64? = nil, ignoring ignores: [IgnoreRule] = [], limit: Int) -> [Mention] {
        var found = mentions(where: "l.is_highlight = 1", matching: search, before: before, ignoring: ignores, limit: limit)
        if privateMessages {
            found += mentions(where: LogStore.privateMessage, matching: search, before: before, ignoring: ignores,
                              limit: limit)
            found.sort { $0.id > $1.id }
            var seen = Set<Int64>()
            found = found.filter { seen.insert($0.id).inserted }
        }
        return Array(found.prefix(limit))
    }

    private static let privateMessage =
        "l.buffer_kind = 'query' AND l.is_self = 0 AND l.kind IN ('message', 'action', 'notice')"

    private func mentions(where condition: String, matching search: String?, before: Int64?,
                          ignoring ignores: [IgnoreRule], limit: Int) -> [Mention] {
        var sql = """
            SELECT l.id, l.network, l.time, l.kind, l.sender, l.text, l.is_self, l.is_highlight, l.ignored,
                   l.network_id, l.buffer, l.buffer_kind FROM lines l
            """
        var conditions: [String] = []
        var arguments: [Any] = []
        if let search, let match = LogStore.ftsQuery(search) {
            sql += " JOIN lines_fts f ON f.rowid = l.id"
            conditions.append("lines_fts MATCH ?")
            arguments.append(match)
        }
        conditions.append(condition)
        if let before {
            conditions.append("l.id < ?")
            arguments.append(before)
        }
        LogStore.exclude(ignores, conditions: &conditions, arguments: &arguments)
        sql += " WHERE " + conditions.joined(separator: " AND ") + " ORDER BY l.id DESC LIMIT ?"
        arguments.append(Int64(limit))
        return (try? query(sql, arguments) { (row: OpaquePointer) -> Mention in
            var line = LogStore.line(from: row)
            line.logID = sqlite3_column_int64(row, 0)
            return Mention(line: line,
                           networkID: LogStore.text(row, 9).flatMap(UUID.init(uuidString:)) ?? UUID(),
                           bufferKey: LogStore.text(row, 10) ?? "",
                           bufferKind: ChatBuffer.Kind(rawValue: LogStore.text(row, 11) ?? "") ?? .channel)
        }) ?? []
    }


    private static func line(from row: OpaquePointer) -> ChatLine {
        var line = ChatLine(time: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                            kind: ChatLine.Kind(rawValue: text(row, 3) ?? "") ?? .info,
                            sender: text(row, 4),
                            text: text(row, 5) ?? "",
                            isSelf: sqlite3_column_int(row, 6) != 0,
                            isHighlight: sqlite3_column_int(row, 7) != 0)
        line.network = text(row, 1)
        line.isIgnored = sqlite3_column_int(row, 8) != 0
        return line
    }

    /// Leaves out the lines logged as ignored whose sender is still ignored
    /// there; once the ignore is taken off, they are shown.
    private static func exclude(_ ignores: [IgnoreRule], conditions: inout [String], arguments: inout [Any]) {
        guard !ignores.isEmpty else { return }
        var terms: [String] = []
        for rule in ignores {
            var term = "lower(l.sender) = ?"
            arguments.append(rule.nick)
            if let network = rule.network {
                term += " AND l.network_id = ?"
                arguments.append(network.uuidString)
            }
            if rule.privateOnly { term += " AND l.buffer_kind = 'query'" }
            terms.append("(\(term))")
        }
        conditions.append("NOT (l.ignored = 1 AND (\(terms.joined(separator: " OR "))))")
    }

    private static func limit(to scope: Scope, conditions: inout [String], arguments: inout [Any]) {
        switch scope {
        case .buffer(let network, let key):
            conditions.append("l.network_id = ? AND l.buffer = ?")
            arguments += [network.uuidString, key]
        case .query(let network, let nicks):
            conditions.append("l.network_id = ? AND l.buffer_kind = 'query' AND l.buffer IN (\(LogStore.placeholders(nicks)))")
            arguments += [network.uuidString] + nicks
        case .nicks(let nicks):
            conditions.append("l.buffer_kind = 'query' AND l.buffer IN (\(LogStore.placeholders(nicks)))")
            arguments += nicks
        }
    }

    // MARK: - Pictures

    /// The lines of a conversation that may hold a web link, oldest first,
    /// after the row `after`; ignored lines left out.
    func linkLines(in scope: Scope, after: Int64? = nil, limit: Int) -> [(id: Int64, text: String)] {
        var conditions = ["l.text LIKE '%http%'", "l.ignored = 0"]
        var arguments: [Any] = []
        LogStore.limit(to: scope, conditions: &conditions, arguments: &arguments)
        if let after {
            conditions.append("l.id > ?")
            arguments.append(after)
        }
        arguments.append(Int64(limit))
        return (try? query("SELECT l.id, l.text FROM lines l WHERE " + conditions.joined(separator: " AND ")
                           + " ORDER BY l.id ASC LIMIT ?", arguments) { row in
            (id: sqlite3_column_int64(row, 0), text: LogStore.text(row, 1) ?? "")
        }) ?? []
    }

    /// A downloaded link: a picture with its bytes, or -- without data -- a
    /// link that turned out not to be one, so it is not fetched again.
    struct MediaRecord: Sendable {
        var url: String
        var mime: String?
        var width: Int
        var height: Int
        var data: Data?
        var isPicture: Bool { data != nil }
    }

    /// The network a logged line came on.
    func networkID(ofLine id: Int64) -> UUID? {
        (try? query("SELECT network_id FROM lines WHERE id = ?", [id]) { row in
            LogStore.text(row, 0).flatMap(UUID.init(uuidString:))
        })?.first ?? nil
    }

    func media(_ url: String) -> MediaRecord? {
        try? query("SELECT url, mime, width, height, data FROM media WHERE url = ?", [url]) { row in
            let data = sqlite3_column_blob(row, 4).map {
                Data(bytes: $0, count: Int(sqlite3_column_bytes(row, 4)))
            }
            return MediaRecord(url: LogStore.text(row, 0) ?? url, mime: LogStore.text(row, 1),
                               width: Int(sqlite3_column_int64(row, 2)), height: Int(sqlite3_column_int64(row, 3)),
                               data: data)
        }.first
    }

    func saveMedia(_ record: MediaRecord) {
        guard let statement = try? prepare("""
            INSERT OR REPLACE INTO media (url, mime, width, height, data, fetched) VALUES (?, ?, ?, ?, ?, ?)
            """) else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, record.url)
        bind(statement, 2, record.mime)
        sqlite3_bind_int64(statement, 3, Int64(record.width))
        sqlite3_bind_int64(statement, 4, Int64(record.height))
        if let data = record.data {
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(bytes.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            sqlite3_bind_null(statement, 5)
        }
        sqlite3_bind_double(statement, 6, Date.now.timeIntervalSince1970)
        if sqlite3_step(statement) != SQLITE_DONE { AppLog.error("log", "could not save a picture: \(errorMessage)") }
    }

    /// The pictures shown under a line, in the order they were linked.
    func lineMedia(_ lineID: Int64) -> [(url: String, collapsed: Bool, width: Double?)] {
        (try? query("SELECT url, collapsed, display_width FROM line_media WHERE line_id = ? ORDER BY rowid",
                    [lineID]) { row in
            (url: LogStore.text(row, 0) ?? "", collapsed: sqlite3_column_int(row, 1) != 0,
             width: sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : sqlite3_column_double(row, 2))
        }) ?? []
    }

    /// The width the user dragged a picture to.
    func setMediaWidth(line lineID: Int64, url: String, width: Double) {
        _ = try? query("UPDATE line_media SET display_width = ? WHERE line_id = ? AND url = ?",
                       [width, lineID, url]) { _ in () }
    }

    func linkMedia(line lineID: Int64, url: String, collapsed: Bool) {
        _ = try? query("INSERT OR IGNORE INTO line_media (line_id, url, collapsed) VALUES (?, ?, ?)",
                       [lineID, url, Int64(collapsed ? 1 : 0)]) { _ in () }
    }

    func setMediaCollapsed(line lineID: Int64, url: String, collapsed: Bool) {
        _ = try? query("UPDATE line_media SET collapsed = ? WHERE line_id = ? AND url = ?",
                       [Int64(collapsed ? 1 : 0), lineID, url]) { _ in () }
    }

    // MARK: - Nicks

    /// A nick seen on a network, with what came with it.
    struct SeenNick: Sendable, Equatable {
        var nick: String
        var user: String?
        var host: String?
        var account: String?
        var realName: String?
    }

    /// A nick of the network's list.
    struct KnownNick: Sendable, Equatable {
        var nick: String
        var lastSeen: Date
        /// Whether there was a private chat with them.
        var hadPrivateChat: Bool
    }

    /// Notes the nicks as seen now: added to the network's list, or brought
    /// up to date. Many at once in one transaction, as a channel's list comes.
    func noteNicks(_ nicks: [SeenNick], network: UUID, privateChat: Bool = false, time: Date = .now) {
        guard let statement = noteNickStatement, !nicks.isEmpty else { return }
        let many = nicks.count > 1
        if many { try? execute("BEGIN") }
        for seen in nicks where !seen.nick.isEmpty {
            sqlite3_reset(statement)
            bind(statement, 1, network.uuidString)
            bind(statement, 2, seen.nick)
            bind(statement, 3, seen.user)
            bind(statement, 4, seen.host)
            bind(statement, 5, seen.account)
            bind(statement, 6, seen.realName)
            sqlite3_bind_double(statement, 7, time.timeIntervalSince1970)
            sqlite3_bind_double(statement, 8, time.timeIntervalSince1970)
            sqlite3_bind_int(statement, 9, privateChat ? 1 : 0)
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLog.error("log", "could not note a nick: \(errorMessage)")
            }
        }
        if many { try? execute("COMMIT") }
    }

    /// The network's nicks starting with `prefix`, the most recently seen
    /// first.
    func knownNicks(network: UUID, startingWith prefix: String, limit: Int) -> [KnownNick] {
        guard !prefix.isEmpty else { return [] }
        let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return (try? query("""
            SELECT nick, last_seen, private_chat FROM network_nicks
            WHERE network_id = ? AND nick LIKE ? ESCAPE '\\' ORDER BY last_seen DESC LIMIT ?
            """, [network.uuidString, escaped + "%", Int64(limit)]) { row in
            KnownNick(nick: LogStore.text(row, 0) ?? "", lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                      hadPrivateChat: sqlite3_column_int(row, 2) != 0)
        }) ?? []
    }

    /// The network's nicks, the most recently seen first.
    func recentNicks(network: UUID, limit: Int) -> [KnownNick] {
        (try? query("""
            SELECT nick, last_seen, private_chat FROM network_nicks WHERE network_id = ?
            ORDER BY last_seen DESC LIMIT ?
            """, [network.uuidString, Int64(limit)]) { row in
            KnownNick(nick: LogStore.text(row, 0) ?? "", lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                      hadPrivateChat: sqlite3_column_int(row, 2) != 0)
        }) ?? []
    }

    /// What is known of a nick on the network.
    func knownNick(_ nick: String, network: UUID) -> (seen: SeenNick, firstSeen: Date, lastSeen: Date)? {
        (try? query("""
            SELECT nick, user, host, account, real_name, first_seen, last_seen FROM network_nicks
            WHERE network_id = ? AND nick = ?
            """, [network.uuidString, nick]) { row in
            (SeenNick(nick: LogStore.text(row, 0) ?? nick, user: LogStore.text(row, 1), host: LogStore.text(row, 2),
                      account: LogStore.text(row, 3), realName: LogStore.text(row, 4)),
             Date(timeIntervalSince1970: sqlite3_column_double(row, 5)),
             Date(timeIntervalSince1970: sqlite3_column_double(row, 6)))
        })?.first
    }

    /// Nicks seen in the log starting with `prefix`, the most recently seen
    /// first.
    func nicks(startingWith prefix: String, limit: Int) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return (try? query("""
            SELECT nick FROM nicks WHERE nick LIKE ? ESCAPE '\\' ORDER BY last_seen DESC LIMIT ?
            """, [escaped + "%", Int64(limit)]) { LogStore.text($0, 0) ?? "" }) ?? []
    }

    /// Nicks seen in the log containing `text`, the most recently seen first.
    func nicks(containing text: String, limit: Int) -> [String] {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return (try? query("""
            SELECT nick FROM nicks WHERE nick LIKE ? ESCAPE '\\' ORDER BY last_seen DESC LIMIT ?
            """, ["%" + escaped + "%", Int64(limit)]) { LogStore.text($0, 0) ?? "" }) ?? []
    }

    private static func placeholders(_ values: [String]) -> String {
        Array(repeating: "?", count: max(values.count, 1)).joined(separator: ", ")
    }

    // MARK: - Channel lists

    /// Replaces the network's saved channel list.
    func saveChannelList(_ channels: [ListedChannel], network: UUID, fetched: Date) {
        do {
            try execute("BEGIN")
            _ = try query("DELETE FROM listed_channels WHERE network_id = ?", [network.uuidString]) { _ in () }
            let insert = try prepare("INSERT INTO listed_channels (network_id, name, users, topic) VALUES (?, ?, ?, ?)")
            defer { sqlite3_finalize(insert) }
            for channel in channels {
                guard let insert else { break }
                sqlite3_reset(insert)
                bind(insert, 1, network.uuidString)
                bind(insert, 2, channel.name)
                sqlite3_bind_int64(insert, 3, Int64(channel.users))
                bind(insert, 4, channel.topic)
                sqlite3_step(insert)
            }
            _ = try query("INSERT OR REPLACE INTO channel_lists (network_id, fetched) VALUES (?, ?)",
                          [network.uuidString, fetched.timeIntervalSince1970]) { _ in () }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            AppLog.error("log", "could not save the channel list: \(error)")
        }
    }

    /// The network's channel list as last fetched, and when.
    func savedChannelList(network: UUID) -> (channels: [ListedChannel], fetched: Date)? {
        guard let fetched = try? query("SELECT fetched FROM channel_lists WHERE network_id = ?", [network.uuidString],
                                       row: { Date(timeIntervalSince1970: sqlite3_column_double($0, 0)) }).first
        else { return nil }
        let channels = (try? query("SELECT name, users, topic FROM listed_channels WHERE network_id = ?",
                                   [network.uuidString]) { row in
            ListedChannel(name: LogStore.text(row, 0) ?? "", users: Int(sqlite3_column_int64(row, 1)),
                          topic: LogStore.text(row, 2) ?? "")
        }) ?? []
        return (channels, fetched)
    }

    /// Whether the logged line matches a search, for lines coming in while
    /// a search is shown.
    func line(_ id: Int64, matches search: String) -> Bool {
        guard let match = LogStore.ftsQuery(search) else { return true }
        let found = try? query("SELECT 1 FROM lines_fts WHERE rowid = ? AND lines_fts MATCH ?", [id, match]) { _ in true }
        return found?.isEmpty == false
    }

    /// What the user typed as an FTS5 query: every word must be there, as a
    /// word or the start of one. Quoting each keeps FTS5's own syntax --
    /// AND, NEAR, column filters -- from being triggered by accident.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - SQLite

    private var errorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw OpenError(description: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw OpenError(description: errorMessage)
        }
        return statement
    }

    private func query<T>(_ sql: String, _ arguments: [Any] = [], row: (OpaquePointer) -> T) throws -> [T] {
        guard let statement = try prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case let value as Int64: sqlite3_bind_int64(statement, position, value)
            case let value as String: bind(statement, position, value)
            case let value as Double: sqlite3_bind_double(statement, position, value)
            default: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(row(statement))
        }
        return rows
    }

    /// SQLite copies the text (SQLITE_TRANSIENT), as the Swift string's
    /// buffer does not outlive the call.
    private func bind(_ statement: OpaquePointer, _ position: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, position)
            return
        }
        sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }
}

/// Told of every line as it is written.
@MainActor
protocol LogSubscriber: AnyObject {
    func logged(_ line: ChatLine, networkID: UUID, key: String, kind: ChatBuffer.Kind)
}

/// A mention, or a private message, with where it was.
struct Mention: Identifiable, Hashable, Sendable {
    var line: ChatLine
    var networkID: UUID
    /// The conversation's name, case-folded as the log keeps it; empty for
    /// the server's own messages.
    var bufferKey: String
    var bufferKind: ChatBuffer.Kind
    var id: Int64 { line.logID ?? 0 }

    var isPrivateMessage: Bool { bufferKind == .query && !line.isHighlight }
}

/// Bumped when the log changed underneath what is shown.
@MainActor @Observable
final class LogRevision {
    var value = 0
}
