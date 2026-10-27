import Foundation

/// What a WHOIS told about a user, kept so the nick list can show it on hover.
struct UserInfo: Sendable, Hashable {
    var nick: String
    var username: String?
    var host: String?
    var realName: String?
    var server: String?
    var serverInfo: String?
    var account: String?
    var channels: [String] = []
    var idleSeconds: Int?
    var signedOn: Date?
    var awayMessage: String?
    var actualHost: String?
    var isOperator = false
    var isSecure = false
    var isBot = false
    /// Further WHOIS lines that have no field of their own.
    var notes: [String] = []
    /// When the WHOIS came in.
    var updated: Date

    init(nick: String, updated: Date) {
        self.nick = nick
        self.updated = updated
    }

    /// Several lines, for a tooltip.
    var summary: String {
        var lines: [String] = []
        if let username, let host {
            lines.append("\(nick) (\(username)@\(host))")
        } else {
            lines.append(nick)
        }
        if let realName, !realName.isEmpty { lines.append("Real name: \(realName)") }
        if let account { lines.append("Account: \(account)") }
        if let actualHost { lines.append("Connecting from: \(actualHost)") }
        if let server {
            lines.append("Server: \(server)" + (serverInfo.map { $0.isEmpty ? "" : " — \($0)" } ?? ""))
        }
        if !channels.isEmpty { lines.append("Channels: \(channels.joined(separator: " "))") }
        var times: [String] = []
        if let idleSeconds {
            times.append("idle \(Duration.seconds(idleSeconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))")
        }
        if let signedOn { times.append("signed on \(signedOn.formatted(date: .abbreviated, time: .shortened))") }
        if !times.isEmpty { lines.append(times.joined(separator: ", ").capitalizedFirst) }
        if let awayMessage { lines.append("Away: \(awayMessage)") }
        if isOperator { lines.append("IRC operator") }
        if isBot { lines.append("Bot") }
        if isSecure { lines.append("Uses a secure connection") }
        lines += notes
        lines.append("WHOIS from \(updated.formatted(date: .omitted, time: .shortened))")
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
