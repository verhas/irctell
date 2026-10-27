import Foundation

/// Client-To-Client Protocol: a PRIVMSG or NOTICE whose text is wrapped in
/// \u{01} bytes, `\u{01}ACTION waves\u{01}`. /me is the one users see; the
/// rest are queries other clients answer automatically.
struct CTCP: Sendable, Hashable {
    var command: String
    var argument: String?

    private static let delimiter: Character = "\u{01}"

    /// Parses message text; nil when it is ordinary text. The closing \u{01}
    /// is optional because some clients leave it off.
    init?(text: String) {
        guard text.first == CTCP.delimiter, text.count > 1 else { return nil }
        var body = text.dropFirst()
        if body.last == CTCP.delimiter { body = body.dropLast() }
        guard !body.isEmpty else { return nil }
        if let space = body.firstIndex(of: " ") {
            command = body[..<space].uppercased()
            argument = String(body[body.index(after: space)...])
        } else {
            command = body.uppercased()
            argument = nil
        }
    }

    init(command: String, argument: String? = nil) {
        self.command = command.uppercased()
        self.argument = argument
    }

    var text: String {
        if let argument { return "\u{01}\(command) \(argument)\u{01}" }
        return "\u{01}\(command)\u{01}"
    }

    /// The automatic reply to a query, sent as a NOTICE; nil for commands
    /// that are not queries (ACTION) or that are not answered. Without a
    /// `version`, VERSION is not answered: the client stays anonymous.
    func reply(version: String?, now: Date = .now) -> CTCP? {
        switch command {
        case "VERSION": version.map { CTCP(command: "VERSION", argument: $0) }
        case "PING": CTCP(command: "PING", argument: argument)
        case "TIME": CTCP(command: "TIME", argument: now.formatted(.iso8601))
        case "CLIENTINFO":
            CTCP(command: "CLIENTINFO", argument: version == nil ? "ACTION CLIENTINFO PING TIME"
                                                                 : "ACTION CLIENTINFO PING TIME VERSION")
        default: nil
        }
    }
}
