import Foundation

/// A regular expression, and what to answer a line it matches: one of the
/// replies, picked at random. "{nick}" in a reply is who wrote, "{me}" the
/// user's nick.
struct AutoReplyRule: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var pattern: String
    var replies: [String]
    var isEnabled = true
}

/// Where lines are answered.
enum AutoReplyScope: String, CaseIterable, Sendable {
    case privateChats
    /// Also channel lines that mention the user.
    case mentions
    /// Every line, channels too.
    case everywhere

    var title: String {
        switch self {
        case .privateChats: "Private chats"
        case .mentions: "Private chats, and channel lines that mention me"
        case .everywhere: "Private chats and channels"
        }
    }
}

/// Answers lines that match a rule, with care not to be a nuisance: never
/// a notice, an action or anyone ignored; each nick once per rule in ten
/// minutes; one reply every few seconds at most, so two such programs cannot
/// talk to each other for ever.
@MainActor
final class AutoReplier {
    static let shared = AutoReplier()

    static let enabledKey = "autoReply.enabled"
    static let scopeKey = "autoReply.scope"
    static let rulesKey = "autoReply.rules"
    /// In a private chat, only the first this many messages of a
    /// conversation are answered; 0 for all.
    static let startMessagesKey = "autoReply.startMessages"
    static let defaultStartMessages = 4
    /// Silence after which a private chat counts as a new conversation.
    static let conversationGap: TimeInterval = 30 * 60

    /// The same nick, the same rule: not again within this.
    static let cooldown: TimeInterval = 10 * 60
    /// Any reply: not within this of the last one.
    static let spacing: TimeInterval = 3

    private let settings: SettingsStore
    private var lastReply: [String: Date] = [:]
    private var lastAny = Date.distantPast
    private var compiled: [String: NSRegularExpression] = [:]

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    var isEnabled: Bool { settings.bool(forKey: AutoReplier.enabledKey, default: false) }

    /// How many messages at the start of a private conversation may be
    /// answered; 0 for no limit.
    var startMessages: Int {
        settings.object(forKey: AutoReplier.startMessagesKey) as? Int ?? AutoReplier.defaultStartMessages
    }

    var scope: AutoReplyScope {
        settings.string(forKey: AutoReplier.scopeKey).flatMap(AutoReplyScope.init(rawValue:)) ?? .privateChats
    }

    /// The rules; the samples until the user has any of their own.
    var rules: [AutoReplyRule] {
        get {
            guard let object = settings.object(forKey: AutoReplier.rulesKey),
                  let rules = SettingsStore.decode([AutoReplyRule].self, from: object) else {
                return AutoReplier.samples
            }
            return rules
        }
        set { settings.set(SettingsStore.plistObject(newValue), forKey: AutoReplier.rulesKey) }
    }

    /// The first enabled rule whose pattern the text matches.
    func rule(matching text: String) -> AutoReplyRule? {
        let plain = IRCFormatting.strip(text)
        let range = NSRange(plain.startIndex..., in: plain)
        return rules.first { rule in
            guard rule.isEnabled, !rule.replies.isEmpty, let regex = regex(rule.pattern) else { return false }
            return regex.firstMatch(in: plain, range: range) != nil
        }
    }

    /// The reply to a line, or nil: the rules, the scope, and the limits
    /// decide. `position` is the line's place in its private conversation,
    /// from 1: past the first few, an exchange is under way and is left to
    /// the user. A reply given is remembered for the limits.
    func reply(to line: ChatLine, in kind: ChatBuffer.Kind, network: UUID, me: String, position: Int = 1,
               now: Date = .now) -> String? {
        guard isEnabled, line.kind == .message, !line.isSelf, !line.isIgnored, let sender = line.sender else { return nil }
        if kind == .query, startMessages > 0, position > startMessages { return nil }
        switch (scope, kind) {
        case (_, .query), (.everywhere, .channel): break
        case (.mentions, .channel) where line.isHighlight: break
        default: return nil
        }
        guard now.timeIntervalSince(lastAny) >= AutoReplier.spacing, let rule = rule(matching: line.text) else {
            return nil
        }
        let key = "\(network)|\(sender.lowercased())|\(rule.id)"
        if let last = lastReply[key], now.timeIntervalSince(last) < AutoReplier.cooldown { return nil }
        guard let reply = rule.replies.randomElement() else { return nil }
        lastReply[key] = now
        lastAny = now
        return reply.replacingOccurrences(of: "{nick}", with: sender).replacingOccurrences(of: "{me}", with: me)
    }

    /// The place of the newest line in its conversation, from 1: the
    /// messages and actions, from both sides, since the last silence of
    /// `conversationGap`. The lines are oldest first.
    static func position(inConversation lines: [ChatLine], gap: TimeInterval = conversationGap) -> Int {
        let said = lines.filter { $0.kind == .message || $0.kind == .action }
        guard var later = said.last else { return 1 }
        var count = 1
        for line in said.dropLast().reversed() {
            if later.time.timeIntervalSince(line.time) >= gap { break }
            count += 1
            later = line
        }
        return count
    }

    /// The error of a pattern that does not compile, for the editor.
    static func error(in pattern: String) -> String? {
        (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)) == nil
            ? "Not a valid regular expression" : nil
    }

    private func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = compiled[pattern] { return cached }
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        compiled[pattern] = regex
        return regex
    }

    /// What the list starts with; also brought back with Restore Samples.
    static let samples: [AutoReplyRule] = [
        AutoReplyRule(pattern: #"^\s*(hi|hello|hey|heya|hiya|howdy|yo|hallo|szia|helló)\b"#,
                      replies: ["Hi {nick}!", "Hello {nick} :)", "Hey {nick}, how are you?"]),
        AutoReplyRule(pattern: #"\bhow\s+(are|r)\s+(you|u|ya)\b|\bhow('?s| is)\s+it\s+going\b|\bwhat'?s\s+up\b|\bwassup\b"#,
                      replies: ["I'm fine, thanks! And you?", "Good, thanks for asking. How about you?",
                                "All well here. You?"]),
        AutoReplyRule(pattern: #"^\s*a\s*/?\s*s\s*/?\s*l\b|\bage\s*/\s*sex\s*/\s*loc"#,
                      replies: ["I don't do a/s/l, sorry. Let's just chat :)",
                                "No a/s/l, please. What would you like to talk about?"]),
        AutoReplyRule(pattern: #"\b(are|r)\s+(you|u)\s+(there|around|here|awake)\b|^\s*(ping|hello\?+)\s*$"#,
                      replies: ["I'm away from the keyboard at the moment; I'll answer when I'm back.",
                                "Not at my desk right now, back soon."]),
        AutoReplyRule(pattern: #"\b(thanks|thank\s+you|thx|thnx|ty)\b"#,
                      replies: ["You're welcome!", "Any time :)", "Glad to help."]),
        AutoReplyRule(pattern: #"\b(bye|byebye|cya|see\s+(you|ya|u)|good\s?night|nite|gn)\b"#,
                      replies: ["Bye {nick}!", "See you later, {nick}!", "Take care!"]),
        AutoReplyRule(pattern: #"\bwhere\s+(are\s+)?(you|u)\s+from\b|\bwhere\s+do\s+(you|u)\s+live\b"#,
                      replies: ["I'd rather not say, but nice to meet you!", "Here and there :)"]),
    ]
}
