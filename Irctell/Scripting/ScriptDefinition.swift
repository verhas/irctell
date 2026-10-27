import Foundation

/// A program of the user's that Irctell starts when something happens, and
/// talks to through its standard input and output. See SCRIPTING.md.
struct ScriptDefinition: Codable, Hashable, Identifiable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case oneShot = "one-shot", service
    }

    /// The protocol on standard input and output.
    enum Format: String, Codable, CaseIterable, Sendable {
        case text, json
    }

    enum Restart: String, Codable, CaseIterable, Sendable {
        case always, onFailure = "on-failure", never
    }

    var id = UUID()
    var name: String
    var enabled = true
    /// The program and its arguments; not run through a shell.
    var command: [String]
    var directory = ScriptDefinition.defaultDirectory
    /// The profile's `scripts` folder.
    static var defaultDirectory: String { IrctellHome.displayPath + "/scripts" }
    var environment: [String: String] = [:]
    var mode = Mode.oneShot
    var `protocol` = Format.text
    var triggers: [ScriptTrigger] = []
    var permissions = ScriptPermissions()
    /// One-shot: seconds before it is stopped.
    var timeout = 10
    /// One-shot: how many may run at once.
    var maxInstances = 4
    /// Lines it may send to IRC in a minute.
    var linesPerMinute = 30
    var restart = Restart.onFailure

    init(name: String, command: [String], mode: Mode = .oneShot, protocol: Format = .text,
         triggers: [ScriptTrigger] = []) {
        self.name = name
        self.command = command
        self.mode = mode
        self.protocol = `protocol`
        self.triggers = triggers
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, command, directory, environment, mode, `protocol`, triggers, permissions, timeout
        case maxInstances = "max_instances", linesPerMinute = "lines_per_minute", restart
    }

    /// Every field but the name and command may be left out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode([String].self, forKey: .command)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        directory = try c.decodeIfPresent(String.self, forKey: .directory) ?? ScriptDefinition.defaultDirectory
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .oneShot
        `protocol` = try c.decodeIfPresent(Format.self, forKey: .protocol) ?? .text
        triggers = try c.decodeIfPresent([ScriptTrigger].self, forKey: .triggers) ?? []
        permissions = try c.decodeIfPresent(ScriptPermissions.self, forKey: .permissions) ?? ScriptPermissions()
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? 10
        maxInstances = try c.decodeIfPresent(Int.self, forKey: .maxInstances) ?? 4
        linesPerMinute = try c.decodeIfPresent(Int.self, forKey: .linesPerMinute) ?? 30
        restart = try c.decodeIfPresent(Restart.self, forKey: .restart) ?? .onFailure
    }

    /// The command as one line, the words quoted where they need it.
    var commandLine: String {
        command.map { word in
            word.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" })
                ? "\"" + word.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : word
        }.joined(separator: " ")
    }

    /// A command line split into words as a shell would: spaces separate,
    /// quotes keep together, a backslash takes the next character as it is.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
                started = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character == " " || character == "\t" {
                if started || !current.isEmpty { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }

    /// Seconds in "30s", "10m", "2h", "1d"; a bare number is seconds.
    static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last else { return nil }
        let factors: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let factor = factors[unit], let value = Double(trimmed.dropLast()) { return value * factor }
        return Double(trimmed)
    }
}

/// What starts a script, or reaches it: an event, narrowed by filters.
struct ScriptTrigger: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// The event's name: `message`, `private_message`, `join`, `timer`, `run`… (SCRIPTING.md §3.2)
    var on: String
    var networks: [String] = []
    /// Channel patterns: * and ?, separated by commas or spaces.
    var channels = ""
    var nicks = ""
    var notNicks = ""
    /// A regular expression on the text, ignoring case.
    var text = ""
    /// Only own lines (true), only others' (false), or as `lines` says.
    var isSelf: Bool?
    /// Whose lines: "others", "mine" or "all"; empty for the default --
    /// others' lines for text events, everyone's for the rest.
    var lines = ""
    var ignored = false
    /// For `timer`: "10m", or a time of day "08:30".
    var every = ""
    var at = ""

    init(on: String, networks: [String] = [], channels: String = "", nicks: String = "", notNicks: String = "",
         text: String = "", isSelf: Bool? = nil, lines: String = "", every: String = "", at: String = "") {
        self.lines = lines
        self.on = on
        self.networks = networks
        self.channels = channels
        self.nicks = nicks
        self.notNicks = notNicks
        self.text = text
        self.isSelf = isSelf
        self.every = every
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case id, on, networks, channels, nicks, notNicks = "not_nicks", text, isSelf = "self", lines, ignored, every, at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        on = try c.decode(String.self, forKey: .on)
        networks = try c.decodeIfPresent([String].self, forKey: .networks) ?? []
        channels = try c.decodeIfPresent(String.self, forKey: .channels) ?? ""
        nicks = try c.decodeIfPresent(String.self, forKey: .nicks) ?? ""
        notNicks = try c.decodeIfPresent(String.self, forKey: .notNicks) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf)
        lines = try c.decodeIfPresent(String.self, forKey: .lines) ?? ""
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
        every = try c.decodeIfPresent(String.self, forKey: .every) ?? ""
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
    }

    /// The events a trigger can name, with what they are for the editor.
    static let events: [(name: String, title: String)] = [
        ("message", "A message in a channel"), ("action", "A /me in a channel"), ("notice", "A notice"),
        ("private_message", "A private message"), ("new_private_chat", "A new private conversation"),
        ("mention", "A line mentioning you"), ("join", "Someone joins"), ("part", "Someone leaves"),
        ("quit", "Someone quits"), ("kick", "Someone is kicked"), ("nick", "A nick change"),
        ("topic", "A topic change"), ("mode", "A mode change"), ("invite", "An invitation"),
        ("ctcp", "A CTCP query"), ("memo", "A new memo"), ("connect", "Connected to a network"),
        ("disconnect", "Disconnected"), ("away", "Marked away"), ("back", "Back from away"),
        ("timer", "On a schedule"), ("startup", "Irctell starts"), ("shutdown", "Irctell quits"),
        ("run", "/run NAME typed"), ("nick_action", "Picked in a nick's Actions menu"),
        ("menu", "Picked in the Scripts menu or window"),
    ]

    /// Whether the event passes the trigger's filters.
    func matches(_ event: ScriptEvent) -> (Bool, groups: [String]) {
        guard event.on == on else { return (false, []) }
        if !networks.isEmpty {
            guard let network = event.network,
                  networks.contains(where: { $0.caseInsensitiveCompare(network) == .orderedSame
                      || $0.caseInsensitiveCompare(event.networkID?.uuidString ?? "") == .orderedSame }) else { return (false, []) }
        }
        if !NickAction.patterns(channels).isEmpty {
            guard let channel = event.channel,
                  NickAction.patterns(channels).contains(where: { NickAction.matches(channel, pattern: $0) }) else {
                return (false, [])
            }
        }
        if !NickAction.patterns(nicks).isEmpty {
            guard let nick = event.nick, NickAction.patterns(nicks).contains(where: { ScriptTrigger.matches(nick, $0) })
            else { return (false, []) }
        }
        if let nick = event.nick, NickAction.patterns(notNicks).contains(where: { ScriptTrigger.matches(nick, $0) }) {
            return (false, [])
        }
        if let mine = event.isSelf {
            let wanted: Bool? = switch lines.lowercased() {
            case "all": nil
            case "mine": true
            case "others": false
            default: isSelf ?? (ScriptEvent.textual.contains(on) ? false : nil)
            }
            if let wanted, wanted != mine { return (false, []) }
        }
        if event.isIgnored && !ignored { return (false, []) }
        guard !text.isEmpty else { return (true, []) }
        guard let regex = try? NSRegularExpression(pattern: text, options: .caseInsensitive) else { return (false, []) }
        let subject = event.text ?? ""
        guard let found = regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) else {
            return (false, [])
        }
        let groups = (1..<max(found.numberOfRanges, 1)).map { index in
            Range(found.range(at: index), in: subject).map { String(subject[$0]) } ?? ""
        }
        return (true, groups)
    }

    /// A nick against a pattern, * and ?, ignoring case.
    static func matches(_ nick: String, _ pattern: String) -> Bool {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return nick.range(of: regex + "$", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// What a script may do. Everything, unless restricted (SCRIPTING.md §9).
struct ScriptPermissions: Codable, Hashable, Sendable {
    /// The networks it hears from and acts on; empty for all.
    var networks: [String] = []
    /// Where it may send: "" for anywhere, "origin", "channels", "private",
    /// "none", or channel and nick patterns.
    var sendTo = ""
    /// The IRC commands it may run, without the slash; empty for all,
    /// ["none"] for none.
    var commands: [String] = []
    var raw = true
    var channelsJoined = true
    var readLog = true
    var ignored = false
    var dryRun = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case networks, sendTo = "send_to", commands, raw, channelsJoined = "channels_joined", readLog = "read_log"
        case ignored, dryRun = "dry_run"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        networks = try c.decodeIfPresent([String].self, forKey: .networks) ?? []
        sendTo = try c.decodeIfPresent(String.self, forKey: .sendTo) ?? ""
        commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
        raw = try c.decodeIfPresent(Bool.self, forKey: .raw) ?? true
        channelsJoined = try c.decodeIfPresent(Bool.self, forKey: .channelsJoined) ?? true
        readLog = try c.decodeIfPresent(Bool.self, forKey: .readLog) ?? true
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
    }

    func allowsNetwork(_ name: String?, id: UUID?) -> Bool {
        guard !networks.isEmpty else { return true }
        return networks.contains { allowed in
            allowed.caseInsensitiveCompare(name ?? "") == .orderedSame
                || allowed.caseInsensitiveCompare(id?.uuidString ?? "") == .orderedSame
        }
    }

    /// Whether it may send to the target; `isOrigin` when that is where the
    /// event came from.
    func allowsSending(to target: String, isChannel: Bool, isOrigin: Bool) -> Bool {
        let rule = sendTo.trimmingCharacters(in: .whitespaces).lowercased()
        switch rule {
        case "": return true
        case "none": return false
        case "origin": return isOrigin
        case "channels": return isChannel
        case "private": return !isChannel
        default:
            return NickAction.patterns(sendTo).contains { pattern in
                isChannel ? NickAction.matches(target, pattern: pattern) : ScriptTrigger.matches(target, pattern)
            }
        }
    }

    func allowsCommand(_ command: String) -> Bool {
        guard !commands.isEmpty else { return true }
        if commands.map({ $0.lowercased() }) == ["none"] { return false }
        return commands.contains { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) == command.lowercased() }
    }
}

/// The scripts, kept in the settings.
@MainActor
final class ScriptStore {
    static let shared = ScriptStore()
    static let key = "scripts"

    private let settings: SettingsStore

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    var list: [ScriptDefinition] {
        get {
            guard let object = settings.object(forKey: ScriptStore.key),
                  let list = SettingsStore.decode([ScriptDefinition].self, from: object) else { return [] }
            return list
        }
        set { settings.set(SettingsStore.plistObject(newValue), forKey: ScriptStore.key) }
    }
}
