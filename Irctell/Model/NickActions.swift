import Foundation

/// A command of the user's in a nick's right-click menu: "/msg Data !view
/// {nick}", offered in the channels it is for.
struct NickAction: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// The channels it is offered in: patterns, `*` for anything and `?` for
    /// one character, separated by commas or spaces; empty for everywhere.
    var channels = ""
    /// One IRC command or message per line; {nick}, {channel}, {me} and
    /// {network} are filled in.
    var command: String
    var isEnabled = true

    /// Whether it is offered in the conversation: everywhere without
    /// channels; with them, in the channels matching one.
    func applies(to conversation: String, isChannel: Bool) -> Bool {
        let patterns = NickAction.patterns(channels)
        guard !patterns.isEmpty else { return true }
        guard isChannel else { return false }
        return patterns.contains { NickAction.matches(conversation, pattern: $0) }
    }

    /// The command with the placeholders filled in.
    func expanded(nick: String, channel: String, me: String, network: String) -> String {
        command.replacingOccurrences(of: "{nick}", with: nick)
            .replacingOccurrences(of: "{channel}", with: channel)
            .replacingOccurrences(of: "{me}", with: me)
            .replacingOccurrences(of: "{network}", with: network)
    }

    static func patterns(_ text: String) -> [String] {
        text.split { $0 == "," || $0 == " " }.map(String.init)
    }

    /// A channel name against a pattern, ignoring case. A pattern without the
    /// channel's # matches it too: "room*" is "#room*".
    static func matches(_ name: String, pattern: String) -> Bool {
        let bare = name.drop { "#&+!".contains($0) }
        return glob(pattern).map { regex in
            [name, String(bare)].contains { candidate in
                regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
            }
        } ?? false
    }

    private static func glob(_ pattern: String) -> NSRegularExpression? {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return try? NSRegularExpression(pattern: regex + "$", options: .caseInsensitive)
    }
}

/// The nick actions: the user's own. None come with Irctell: each depends
/// on the channels and bots of the user's networks.
@MainActor
final class NickActions {
    static let shared = NickActions()
    static let key = "nickActions"

    private let settings: SettingsStore

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    var list: [NickAction] {
        get {
            guard let object = settings.object(forKey: NickActions.key),
                  let list = SettingsStore.decode([NickAction].self, from: object) else { return [] }
            return list
        }
        set { settings.set(SettingsStore.plistObject(newValue), forKey: NickActions.key) }
    }

    /// The enabled ones offered in the conversation.
    func offered(in conversation: String, isChannel: Bool) -> [NickAction] {
        list.filter { $0.isEnabled && !$0.name.isEmpty && !$0.command.isEmpty
            && $0.applies(to: conversation, isChannel: isChannel) }
    }
}

extension NetworkSession {
    /// Runs a nick action for the nick in the conversation: each line of it,
    /// a command or a message there.
    func run(_ action: NickAction, nick: String, in buffer: ChatBuffer) {
        let channel = buffer.kind == .server ? "" : buffer.name
        let command = action.expanded(nick: nick, channel: channel, me: self.nick, network: displayName)
        AppLog.info("actions", "\(action.name) for \(nick) in \(buffer.name)")
        submit(command, in: buffer)
    }
}
