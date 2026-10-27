import Foundation
import Observation

/// One line in a conversation.
struct ChatLine: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case message, action, notice
        case join, part, quit, kick, nick, topic, mode
        case info, error
    }

    let id = UUID()
    var time: Date
    var kind: Kind
    /// The nick the line is from, for message-like lines and events.
    var sender: String?
    var text: String
    var isSelf = false
    var isHighlight = false
    /// Its row in the log database, once written there.
    var logID: Int64?
    /// The network it came on, for lines read back from the log.
    var network: String?
    /// From someone ignored when it came: logged, not shown while they
    /// still are.
    var isIgnored = false

    /// Lines that count as unread activity, as opposed to joins and parts.
    var isActivity: Bool { kind == .message || kind == .action || kind == .notice }

    /// What a conversation shows with "Messages only": what people wrote,
    /// if it is three characters or more -- not joins, parts, quits, modes,
    /// nick changes, notices or the server's own lines.
    var isConversation: Bool {
        (kind == .message || kind == .action)
            && IRCFormatting.strip(text).trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }
}

struct ChannelMember: Sendable, Hashable {
    var nick: String
    /// Membership symbols, highest first: "@+" for an op with voice.
    var prefixes = ""
    var isAway = false
}

/// A conversation: the server's own messages, a channel, or a private chat.
@MainActor @Observable
final class ChatBuffer: Identifiable {
    enum Kind: String, Sendable, Codable { case server, channel, query }

    /// Lines kept in memory per buffer; older ones scroll away. The history
    /// database (step 3) will keep everything.
    static let lineLimit = 5000

    let id = UUID()
    let kind: Kind
    var name: String
    private(set) var lines: [ChatLine] = []
    var topic: String?
    /// Keyed by the case-folded nick.
    var members: [String: ChannelMember] = [:]
    var isJoined = false
    /// For a private chat: whether the other one is on the network now; nil
    /// until known.
    var partnerOnline: Bool?
    /// Joined again on reconnect; cleared by parting.
    var wantsJoin = false
    var unreadCount = 0
    /// Notifications since it was last looked at: what the Dock badge counts.
    var attentionCount = 0
    /// The member list's filter, kept while switching between buffers; it
    /// goes with the buffer when it is closed, and is not saved on quit.
    var memberFilter = ""
    /// The members selected in the list, whose lines are highlighted.
    var selectedMembers: Set<String> = []
    /// The transcript's full-text search; saved with the open buffers.
    var search = ""
    /// A private chat showing its nick's chats on every network, from the log.
    var aggregatesHistory = false
    /// Each line of an aggregated history says which network it came on.
    var showsNetworkNames = false
    /// New messages from others are read aloud.
    var speaks = false
    /// Only what people wrote is shown: joins, parts, modes and the like,
    /// and lines of one or two characters, are hidden.
    var messagesOnly = false
    /// What is typed in the input field and not sent yet: kept while other
    /// conversations are looked at, and saved with the open buffers.
    var draft = ""
    /// The time the transcript went back to, from the log; nil for the
    /// newest lines. Not kept between launches.
    var historyDate: Date?
    /// Lines up to this log row are hidden: what Clear cleared.
    var clearedUpTo: Int64?
    /// The logged line in the middle of the transcript when it was left
    /// scrolled back; nil when it showed the newest lines.
    @ObservationIgnored var anchorLine: Int64?
    /// The text selected in one line of the transcript.
    @ObservationIgnored var selection: TranscriptSelection?
    /// A reply Apple Intelligence suggests, shown in the empty input field,
    /// and the line it answers.
    var suggestion: String?
    /// When the oldest message not seen yet came: what the unread private
    /// chats are taken in the order of.
    var firstUnseen: Date?
    @ObservationIgnored var suggestionAnswers: String?
    var hasHighlight = false
    @ObservationIgnored var namesInProgress = false

    init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    func append(_ line: ChatLine) {
        lines.append(line)
        if lines.count > ChatBuffer.lineLimit {
            lines.removeFirst(lines.count - ChatBuffer.lineLimit)
        }
    }

    /// Empties the transcript; `logID`, the newest line in the log, keeps
    /// the history from coming back with scrolling until the next launch.
    func clear(upTo logID: Int64? = nil) {
        lines.removeAll()
        clearedUpTo = logID ?? clearedUpTo
    }

    /// The log was numbered again: the rows this buffer knows, where they
    /// are now.
    func renumberLogRows(_ moved: [Int64: Int64]) {
        guard !moved.isEmpty else { return }
        if let floor = clearedUpTo { clearedUpTo = moved[floor] ?? floor }
        for index in lines.indices {
            if let id = lines[index].logID, let new = moved[id] { lines[index].logID = new }
        }
    }

    func markRead() {
        unreadCount = 0
        hasHighlight = false
        firstUnseen = nil
        attentionCount = 0
    }
}

/// Text selected in one logged line: the line, and the characters in it as
/// the transcript shows it.
struct TranscriptSelection: Codable, Equatable, Hashable, Sendable {
    var logID: Int64
    var location: Int
    var length: Int

    var range: NSRange { NSRange(location: location, length: length) }
}
