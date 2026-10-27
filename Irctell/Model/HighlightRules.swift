import Foundation

/// Someone whose lines are not shown: everywhere, or in private chats only.
/// Their lines are still logged, so taking the ignore off brings them back
/// when scrolling through the history.
struct IgnoreEntry: Codable, Hashable, Sendable, Identifiable {
    enum Scope: String, Codable, CaseIterable, Sendable {
        /// Not in channels either.
        case everything
        /// Channel messages are shown; private messages do not open a chat.
        case privateMessages

        var title: String {
            switch self {
            case .everything: "Everything"
            case .privateMessages: "Private messages"
            }
        }
    }

    var nick: String
    var scope: Scope = .everything
    var id: String { nick.lowercased() }
}

/// An ignore as the log applies it: the network it is set for, or nil for
/// every network.
struct IgnoreRule: Hashable, Sendable {
    var network: UUID?
    /// Lowercased.
    var nick: String
    var privateOnly: Bool

    /// Whether a line logged as ignored stays hidden under this rule.
    func hides(sender: String?, network: UUID, kind: ChatBuffer.Kind) -> Bool {
        guard let sender, sender.lowercased() == nick else { return false }
        if let only = self.network, only != network { return false }
        return !privateOnly || kind == .query
    }
}

/// What counts as a mention besides the nick, and whose lines are ignored:
/// the settings' rules together with the network's own.
struct HighlightRules: Equatable, Sendable {
    static let wordsKey = "highlight.words"
    static let patternsKey = "highlight.patterns"
    static let ignoresKey = "highlight.ignores"
    /// Earlier versions' plain list of nicks, ignored everywhere.
    static let ignoredNicksKey = "highlight.ignoredNicks"

    /// Matched as whole words, ignoring case.
    var words: [String] = []
    /// Regular expressions, ignoring case.
    var patterns: [String] = [] {
        didSet { compiled = HighlightRules.compile(patterns) }
    }
    var ignores: [IgnoreEntry] = []

    private var compiled: [NSRegularExpression] = []

    init(words: [String] = [], patterns: [String] = [], ignores: [IgnoreEntry] = []) {
        self.words = words
        self.patterns = patterns
        self.ignores = ignores
        compiled = HighlightRules.compile(patterns)
    }

    static func == (lhs: HighlightRules, rhs: HighlightRules) -> Bool {
        lhs.words == rhs.words && lhs.patterns == rhs.patterns && lhs.ignores == rhs.ignores
    }

    /// The global ignores in the settings.
    @MainActor static func globalIgnores(in settings: SettingsStore = .shared) -> [IgnoreEntry] {
        if let object = settings.object(forKey: ignoresKey),
           let entries = SettingsStore.decode([IgnoreEntry].self, from: object) {
            return entries
        }
        return (settings.stringArray(forKey: ignoredNicksKey) ?? []).map { IgnoreEntry(nick: $0) }
    }

    @MainActor static func setGlobalIgnores(_ entries: [IgnoreEntry], in settings: SettingsStore = .shared) {
        settings.set(SettingsStore.plistObject(entries), forKey: ignoresKey)
        settings.set(nil, forKey: ignoredNicksKey)
    }

    /// The settings' rules with the network's added; asked for every
    /// message, so the compiled patterns are kept until either changes.
    @MainActor static func current(for network: NetworkConfig? = nil) -> HighlightRules {
        let settings = SettingsStore.shared
        let words = (settings.stringArray(forKey: wordsKey) ?? []) + (network?.highlightWords ?? [])
        let patterns = (settings.stringArray(forKey: patternsKey) ?? []) + (network?.highlightPatterns ?? [])
        let ignores = globalIgnores(in: settings) + (network?.ignores ?? [])
        let key = network?.id
        if let cached = cache[key], cached.words == words, cached.patterns == patterns, cached.ignores == ignores {
            return cached
        }
        let fresh = HighlightRules(words: words, patterns: patterns, ignores: ignores)
        cache[key] = fresh
        return fresh
    }

    @MainActor private static var cache: [UUID?: HighlightRules] = [:]

    /// Whether the text mentions `nick` or one of the words, or matches one
    /// of the patterns.
    func matches(_ text: String, nick: String) -> Bool {
        if HighlightRules.containsWord(nick, in: text) { return true }
        if words.contains(where: { HighlightRules.containsWord($0, in: text) }) { return true }
        let range = NSRange(text.startIndex..., in: text)
        return compiled.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// How the sender is ignored; ignoring everything wins over private
    /// messages only.
    func ignore(of sender: String?) -> IgnoreEntry.Scope? {
        guard let sender else { return nil }
        let scopes = ignores.filter { $0.nick.caseInsensitiveCompare(sender) == .orderedSame }.map(\.scope)
        if scopes.contains(.everything) { return .everything }
        return scopes.first
    }

    func isIgnored(_ sender: String?) -> Bool {
        ignore(of: sender) != nil
    }

    /// The error of a pattern that does not compile, for the settings.
    static func error(in pattern: String) -> String? {
        do {
            _ = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            return nil
        } catch {
            return "Not a valid regular expression: \(pattern)"
        }
    }

    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }

    /// `word` in `text`, ignoring case, not as part of a longer word: "bob"
    /// is in "hey bob!" and "Bob: ping", not in "bobby" or "kebob".
    static func containsWord(_ word: String, in text: String) -> Bool {
        let haystack = text.lowercased(), needle = word.lowercased()
        guard !needle.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            let before = found.lowerBound > haystack.startIndex ? haystack[haystack.index(before: found.lowerBound)] : nil
            let after = found.upperBound < haystack.endIndex ? haystack[found.upperBound] : nil
            let isWordChar: (Character?) -> Bool = { $0?.isLetter == true || $0?.isNumber == true }
            if !isWordChar(before) && !isWordChar(after) { return true }
            searchRange = found.upperBound..<haystack.endIndex
        }
        return false
    }
}

/// How much a conversation notifies.
enum NotificationLevel: String, CaseIterable, Sendable {
    /// Every message from others.
    case all
    /// Mentions only; private chats count as mentions.
    case mentions
    /// Never: muted.
    case none

    static func `default`(for kind: ChatBuffer.Kind) -> NotificationLevel {
        kind == .query ? .all : .mentions
    }

    var title: String {
        switch self {
        case .all: "Every Message"
        case .mentions: "Mentions Only"
        case .none: "Never (Muted)"
        }
    }
}

/// Something that may deserve a notification: a line from someone else.
struct AttentionEvent: Sendable {
    enum Reason: Sendable { case mention, privateMessage, message }
    var networkID: UUID
    var networkName: String
    var bufferName: String
    var bufferKind: ChatBuffer.Kind
    var line: ChatLine
    var reason: Reason
}
