import CryptoKit
import Foundation
import SQLite3

/// What an archive can carry, each chosen on export and on import.
enum ArchivePart: String, Codable, CaseIterable, Identifiable, Sendable {
    case messages, pictures, networks, general, highlights, speech, autoReplies, people, sounds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "Messages"
        case .pictures: "Pictures"
        case .networks: "Networks"
        case .general: "General settings"
        case .highlights: "Highlights and ignores"
        case .speech: "Speech"
        case .autoReplies: "Auto replies"
        case .people: "People"
        case .sounds: "Your sounds"
        }
    }

    var detail: String {
        switch self {
        case .messages: "Every conversation in the log"
        case .pictures: "The pictures downloaded from links"
        case .networks: "Servers, nicks, channels, startup commands; never passwords"
        case .general: "Identity, notifications, pictures, away and the rest of Settings"
        case .highlights: "Highlight words and patterns, ignored nicks"
        case .speech: "Voices, voices per nick, spoken abbreviations, laughs as sounds"
        case .autoReplies: "Automatic replies and when they are sent"
        case .people: "Nicks grouped as one person"
        case .sounds: "The sounds in \(IrctellHome.displayPath)/sounds"
        }
    }

    /// The settings that are not a part of their own: window state, and
    /// what only makes sense on the Mac it was saved on.
    static let unexportedSettings: Set<String> = ["openNetworks", "openBuffers", "addedKnownNetworks"]

    /// The part a setting belongs to; nil for one that is not exported.
    static func part(forSetting key: String) -> ArchivePart? {
        if unexportedSettings.contains(key) { return nil }
        if key.hasPrefix("highlight.") { return .highlights }
        if key.hasPrefix("speech.") { return .speech }
        if key.hasPrefix("autoReply.") { return .autoReplies }
        if key == "people" { return .people }
        return .general
    }

    static let settingsParts: [ArchivePart] = [.general, .highlights, .speech, .autoReplies, .people]
}

/// `manifest.json`: what the archive is, and what it holds.
struct ArchiveManifest: Codable, Sendable {
    static let formatName = "irctell-archive"
    static let currentVersion = 1

    var format = ArchiveManifest.formatName
    var version = ArchiveManifest.currentVersion
    var app: String
    var exportedAt: Date
    /// Per part, how many: lines, pictures, networks, settings, sound files.
    var contents: [String: Int]
}

/// One entry of `conversations.json`: a conversation, and the file its
/// lines are in.
struct ArchiveConversation: Codable, Sendable {
    var file: String
    var networkID: UUID
    var network: String
    /// The network's server, to find it on a Mac where it has another ID.
    var host: String?
    /// The name it is filed under: lowercased, empty for the server's lines.
    var buffer: String
    var kind: String
    var lines: Int
    var first: Date?
    var last: Date?
}

/// What an import did.
struct ArchiveImportResult: Sendable {
    var linesAdded = 0
    var linesAlreadyThere = 0
    var picturesAdded = 0
    var networksAdded: [String] = []
    var settingsImported = 0
    var soundsAdded = 0
    /// Old log row → new one, when the log was renumbered to keep its lines
    /// in time order.
    var renumbered: [Int64: Int64] = [:]
}

/// The archive: a zip of JSON Lines, one file per conversation, with the
/// pictures, the network list and the settings beside them.
///
///     manifest.json
///     conversations.json        which file is which conversation
///     lines/<network>/<conversation>.jsonl
///     media/index.jsonl, media/<sha256>.<ext>
///     networks.json             without passwords
///     settings/<part>.plist
///     sounds/<kind>/<file>
enum LogArchive {
    typealias Progress = @Sendable (String) -> Void

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    // MARK: - Export

    struct ExportInput: Sendable {
        var logPath: String?
        var parts: Set<ArchivePart>
        /// The network list as JSON, and the networks' names by ID.
        var networks: Data?
        var networkNames: [UUID: String] = [:]
        var networkHosts: [UUID: String] = [:]
        var networkCount = 0
        /// Each settings part as an XML property list, and how many settings.
        var settings: [ArchivePart: Data] = [:]
        var settingsCounts: [ArchivePart: Int] = [:]
        var soundsDirectory: URL?
    }

    /// Writes the archive. Reads the log in one snapshot: lines written
    /// meanwhile wait for the next export.
    static func export(_ input: ExportInput, to destination: URL, progress: Progress) throws -> ArchiveManifest {
        // Written beside the destination, and put in its place when done:
        // a failed export leaves what was there.
        let partial = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        let zip = try ZipWriter(url: partial)
        var contents: [String: Int] = [:]

        if let logPath = input.logPath,
           input.parts.contains(.messages) || input.parts.contains(.pictures) {
            let db = try SQLiteDatabase(path: logPath, readOnly: true)
            try db.execute("BEGIN")
            defer { try? db.execute("COMMIT") }
            if input.parts.contains(.messages) {
                contents[ArchivePart.messages.rawValue] = try exportLines(db, names: input.networkNames,
                                                                          hosts: input.networkHosts, to: zip,
                                                                          progress: progress)
            }
            if input.parts.contains(.pictures) {
                progress("Writing the pictures…")
                contents[ArchivePart.pictures.rawValue] = try exportMedia(db, to: zip)
            }
        }
        if input.parts.contains(.networks), let networks = input.networks {
            try zip.add("networks.json", data: networks)
            contents[ArchivePart.networks.rawValue] = input.networkCount
        }
        for part in ArchivePart.settingsParts where input.parts.contains(part) {
            guard let data = input.settings[part] else { continue }
            try zip.add("settings/\(part.rawValue).plist", data: data)
            contents[part.rawValue] = input.settingsCounts[part] ?? 0
        }
        if input.parts.contains(.sounds), let sounds = input.soundsDirectory {
            contents[ArchivePart.sounds.rawValue] = try addFiles(from: sounds, as: "sounds", to: zip)
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        // A part with nothing in it is not offered on import.
        let manifest = ArchiveManifest(app: "Irctell \(version)", exportedAt: .now,
                                       contents: contents.filter { $0.value > 0 })
        try zip.add("manifest.json", data: encoder.encode(manifest))
        try zip.finish()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        return manifest
    }

    private static func exportLines(_ db: SQLiteDatabase, names: [UUID: String], hosts: [UUID: String], to zip: ZipWriter,
                                    progress: Progress) throws -> Int {
        progress("Reading the log…")
        // The pictures under each line, read at once: there are few.
        var media: [Int64: [(url: String, collapsed: Bool, width: Double?)]] = [:]
        try db.forEach("SELECT line_id, url, collapsed, display_width FROM line_media ORDER BY rowid") { row in
            media[sqlite3_column_int64(row, 0), default: []].append(
                (SQLiteDatabase.text(row, 1) ?? "", sqlite3_column_int(row, 2) != 0,
                 SQLiteDatabase.isNull(row, 3) ? nil : sqlite3_column_double(row, 3)))
        }
        struct Group { var networkID: String, buffer: String, kind: String, count: Int, first: Double, last: Double,
                       network: String }
        let groups = try db.query("""
            SELECT network_id, buffer, buffer_kind, count(*), min(time), max(time), max(network)
            FROM lines GROUP BY network_id, buffer, buffer_kind ORDER BY network_id, buffer
            """) { row in
            Group(networkID: SQLiteDatabase.text(row, 0) ?? "", buffer: SQLiteDatabase.text(row, 1) ?? "",
                  kind: SQLiteDatabase.text(row, 2) ?? "channel", count: Int(sqlite3_column_int64(row, 3)),
                  first: sqlite3_column_double(row, 4), last: sqlite3_column_double(row, 5),
                  network: SQLiteDatabase.text(row, 6) ?? "")
        }
        let total = groups.reduce(0) { $0 + $1.count }
        var written = 0
        var conversations: [ArchiveConversation] = []
        var folders: [String: String] = [:] // network ID → folder
        var usedFolders = Set<String>()
        var usedFiles = Set<String>()
        let statement = try db.prepare("""
            SELECT id, time, kind, sender, text, is_self, is_highlight, ignored, network FROM lines
            WHERE network_id = ? AND buffer = ? AND buffer_kind = ? ORDER BY id
            """)
        defer { sqlite3_finalize(statement) }

        for group in groups {
            let networkID = UUID(uuidString: group.networkID) ?? UUID()
            let networkName = names[networkID] ?? group.network
            let folder = folders[group.networkID] ?? {
                let folder = unique(safeName(networkName.isEmpty ? group.networkID : networkName), in: &usedFolders,
                                    suffix: String(group.networkID.prefix(8)))
                folders[group.networkID] = folder
                return folder
            }()
            let base = group.kind == "server" ? "(server)" : (group.kind == "query" ? "@" : "") + group.buffer
            let file = "lines/\(folder)/" + unique(safeName(base), in: &usedFiles, prefix: "\(folder)/",
                                                   suffix: group.kind) + ".jsonl"
            let writer = try LineWriter(zip: zip, name: file)

            db.bind(statement, [group.networkID, group.buffer, group.kind])
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                var json = JSONLine()
                json.add("time", time: sqlite3_column_double(statement, 1))
                json.add("kind", SQLiteDatabase.text(statement, 2) ?? "info")
                if let sender = SQLiteDatabase.text(statement, 3) { json.add("sender", sender) }
                json.add("text", SQLiteDatabase.text(statement, 4) ?? "")
                if sqlite3_column_int(statement, 5) != 0 { json.add("self", true) }
                if sqlite3_column_int(statement, 6) != 0 { json.add("highlight", true) }
                if sqlite3_column_int(statement, 7) != 0 { json.add("ignored", true) }
                if let network = SQLiteDatabase.text(statement, 8), network != networkName {
                    json.add("network", network)
                }
                if let pictures = media[id] {
                    json.addMedia(pictures)
                }
                try writer.write(json.finished())
                written += 1
                if written % 100_000 == 0 {
                    progress("Writing messages: \(written.formatted()) of \(total.formatted())…")
                }
            }
            try writer.close()
            conversations.append(ArchiveConversation(
                file: file, networkID: networkID, network: networkName, host: hosts[networkID], buffer: group.buffer,
                kind: group.kind,
                lines: group.count, first: Date(timeIntervalSince1970: group.first),
                last: Date(timeIntervalSince1970: group.last)))
        }
        try zip.add("conversations.json", data: encoder.encode(conversations))
        return written
    }

    private static func exportMedia(_ db: SQLiteDatabase, to zip: ZipWriter) throws -> Int {
        // The pictures go in as they are read; their index, small, after.
        var index: [UInt8] = []
        var stored = Set<String>()
        var count = 0
        try db.forEach("SELECT url, mime, width, height, data, fetched FROM media ORDER BY url") { row in
            var json = JSONLine()
            json.add("url", SQLiteDatabase.text(row, 0) ?? "")
            let mime = SQLiteDatabase.text(row, 1)
            if let mime { json.add("mime", mime) }
            json.add("width", Double(sqlite3_column_int64(row, 2)))
            json.add("height", Double(sqlite3_column_int64(row, 3)))
            json.add("fetched", time: sqlite3_column_double(row, 5))
            if let data = SQLiteDatabase.blob(row, 4) {
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let name = hash + "." + fileExtension(mime: mime)
                if stored.insert(name).inserted { try zip.add("media/\(name)", data: data) }
                json.add("file", name)
                count += 1
            }
            index += json.finished()
        }
        try zip.add("media/index.jsonl", data: Data(index))
        return count
    }

    private static func fileExtension(mime: String?) -> String {
        switch mime?.lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/heic": "heic"
        case "image/svg+xml": "svg"
        default: "bin"
        }
    }

    /// Adds the regular files under `source`, keeping their folders, under
    /// `folder` in the archive; links are left out. Returns how many.
    private static func addFiles(from source: URL, as folder: String, to zip: ZipWriter) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        let base = source.standardizedFileURL.path
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
            try zip.add("\(folder)/\(relative)", contentsOf: file)
            count += 1
        }
        return count
    }

    /// A file or folder name made of the conversation's: no slashes, colons
    /// or leading dots, and not too long.
    static func safeName(_ name: String) -> String {
        var safe = String(name.map { "/:\\\0".contains($0) || $0.isNewline ? "_" : $0 }.prefix(120))
        while safe.hasPrefix(".") { safe = "_" + safe.dropFirst() }
        return safe.isEmpty ? "_" : safe
    }

    /// The name, or with the suffix when taken, compared without case as
    /// the Mac's disks do.
    private static func unique(_ name: String, in used: inout Set<String>, prefix: String = "", suffix: String) -> String {
        var candidate = name
        var counter = 1
        while used.contains((prefix + candidate).lowercased()) {
            counter += 1
            candidate = "\(name) (\(suffix)\(counter == 2 ? "" : " \(counter)"))"
        }
        used.insert((prefix + candidate).lowercased())
        return candidate
    }

    // MARK: - Reading an archive

    /// An archive unpacked into a temporary folder, with what it holds.
    struct Unpacked: Sendable {
        var root: URL
        var manifest: ArchiveManifest
        var conversations: [ArchiveConversation]
        var networks: [NetworkConfig]
        /// The parts that are there, with how many of each.
        var available: [ArchivePart: Int]

        func cleanUp() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }

        /// A file of the archive; nil for a path that would lead outside it.
        func file(_ path: String) -> URL? {
            let components = path.split(separator: "/")
            guard !path.hasPrefix("/"), !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
            return root.appending(path: path)
        }

        func settings(_ part: ArchivePart) -> [String: Any]? {
            guard let data = try? Data(contentsOf: root.appending(path: "settings/\(part.rawValue).plist")) else {
                return nil
            }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }

        var soundsDirectory: URL { root.appending(path: "sounds") }
    }

    static func unpack(_ zip: URL) throws -> Unpacked {
        let work = FileManager.default.temporaryDirectory.appending(path: "irctell-import-\(UUID().uuidString)")
        let root = work.appending(path: "archive")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try ZipReader(url: zip).extractAll(to: root)
            guard let data = try? Data(contentsOf: root.appending(path: "manifest.json")),
                  let manifest = try? decoder.decode(ArchiveManifest.self, from: data),
                  manifest.format == ArchiveManifest.formatName else {
                throw Failure(message: "\(zip.lastPathComponent) is not an Irctell archive.")
            }
            guard manifest.version <= ArchiveManifest.currentVersion else {
                throw Failure(message: "\(zip.lastPathComponent) was written by a newer Irctell (\(manifest.app)).")
            }
            let conversations = (try? Data(contentsOf: root.appending(path: "conversations.json")))
                .flatMap { try? decoder.decode([ArchiveConversation].self, from: $0) } ?? []
            let networks = (try? Data(contentsOf: root.appending(path: "networks.json")))
                .flatMap { try? JSONDecoder().decode([NetworkConfig].self, from: $0) } ?? []
            var available: [ArchivePart: Int] = [:]
            for (key, count) in manifest.contents {
                guard let part = ArchivePart(rawValue: key) else { continue }
                available[part] = count
            }
            if conversations.isEmpty { available[.messages] = nil }
            if networks.isEmpty { available[.networks] = nil }
            return Unpacked(root: root, manifest: manifest, conversations: conversations, networks: networks,
                            available: available)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    // MARK: - Importing messages and pictures

    /// Adds the archive's lines and pictures to the log, skipping what is
    /// there already, and keeps the log's rows in time order. `networkIDs`
    /// maps the archive's networks to the ones in this Mac's list; `keep`
    /// are rows the app holds, to be told where they went if renumbered.
    static func importLog(from archive: Unpacked, into logPath: String, messages: Bool, pictures: Bool,
                          networkIDs: [UUID: UUID], keep: Set<Int64>, progress: Progress) throws -> ArchiveImportResult {
        var result = ArchiveImportResult()
        let db = try SQLiteDatabase(path: logPath)
        try db.execute("PRAGMA temp_store = FILE")
        try db.execute("BEGIN IMMEDIATE")
        do {
            if pictures {
                progress("Adding the pictures…")
                result.picturesAdded = try importMedia(archive, into: db)
            }
            // Its statements done with first: a table cannot be dropped
            // under them.
            if messages, try importLines(archive, into: db, networkIDs: networkIDs, result: &result,
                                         progress: progress) {
                progress("Putting the log's messages in time order…")
                result.renumbered = try renumberLines(db, keep: keep)
            }
            progress("Saving…")
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return result
    }

    private static func importMedia(_ archive: Unpacked, into db: SQLiteDatabase) throws -> Int {
        guard let index = archive.file("media/index.jsonl"), let data = try? Data(contentsOf: index) else { return 0 }
        let insert = try db.prepare("""
            INSERT OR IGNORE INTO media (url, mime, width, height, data, fetched) VALUES (?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(insert) }
        var added = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let url = object["url"] as? String else { continue }
            var picture: Data?
            if let name = object["file"] as? String {
                guard !name.contains("/"), let file = archive.file("media/" + name),
                      let bytes = try? Data(contentsOf: file) else { continue }
                picture = bytes
            }
            db.bind(insert, [url, object["mime"] as? String, (object["width"] as? NSNumber)?.int64Value ?? 0,
                             (object["height"] as? NSNumber)?.int64Value ?? 0, picture,
                             (object["fetched"] as? String).flatMap(parseTime) ?? Date.now.timeIntervalSince1970])
            try db.step(insert)
            if db.changes > 0, picture != nil { added += 1 }
        }
        return added
    }

    /// Adds the lines that are not there yet; returns whether the log must
    /// be numbered again, as they went in between the ones there.
    private static func importLines(_ archive: Unpacked, into db: SQLiteDatabase, networkIDs: [UUID: UUID],
                                    result: inout ArchiveImportResult, progress: Progress) throws -> Bool {
        try db.execute("""
            CREATE TEMP TABLE staged (
                seq INTEGER PRIMARY KEY, network_id TEXT, network TEXT, buffer TEXT, buffer_kind TEXT, time REAL,
                kind TEXT, sender TEXT, text TEXT, is_self INTEGER, is_highlight INTEGER, ignored INTEGER, media TEXT
            )
            """)
        defer { try? db.execute("DROP TABLE IF EXISTS temp.staged") }
        let stage = try db.prepare("""
            INSERT INTO staged (network_id, network, buffer, buffer_kind, time, kind, sender, text, is_self,
                                is_highlight, ignored, media) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stage) }
        let existing = try db.prepare("SELECT time, sender, text FROM lines WHERE network_id = ? AND buffer = ?")
        defer { sqlite3_finalize(existing) }

        let total = archive.conversations.reduce(0) { $0 + $1.lines }
        var read = 0
        for conversation in archive.conversations {
            guard let file = archive.file(conversation.file), let data = try? Data(contentsOf: file) else { continue }
            let networkID = (networkIDs[conversation.networkID] ?? conversation.networkID).uuidString
            // What this conversation has already, to leave out: the same
            // line at the same millisecond. Counted, as a log can have the
            // same line twice -- old logs kept whole seconds only -- and
            // both copies are to come over.
            var known: [Int: Int] = [:]
            db.bind(existing, [networkID, conversation.buffer])
            while sqlite3_step(existing) == SQLITE_ROW {
                known[lineKey(time: sqlite3_column_double(existing, 0), sender: SQLiteDatabase.text(existing, 1),
                              text: SQLiteDatabase.text(existing, 2) ?? ""), default: 0] += 1
            }
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                read += 1
                if read % 100_000 == 0 { progress("Reading messages: \(read.formatted()) of \(total.formatted())…") }
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let time = (object["time"] as? String).flatMap(parseTime),
                      let text = object["text"] as? String else { continue }
                let sender = object["sender"] as? String
                let key = lineKey(time: time, sender: sender, text: text)
                if let copies = known[key], copies > 0 {
                    known[key] = copies - 1
                    result.linesAlreadyThere += 1
                    continue
                }
                var media: String?
                if let pictures = object["media"] as? [Any],
                   let json = try? JSONSerialization.data(withJSONObject: pictures) {
                    media = String(decoding: json, as: UTF8.self)
                }
                db.bind(stage, [networkID, object["network"] as? String ?? conversation.network, conversation.buffer,
                                conversation.kind, time, object["kind"] as? String ?? "info", sender, text,
                                object["self"] as? Bool ?? false, object["highlight"] as? Bool ?? false,
                                object["ignored"] as? Bool ?? false, media])
                try db.step(stage)
            }
        }

        let added = try db.query("SELECT count(*), min(time), max(time) FROM staged") { row in
            (count: Int(sqlite3_column_int64(row, 0)), first: sqlite3_column_double(row, 1),
             last: sqlite3_column_double(row, 2))
        }[0]
        result.linesAdded = added.count
        guard added.count > 0 else { return false }
        let present = try db.query("SELECT count(*), min(id), max(id), min(time), max(time) FROM lines") { row in
            (count: sqlite3_column_int64(row, 0), minID: sqlite3_column_int64(row, 1),
             maxID: sqlite3_column_int64(row, 2), first: sqlite3_column_double(row, 3),
             last: sqlite3_column_double(row, 4))
        }[0]

        // The rows are read in their order as the lines' order: the new
        // ones go after the rest when newer, before when older; in between,
        // everything is numbered again.
        let firstID: Int64
        var renumber = false
        if present.count == 0 || added.first >= present.last {
            firstID = present.count == 0 ? 1 : present.maxID + 1
        } else if added.last < present.first, present.minID > Int64.min + Int64(added.count) + 1 {
            firstID = present.minID - Int64(added.count)
        } else {
            firstID = present.maxID + 1
            renumber = true
        }

        progress("Adding \(added.count.formatted()) messages…")
        let insert = try db.prepare("""
            INSERT INTO lines (id, network_id, network, buffer, buffer_kind, time, kind, sender, text, is_self,
                               is_highlight, ignored) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(insert) }
        let link = try db.prepare("""
            INSERT OR IGNORE INTO line_media (line_id, url, collapsed, display_width) VALUES (?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(link) }
        var id = firstID
        try db.forEach("""
            SELECT network_id, network, buffer, buffer_kind, time, kind, sender, text, is_self, is_highlight, ignored,
                   media FROM staged ORDER BY time, seq
            """) { row in
            db.bind(insert, [id, SQLiteDatabase.text(row, 0), SQLiteDatabase.text(row, 1), SQLiteDatabase.text(row, 2),
                             SQLiteDatabase.text(row, 3), sqlite3_column_double(row, 4), SQLiteDatabase.text(row, 5),
                             SQLiteDatabase.text(row, 6), SQLiteDatabase.text(row, 7),
                             Int64(sqlite3_column_int(row, 8)), Int64(sqlite3_column_int(row, 9)),
                             Int64(sqlite3_column_int(row, 10))])
            try db.step(insert)
            if let media = SQLiteDatabase.text(row, 11),
               let pictures = try? JSONSerialization.jsonObject(with: Data(media.utf8)) as? [[String: Any]] {
                for picture in pictures {
                    guard let url = picture["url"] as? String else { continue }
                    db.bind(link, [id, url, picture["collapsed"] as? Bool ?? false,
                                   (picture["width"] as? NSNumber)?.doubleValue])
                    try db.step(link)
                }
            }
            id += 1
        }
        return renumber
    }

    /// The same line: time to the millisecond, sender and text.
    static func lineKey(time: Double, sender: String?, text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(Int64((time * 1000).rounded()))
        hasher.combine(sender)
        hasher.combine(text)
        return hasher.finalize()
    }

    /// Numbers every line again in time order, by copying the table: much
    /// faster than changing millions of rows in place. Indexes, triggers and
    /// the search index are made again after. Returns where `keep` went.
    static func renumberLines(_ db: SQLiteDatabase, keep: Set<Int64>) throws -> [Int64: Int64] {
        let schema = try db.query("""
            SELECT type, name, sql FROM sqlite_master WHERE tbl_name = 'lines' AND sql IS NOT NULL
            """) { row in
            (type: SQLiteDatabase.text(row, 0) ?? "", name: SQLiteDatabase.text(row, 1) ?? "",
             sql: SQLiteDatabase.text(row, 2) ?? "")
        }
        guard let table = schema.first(where: { $0.type == "table" }),
              let range = table.sql.range(of: "lines", options: .caseInsensitive) else {
            throw Failure(message: "The log has no lines table.")
        }
        let columns = try db.query("PRAGMA table_info(lines)") { SQLiteDatabase.text($0, 1) ?? "" }
            .filter { $0 != "id" }
        let list = columns.joined(separator: ", ")

        try db.execute("""
            DROP TABLE IF EXISTS temp.renumber;
            CREATE TEMP TABLE renumber (old INTEGER PRIMARY KEY, new INTEGER NOT NULL);
            INSERT INTO renumber (old, new) SELECT id, row_number() OVER (ORDER BY time, id) FROM lines;
            DROP TABLE IF EXISTS lines_renumbered;
            """)
        try db.execute(table.sql.replacingCharacters(in: range, with: "lines_renumbered"))
        try db.execute("""
            INSERT INTO lines_renumbered (id, \(list))
            SELECT r.new, \(columns.map { "l." + $0 }.joined(separator: ", "))
            FROM renumber r JOIN lines l ON l.id = r.old ORDER BY r.new;

            CREATE TEMP TABLE renumbered_media AS
            SELECT r.new AS line_id, m.url, m.collapsed, m.display_width
            FROM line_media m JOIN renumber r ON r.old = m.line_id;
            DELETE FROM line_media;
            INSERT OR IGNORE INTO line_media (line_id, url, collapsed, display_width)
            SELECT line_id, url, collapsed, display_width FROM renumbered_media;
            DROP TABLE renumbered_media;

            """)
        try db.execute("DROP TABLE lines")
        try db.execute("ALTER TABLE lines_renumbered RENAME TO lines")
        for entry in schema where entry.type != "table" {
            try db.execute(entry.sql)
        }
        try db.execute("INSERT INTO lines_fts (lines_fts) VALUES ('rebuild')")

        var moved: [Int64: Int64] = [:]
        let find = try db.prepare("SELECT new FROM renumber WHERE old = ?")
        for old in keep {
            db.bind(find, [old])
            if sqlite3_step(find) == SQLITE_ROW { moved[old] = sqlite3_column_int64(find, 0) }
        }
        sqlite3_finalize(find)
        try db.execute("DROP TABLE temp.renumber")
        return moved
    }

    // MARK: - JSON and times

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatTime(date.timeIntervalSince1970))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let seconds = parseTime(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return Date(timeIntervalSince1970: seconds)
        }
        return decoder
    }()

    /// UTC, to the millisecond: `2026-10-15T13:21:59.123Z`.
    static func formatTime(_ seconds: Double) -> String {
        let milliseconds = Int64((seconds * 1000).rounded())
        var whole = time_t(milliseconds.floorDivided(by: 1000))
        let fraction = Int(milliseconds - Int64(whole) * 1000)
        var parts = tm()
        gmtime_r(&whole, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.tm_year + 1900, parts.tm_mon + 1,
                      parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec, fraction)
    }

    /// The time `formatTime` writes; other ISO 8601 forms, with an offset or
    /// without fractions, too.
    static func parseTime(_ text: String) -> Double? {
        let bytes = Array(text.utf8)
        func number(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[start..<start + count] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        if bytes.count >= 20, bytes.last == UInt8(ascii: "Z"), bytes[10] == UInt8(ascii: "T"),
           let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
           let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) {
            var parts = tm()
            parts.tm_year = Int32(year - 1900)
            parts.tm_mon = Int32(month - 1)
            parts.tm_mday = Int32(day)
            parts.tm_hour = Int32(hour)
            parts.tm_min = Int32(minute)
            parts.tm_sec = Int32(second)
            var seconds = Double(timegm(&parts))
            if bytes.count > 21, bytes[19] == UInt8(ascii: ".") {
                let digits = bytes.count - 21
                if let fraction = number(20, digits) { seconds += Double(fraction) / pow(10, Double(digits)) }
            }
            return seconds
        }
        return (try? Date(text, strategy: .iso8601))?.timeIntervalSince1970
    }
}

private extension Int64 {
    func floorDivided(by divisor: Int64) -> Int64 {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}

/// One line of JSON, written by hand: millions of them are written, and an
/// encoder per line would take minutes.
struct JSONLine {
    private var bytes: [UInt8] = [UInt8(ascii: "{")]

    mutating func add(_ key: String, _ value: String) {
        start(key)
        append(string: value)
    }

    mutating func add(_ key: String, _ value: Bool) {
        start(key)
        bytes += Array((value ? "true" : "false").utf8)
    }

    mutating func add(_ key: String, _ value: Double) {
        start(key)
        bytes += Array((value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)).utf8)
    }

    mutating func add(_ key: String, time: Double) {
        add(key, LogArchive.formatTime(time))
    }

    mutating func addMedia(_ pictures: [(url: String, collapsed: Bool, width: Double?)]) {
        start("media")
        bytes.append(UInt8(ascii: "["))
        for (index, picture) in pictures.enumerated() {
            if index > 0 { bytes.append(UInt8(ascii: ",")) }
            var item = JSONLine()
            item.add("url", picture.url)
            if picture.collapsed { item.add("collapsed", true) }
            if let width = picture.width { item.add("width", width) }
            bytes += item.closed()
        }
        bytes.append(UInt8(ascii: "]"))
    }

    /// The object and a newline.
    func finished() -> [UInt8] {
        closed() + [UInt8(ascii: "\n")]
    }

    private func closed() -> [UInt8] {
        bytes + [UInt8(ascii: "}")]
    }

    private mutating func start(_ key: String) {
        if bytes.count > 1 { bytes.append(UInt8(ascii: ",")) }
        append(string: key)
        bytes.append(UInt8(ascii: ":"))
    }

    private mutating func append(string: String) {
        bytes.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): bytes += [92, 34]
            case UInt8(ascii: "\\"): bytes += [92, 92]
            case 10: bytes += [92, UInt8(ascii: "n")]
            case 13: bytes += [92, UInt8(ascii: "r")]
            case 9: bytes += [92, UInt8(ascii: "t")]
            case 0..<32:
                // IRC's formatting codes: bold, colours and the like.
                bytes += Array(String(format: "\\u%04x", byte).utf8)
            default: bytes.append(byte)
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }
}

/// Writes an entry of the archive in large pieces: compressing a line at a
/// time would take much longer.
private final class LineWriter {
    private let zip: ZipWriter
    private var buffer: [UInt8] = []

    init(zip: ZipWriter, name: String) throws {
        self.zip = zip
        try zip.begin(name)
        buffer.reserveCapacity(1 << 20)
    }

    func write(_ bytes: [UInt8]) throws {
        buffer += bytes
        if buffer.count >= 1 << 20 { try flush() }
    }

    func close() throws {
        try flush()
        try zip.end()
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try zip.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
