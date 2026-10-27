import Foundation

/// The source of a message: `nick!user@host` for a user, or a bare server name.
struct IRCPrefix: Sendable, Hashable, CustomStringConvertible {
    /// The nick for a user, the server name for a server.
    var name: String
    var user: String?
    var host: String?

    init(name: String, user: String? = nil, host: String? = nil) {
        self.name = name
        self.user = user
        self.host = host
    }

    init(parsing raw: Substring) {
        var rest = raw
        var host: String?
        var user: String?
        if let at = rest.firstIndex(of: "@") {
            host = String(rest[rest.index(after: at)...])
            rest = rest[..<at]
        }
        if let bang = rest.firstIndex(of: "!") {
            user = String(rest[rest.index(after: bang)...])
            rest = rest[..<bang]
        }
        self.init(name: String(rest), user: user, host: host)
    }

    var description: String {
        var text = name
        if let user { text += "!" + user }
        if let host { text += "@" + host }
        return text
    }
}

/// One line of the IRC protocol, IRCv3 message tags included:
///
///     [@tag=value;tag SP] [:prefix SP] COMMAND [param ...] [:trailing]
///
/// The trailing parameter is not distinguished from the others once parsed --
/// it is simply the last one -- because the protocol gives it no other meaning.
struct IRCMessage: Sendable, Hashable, CustomStringConvertible {
    /// Tag values are already unescaped; a tag without `=` maps to "".
    var tags: [String: String]
    var prefix: IRCPrefix?
    /// Upper-cased verb, or the three-digit numeric as a string.
    var command: String
    var params: [String]

    init(tags: [String: String] = [:], prefix: IRCPrefix? = nil,
         command: String, params: [String] = []) {
        self.tags = tags
        self.prefix = prefix
        self.command = command.uppercased()
        self.params = params
    }

    init(_ command: String, _ params: String...) {
        self.init(command: command, params: params)
    }

    /// Parses one line, with or without its CR LF. Returns nil only for lines
    /// that have no command at all; everything else the server sends is taken
    /// as it comes, since a client that rejects odd lines loses messages.
    init?(parsing line: String) {
        var rest = Substring(line)
        // "\r\n" is one Character in Swift, so test for it as well as its parts.
        while let last = rest.last, last == "\r\n" || last == "\r" || last == "\n" { rest = rest.dropLast() }

        var tags: [String: String] = [:]
        if rest.first == "@" {
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            tags = IRCMessage.parseTags(rest[rest.index(after: rest.startIndex)..<end])
            rest = rest[end...].drop { $0 == " " }
        }

        var prefix: IRCPrefix?
        if rest.first == ":" {
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            prefix = IRCPrefix(parsing: rest[rest.index(after: rest.startIndex)..<end])
            rest = rest[end...].drop { $0 == " " }
        }

        let commandEnd = rest.firstIndex(of: " ") ?? rest.endIndex
        let command = rest[..<commandEnd]
        guard !command.isEmpty else { return nil }
        rest = rest[commandEnd...]

        var params: [String] = []
        while true {
            rest = rest.drop { $0 == " " }
            if rest.isEmpty { break }
            if rest.first == ":" {
                params.append(String(rest.dropFirst()))
                break
            }
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            params.append(String(rest[..<end]))
            rest = rest[end...]
        }

        self.init(tags: tags, prefix: prefix, command: String(command), params: params)
    }

    /// The line to send, without CR LF. CR, LF and NUL are removed from every
    /// part: a nick or message text containing them would otherwise end the
    /// line early and let the rest be read as a second, injected command.
    var serialized: String {
        var parts: [String] = []
        if !tags.isEmpty {
            let encoded = tags.keys.sorted().map { key -> String in
                let value = tags[key] ?? ""
                let cleanKey = IRCMessage.stripLineBreaks(key)
                return value.isEmpty ? cleanKey : cleanKey + "=" + IRCMessage.escapeTagValue(value)
            }
            parts.append("@" + encoded.joined(separator: ";"))
        }
        if let prefix { parts.append(":" + IRCMessage.stripLineBreaks(prefix.description)) }
        parts.append(IRCMessage.stripLineBreaks(command))
        for (index, param) in params.enumerated() {
            let clean = IRCMessage.stripLineBreaks(param)
            let isLast = index == params.count - 1
            if isLast && (clean.isEmpty || clean.contains(" ") || clean.hasPrefix(":")) {
                parts.append(":" + clean)
            } else {
                parts.append(clean)
            }
        }
        return parts.joined(separator: " ")
    }

    var description: String { serialized }

    /// The numeric reply code, when the command is one.
    var numeric: Int? {
        guard command.count == 3, command.allSatisfy(\.isASCII) else { return nil }
        return Int(command)
    }

    /// The IRCv3 `server-time` tag, when the server sent one.
    var serverTime: Date? {
        guard let time = tags["time"] else { return nil }
        return IRCMessage.parseServerTime(time)
    }

    subscript(param index: Int) -> String? {
        params.indices.contains(index) ? params[index] : nil
    }

    // MARK: - Tags

    static func parseTags(_ raw: Substring) -> [String: String] {
        var tags: [String: String] = [:]
        for item in raw.split(separator: ";", omittingEmptySubsequences: true) {
            if let eq = item.firstIndex(of: "=") {
                tags[String(item[..<eq])] = unescapeTagValue(item[item.index(after: eq)...])
            } else {
                tags[String(item)] = ""
            }
        }
        return tags
    }

    static func unescapeTagValue(_ raw: Substring) -> String {
        var result = ""
        var iterator = raw.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\" else { result.append(ch); continue }
            // A lone backslash at the end is dropped, as the spec says.
            guard let next = iterator.next() else { break }
            switch next {
            case ":": result.append(";")
            case "s": result.append(" ")
            case "\\": result.append("\\")
            case "r": result.append("\r")
            case "n": result.append("\n")
            default: result.append(next)
            }
        }
        return result
    }

    static func escapeTagValue(_ value: String) -> String {
        var result = ""
        // Scalars, not Characters: "\r\n" is a single Character.
        for scalar in value.unicodeScalars {
            switch scalar {
            case ";": result += "\\:"
            case " ": result += "\\s"
            case "\\": result += "\\\\"
            case "\r": result += "\\r"
            case "\n": result += "\\n"
            case "\0": break
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func stripLineBreaks(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            return text
        }
        return String(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" })
    }

    private static let fractionalTime = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondTime = Date.ISO8601FormatStyle()

    static func parseServerTime(_ text: String) -> Date? {
        (try? fractionalTime.parse(text)) ?? (try? wholeSecondTime.parse(text))
    }
}
