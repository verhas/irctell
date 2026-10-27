import Foundation
import Observation

/// A memo in the inbox, as MemoServ lists it: its number there -- which
/// changes when one before it is deleted -- who sent it, when, and its text
/// once read.
struct Memo: Codable, Hashable, Identifiable, Sendable {
    var number: Int
    var from: String
    /// As the server wrote it: its format and time zone differ by network.
    var date: String
    var isUnread: Bool
    var text: String?

    /// Stays the same when the numbers change.
    var id: String { "\(from.lowercased())|\(date)" }
}

/// A memo the user sent: MemoServ keeps no copy, so Irctell does.
struct SentMemo: Codable, Hashable, Identifiable, Sendable {
    enum Status: Codable, Hashable, Sendable {
        case sending
        case delivered
        case failed(String)
    }

    var id = UUID()
    var to: String
    var text: String
    var time: Date
    var status: Status
}

/// What a MemoServ line says, in the words of Atheme (Libera.Chat and many
/// more) or Anope, the services most networks run.
enum MemoServReply: Equatable {
    /// A listing starts: a count, or a heading.
    case listStart
    case listEmpty
    case listEntry(number: Int, from: String, date: String, unread: Bool)
    /// A memo being read: its text follows.
    case readStart(number: Int, from: String, date: String)
    case sent(to: String)
    case deleted
    /// A new memo came, or new ones wait: worth listing.
    case newMemos
    /// Not understood alone: the text of a memo being read, or a message.
    case other(String)

    static func parse(_ raw: String, listing: Bool) -> MemoServReply {
        let line = IRCFormatting.strip(raw).trimmingCharacters(in: .whitespaces)
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let found = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            return (0..<found.numberOfRanges).map { index in
                Range(found.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
        }
        // Atheme: "- 1 From: bob Sent: Oct 16 10:00:00 2026 [unread]"
        if let m = match(#"^-\s+(\d+)\s+From:\s+(\S+)\s+Sent:\s+(.+?)(\s+\[unread\])?$"#), let number = Int(m[1]) {
            return .listEntry(number: number, from: m[2], date: m[3], unread: !m[4].isEmpty)
        }
        // Atheme: "Memo 1 - Sent by bob, Oct 16 10:00:00 2026"
        if let m = match(#"^Memo\s+(\d+)\s+-\s+Sent by\s+(\S+),\s+(.+)$"#), let number = Int(m[1]) {
            return .readStart(number: number, from: m[2], date: m[3])
        }
        // Anope: "Memo 1 from bob (Oct 16 10:00:00 2026 UTC)."
        if let m = match(#"^Memo\s+(\d+)\s+from\s+(\S+)\s+\((.+)\)\.?$"#), let number = Int(m[1]) {
            return .readStart(number: number, from: m[2], date: m[3])
        }
        if match(#"^You have no memos"#) != nil { return .listEmpty }
        if match(#"^You have a new memo"#) != nil || match(#"^You have \d+ new memos?\.?$"#) != nil {
            return .newMemos
        }
        if match(#"^You have \d+ memos?"#) != nil || match(#"^Memos for \S+"#) != nil { return .listStart }
        if let m = match(#"^The memo has been successfully sent to\s+(\S+?)\.?$"#) ?? match(#"^Memo sent to\s+(\S+?)\.?$"#) {
            return .sent(to: m[1])
        }
        if match(#"^\d+ memos? deleted"#) != nil || match(#"^Memo \d+ has been deleted"#) != nil
            || match(#"^All of your memos have been deleted"#) != nil {
            return .deleted
        }
        // Anope's rows: " * 1  bob  Oct 16 10:00:00 2026 UTC" -- only taken
        // as one inside a listing, as it would match much else.
        if listing, let m = match(#"^(\*)?\s*(\d+)\s+(\S+)\s+(.+)$"#), let number = Int(m[2]) {
            return .listEntry(number: number, from: m[3], date: m[4], unread: !m[1].isEmpty)
        }
        return .other(line)
    }
}

/// The memos of one network: the inbox as MemoServ lists it, with the texts
/// read, and the outbox Irctell keeps. Made from MemoServ's answers to the
/// commands it sends; saved, so they can be read offline.
@MainActor @Observable
final class MemoBox {
    private(set) var inbox: [Memo] = []
    private(set) var outbox: [SentMemo] = []
    /// What MemoServ last said that was not understood: an error, mostly.
    private(set) var status: String?
    /// Waiting for an answer to LIST.
    private(set) var isChecking = false
    private(set) var lastChecked: Date?

    /// Sends a command to MemoServ.
    @ObservationIgnored var command: (String) -> Void = { _ in }
    /// Told when a new memo comes, with its sender when MemoServ names them.
    @ObservationIgnored var onNewMemo: (String?) -> Void = { _ in }
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var listing: [Memo]?
    @ObservationIgnored private var reading: (number: Int, from: String, date: String)?
    @ObservationIgnored private var readingText: [String] = []

    var unreadCount: Int { inbox.filter(\.isUnread).count }

    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - What the user does

    func check() {
        isChecking = true
        listing = nil
        command("LIST")
    }

    /// Reads it on the server -- marking it read there too -- unless its text
    /// is here already.
    func open(_ memo: Memo) {
        guard memo.text == nil || memo.isUnread else { return }
        command("READ \(memo.number)")
    }

    func delete(_ memo: Memo) {
        command("DEL \(memo.number)")
    }

    func deleteAll() {
        command("DEL ALL")
    }

    func send(to nick: String, text: String) {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        outbox.insert(SentMemo(to: nick, text: flat, time: .now, status: .sending), at: 0)
        save()
        command("SEND \(nick) \(flat)")
    }

    func removeFromOutbox(_ ids: Set<SentMemo.ID>) {
        outbox.removeAll { ids.contains($0.id) }
        save()
    }

    // MARK: - What MemoServ says

    func received(_ line: String) {
        let reply = MemoServReply.parse(line, listing: listing != nil)
        // A memo's text ends where something else begins.
        if reading != nil, case .other(let text) = reply {
            if text.hasPrefix("---") || text.lowercased().hasPrefix("to delete") || text.isEmpty { return }
            readingText.append(text)
            finishReading()
            return
        }
        switch reply {
        case .listStart:
            listing = []
            scheduleListEnd()
        case .listEmpty:
            listing = nil
            replaceInbox(with: [])
        case .listEntry(let number, let from, let date, let unread):
            if listing == nil { listing = [] }
            listing?.append(Memo(number: number, from: from, date: date, isUnread: unread))
            scheduleListEnd()
        case .readStart(let number, let from, let date):
            reading = (number, from, date)
            readingText = []
        case .sent:
            settleSend(.delivered)
        case .deleted:
            check()
        case .newMemos:
            let plain = IRCFormatting.strip(line)
            let from = plain.range(of: #"from\s+(\S+?)[\s.(]"#, options: .regularExpression).map {
                String(plain[$0]).dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " .("))
            }
            if plain.lowercased().contains("new memo from") { onNewMemo(from) }
            check()
        case .other(let text):
            if outbox.contains(where: { $0.status == .sending }), MemoBox.isRefusal(text) {
                settleSend(.failed(text))
            } else if listing != nil, MemoBox.isListDecoration(text) {
                scheduleListEnd()
            } else {
                status = text
            }
        }
    }

    /// An answer refusing a SEND: not registered, a full inbox, too soon.
    static func isRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["not registered", "isn't registered", "is not a registered", "is full", "cannot", "can't",
                "must wait", "please wait", "insufficient", "not allowed", "denied", "too long", "ignor"]
            .contains { lower.contains($0) }
    }

    /// Lines of a listing that are no memo: Anope's column heading, hints.
    private static func isListDecoration(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("num ") || lower.hasPrefix("to read") || lower.hasPrefix("end of")
    }

    // MARK: - Keeping it

    private var listEnd: Task<Void, Never>?

    /// The listing has no end marker: it ends when the lines stop coming.
    private func scheduleListEnd() {
        listEnd?.cancel()
        listEnd = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.endListing()
        }
    }

    private func endListing() {
        listEnd?.cancel()
        guard let listed = listing else { return }
        listing = nil
        replaceInbox(with: listed)
    }

    /// The new list, with the texts already read kept.
    private func replaceInbox(with listed: [Memo]) {
        let known = Dictionary(inbox.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        inbox = listed.map { memo in
            var memo = memo
            memo.text = known[memo.id]?.text
            return memo
        }
        isChecking = false
        lastChecked = .now
        status = nil
        save()
    }

    private func finishReading() {
        guard let read = reading else { return }
        reading = nil
        let text = readingText.joined(separator: " ")
        readingText = []
        let id = Memo(number: read.number, from: read.from, date: read.date, isUnread: false).id
        if let index = inbox.firstIndex(where: { $0.id == id || $0.number == read.number }) {
            inbox[index].text = text
            inbox[index].isUnread = false
        } else {
            inbox.append(Memo(number: read.number, from: read.from, date: read.date, isUnread: false, text: text))
        }
        save()
    }

    /// The oldest memo still being sent: answered now.
    private func settleSend(_ result: SentMemo.Status) {
        guard let index = outbox.lastIndex(where: { $0.status == .sending }) else { return }
        outbox[index].status = result
        save()
    }

    private struct Saved: Codable {
        var inbox: [Memo]
        var outbox: [SentMemo]
        var lastChecked: Date?
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        inbox = saved.inbox
        // Unanswered when Irctell last ran: no answer will come now.
        outbox = saved.outbox.map { memo in
            var memo = memo
            if memo.status == .sending { memo.status = .failed("No answer from MemoServ") }
            return memo
        }
        lastChecked = saved.lastChecked
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Saved(inbox: inbox, outbox: outbox, lastChecked: lastChecked))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.error("memos", "could not save the memos: \(error.localizedDescription)")
        }
    }
}
