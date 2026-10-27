import Foundation

/// Where an event came from: where a reply goes.
struct ScriptOrigin: Equatable, Sendable {
    var session: UUID
    /// The channel, or the nick of a private chat; empty for the server window.
    var target: String
    var isChannel: Bool
}

/// Something that happened, as scripts are told of it (SCRIPTING.md §6).
struct ScriptEvent: Sendable {
    var id: String
    /// The event's name, as triggers name it.
    var on: String
    var time = Date.now
    var networkID: UUID?
    var network: String?
    /// For the filters: the channel; for private events, the nick; for `run`,
    /// the conversation it was typed in.
    var channel: String?
    var nick: String?
    var text: String?
    var isSelf: Bool?
    var isIgnored = false
    /// The event's own fields, sent as they are (§6.2).
    var fields: [String: JSON] = [:]
    var origin: ScriptOrigin?
    /// For `run`: the words typed after the name.
    var arguments: [String] = []

    /// Events whose lines are someone's text: own lines left out unless asked.
    static let textual: Set<String> = ["message", "action", "notice", "private_message", "new_private_chat", "mention"]

    nonisolated(unsafe) private static var counter = 0
    private static let lock = NSLock()

    static func nextID() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "e\(counter)"
    }

    init(on: String, network: String? = nil, networkID: UUID? = nil, channel: String? = nil, nick: String? = nil,
         text: String? = nil, isSelf: Bool? = nil, fields: [String: JSON] = [:], origin: ScriptOrigin? = nil) {
        id = ScriptEvent.nextID()
        self.on = on
        self.network = network
        self.networkID = networkID
        self.channel = channel
        self.nick = nick
        self.text = text
        self.isSelf = isSelf
        self.fields = fields
        self.origin = origin
    }

    /// The event as a JSON line: the common fields and its own.
    func json(groups: [String] = []) -> JSON {
        var object = fields
        object["type"] = "event"
        object["id"] = .string(id)
        object["event"] = .string(on)
        object["time"] = JSON(time)
        if let network { object["network"] = .string(network) }
        if let networkID { object["network_id"] = .string(networkID.uuidString) }
        if !groups.isEmpty { object["groups"] = JSON(groups) }
        return .object(object)
    }

    /// The environment variables of a one-shot script (§12).
    func environment(groups: [String], me: String?) -> [String: String] {
        var values: [String: String] = [
            "IRCTELL_EVENT": on,
            "IRCTELL_TIME": LogArchive.formatTime(time.timeIntervalSince1970),
        ]
        values["IRCTELL_NETWORK"] = network
        values["IRCTELL_NETWORK_ID"] = networkID?.uuidString
        values["IRCTELL_ME"] = me
        values["IRCTELL_CHANNEL"] = channel
        values["IRCTELL_NICK"] = nick
        values["IRCTELL_USER"] = fields["user"]?.string
        values["IRCTELL_HOST"] = fields["host"]?.string
        values["IRCTELL_ACCOUNT"] = fields["account"]?.string
        values["IRCTELL_TEXT"] = text
        values["IRCTELL_RAW_TEXT"] = fields["raw_text"]?.string ?? text
        if on == "run" { values["IRCTELL_ARGS"] = arguments.joined(separator: " ") }
        for (index, group) in groups.enumerated() { values["IRCTELL_GROUP_\(index + 1)"] = group }
        return values.compactMapValues { $0 }
    }

    /// For a service in the text protocol: nick, channel and text, by tabs.
    var textLine: String {
        [nick ?? "", channel ?? "", (text ?? "").replacingOccurrences(of: "\n", with: " ")]
            .joined(separator: "\t")
    }
}
