import Foundation
import Observation

/// Runs the user's scripts: matches events to their triggers, starts them,
/// feeds them, and does what they ask, within their permissions and limits.
/// See SCRIPTING.md.
@MainActor @Observable
final class ScriptHost {
    static let shared = ScriptHost()
    static let protocolVersion = 1

    /// What the Scripts window shows of a script.
    struct Status: Equatable {
        enum State: String { case idle, running, failed, disabled }
        var state = State.idle
        var running = 0
        var lastStarted: Date?
        var lastExit: Int32?
        var output: [String] = []
        var errors: [String] = []
    }

    private(set) var statuses: [UUID: Status] = [:]
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let store: ScriptStore
    @ObservationIgnored private var definitions: [ScriptDefinition] = []

    /// A running service, with what it subscribed to and the events it was
    /// sent, for replies.
    private final class Service {
        let runner: ScriptRunner
        var subscriptions: [ScriptTrigger] = []
        var lastOrigin: ScriptOrigin?
        init(runner: ScriptRunner) { self.runner = runner }
    }

    @ObservationIgnored private var services: [UUID: Service] = [:]
    @ObservationIgnored private var oneShots: [UUID: [ScriptRunner]] = [:]
    @ObservationIgnored private var waiting: [UUID: [(ScriptEvent, [String])]] = [:]
    /// Event IDs to where they came from, per runner.
    @ObservationIgnored private var origins: [UUID: [String: ScriptOrigin]] = [:]
    /// The default place for a runner's replies: its event's origin.
    @ObservationIgnored private var defaultOrigins: [UUID: ScriptOrigin] = [:]
    @ObservationIgnored private var sentLines: [UUID: [Date]] = [:]
    @ObservationIgnored private var overflowSince: [UUID: Date] = [:]
    @ObservationIgnored private var failures: [UUID: [Date]] = [:]
    @ObservationIgnored private var scriptTimers: [UUID: [String: Task<Void, Never>]] = [:]
    @ObservationIgnored private var timerFired: [UUID: Date] = [:]
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var started = Date.now

    init(store: ScriptStore = .shared) {
        self.store = store
        // A script gone: writing to it must not end Irctell.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Lifecycle

    func start() {
        started = .now
        reload()
        dispatch(ScriptEvent(on: "startup"))
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.fireTimers()
            }
        }
    }

    /// At quit: the scripts asking for it told, then all stopped.
    func shutDown() async {
        dispatch(ScriptEvent(on: "shutdown"))
        try? await Task.sleep(for: .seconds(1))
        clock?.cancel()
        for id in services.keys { stopService(id, reason: "quitting") }
        for runners in oneShots.values { runners.forEach { $0.stop(grace: .milliseconds(500)) } }
    }

    /// The definitions read again: changed services restarted, disabled
    /// ones stopped, services started.
    func reload() {
        let old = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        definitions = store.list
        for definition in definitions {
            var status = statuses[definition.id] ?? Status()
            if !definition.enabled { status.state = .disabled } else if status.state == .disabled { status.state = .idle }
            statuses[definition.id] = status
        }
        for (id, _) in services {
            guard let definition = definitions.first(where: { $0.id == id }), definition.enabled,
                  old[id] == definition else {
                stopService(id, reason: "restart")
                continue
            }
        }
        for definition in definitions where definition.enabled && definition.mode == .service
            && services[definition.id] == nil && !definition.triggers.contains(where: { $0.on == "connect" }) {
            startService(definition)
        }
        statuses = statuses.filter { id, _ in definitions.contains { $0.id == id } }
    }

    var scripts: [ScriptDefinition] { definitions }

    // MARK: - Events

    /// An event from a network or Irctell: to every script it reaches.
    func dispatch(_ event: ScriptEvent) {
        // Hand-picked events reach only the script picked.
        guard !["run", "nick_action", "menu", "timer"].contains(event.on) else { return }
        for definition in definitions where definition.enabled {
            guard definition.permissions.allowsNetwork(event.network, id: event.networkID),
                  !event.isIgnored || definition.permissions.ignored else { continue }
            let subscriptions = services[definition.id]?.subscriptions ?? []
            for trigger in definition.triggers + subscriptions {
                let (matched, groups) = trigger.matches(event)
                if matched {
                    deliver(event, groups: groups, to: definition)
                    break
                }
            }
        }
    }

    private func deliver(_ event: ScriptEvent, groups: [String], to definition: ScriptDefinition) {
        switch definition.mode {
        case .service:
            if services[definition.id] == nil {
                guard statuses[definition.id]?.state != .failed else { return }
                startService(definition)
            }
            guard let service = services[definition.id] else { return }
            if let origin = event.origin {
                remember(origin, for: event.id, runner: service.runner.id)
                service.lastOrigin = origin
            }
            switch definition.protocol {
            case .json: service.runner.send(event.json(groups: groups).line)
            case .text: service.runner.send(event.textLine)
            }
        case .oneShot:
            launch(definition, event: event, groups: groups)
        }
    }

    private func remember(_ origin: ScriptOrigin, for eventID: String, runner: UUID) {
        var known = origins[runner] ?? [:]
        if known.count > 500 { known.removeAll() }
        known[eventID] = origin
        origins[runner] = known
    }

    /// `/run NAME words`: the script with a `run` trigger of that name.
    @discardableResult
    func run(named name: String, arguments: [String], in session: NetworkSession, buffer: ChatBuffer) -> Bool {
        guard let definition = definitions.first(where: {
            $0.enabled && $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.triggers.contains { $0.on == "run" }
        }) else {
            session.addInfo("No script “\(name)” with a /run trigger. Network › Scripts… lists them.", kind: .error, to: buffer)
            return false
        }
        var event = conversationEvent("run", session: session, buffer: buffer)
        event.arguments = arguments
        event.text = arguments.joined(separator: " ")
        event.fields["arguments"] = JSON(arguments)
        event.fields["text"] = .string(event.text ?? "")
        deliver(event, groups: [], to: definition)
        return true
    }

    /// The scripts offered in a nick's Actions menu in the conversation.
    func nickActionScripts(in buffer: ChatBuffer) -> [ScriptDefinition] {
        definitions.filter { definition in
            definition.enabled && definition.triggers.contains { trigger in
                trigger.on == "nick_action" && (NickAction.patterns(trigger.channels).isEmpty
                    || (buffer.kind == .channel && NickAction.patterns(trigger.channels)
                        .contains { NickAction.matches(buffer.name, pattern: $0) }))
            }
        }
    }

    func runNickAction(_ definition: ScriptDefinition, nick: String, session: NetworkSession, buffer: ChatBuffer) {
        var event = conversationEvent("nick_action", session: session, buffer: buffer)
        event.nick = nick
        event.fields["nick"] = .string(nick)
        deliver(event, groups: [], to: definition)
    }

    /// The Scripts menu or window's Run.
    func runFromMenu(_ id: UUID) {
        guard let definition = definitions.first(where: { $0.id == id }) else { return }
        var event = ScriptEvent(on: "menu")
        if let session = app?.selectedSession, let buffer = session.selectedBuffer {
            event = conversationEvent("menu", session: session, buffer: buffer)
        }
        deliver(event, groups: [], to: definition)
    }

    private func conversationEvent(_ on: String, session: NetworkSession, buffer: ChatBuffer) -> ScriptEvent {
        let target = buffer.kind == .server ? "" : buffer.name
        var event = ScriptEvent(on: on, network: session.displayName, networkID: session.id, channel: target,
                                origin: ScriptOrigin(session: session.id, target: target, isChannel: buffer.kind == .channel))
        event.fields["conversation"] = .object(["channel": buffer.kind == .channel ? .string(target) : .null,
                                                "nick": buffer.kind == .query ? .string(target) : .null,
                                                "kind": .string(buffer.kind.rawValue)])
        return event
    }

    // MARK: - Starting

    private func baseEnvironment(_ definition: ScriptDefinition) -> [String: String] {
        let data = IrctellHome.directory.appending(path: "script-data/\(LogArchive.safeName(definition.name))")
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return ["IRCTELL_VERSION": version, "IRCTELL_PROTOCOL": definition.protocol.rawValue,
                "IRCTELL_PROTOCOL_VERSION": String(ScriptHost.protocolVersion), "IRCTELL_SCRIPT": definition.name,
                "IRCTELL_HOME": IrctellHome.directory.path, "IRCTELL_PROFILE": IrctellHome.profileName,
                "IRCTELL_DATA": data.path]
    }

    /// The first line a JSON script gets.
    private func hello(_ definition: ScriptDefinition) -> JSON {
        let sessions = app?.sessions ?? []
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return ["type": "hello", "version": JSON(ScriptHost.protocolVersion), "script": .string(definition.name),
                    "mode": .string(definition.mode.rawValue), "app": .string("Irctell \(version)"),
                    "me": .object(Dictionary(sessions.filter(\.isConnected).map { ($0.displayName, JSON.string($0.nick)) },
                                             uniquingKeysWith: { first, _ in first })),
                    "networks": .array(sessions.map { session in
                        ["name": .string(session.displayName), "id": .string(session.id.uuidString),
                         "connected": JSON(session.isConnected), "nick": .string(session.nick)]
                    })]
    }

    private func makeRunner(_ definition: ScriptDefinition) -> ScriptRunner {
        let runner = ScriptRunner(definition: definition)
        runner.onLine = { [weak self, weak runner] line in
            guard let self, let runner else { return }
            self.note(definition.id) { $0.output = Array(($0.output + [line]).suffix(50)) }
            self.handle(line, from: runner, definition: definition)
        }
        runner.onError = { [weak self] line in
            AppLog.info("scripts", "\(definition.name): \(line)")
            self?.note(definition.id) { $0.errors = Array(($0.errors + [line]).suffix(200)) }
        }
        return runner
    }

    private func note(_ id: UUID, _ change: (inout Status) -> Void) {
        var status = statuses[id] ?? Status()
        change(&status)
        statuses[id] = status
    }

    private func startService(_ definition: ScriptDefinition) {
        let runner = makeRunner(definition)
        runner.onExit = { [weak self] status, stopped in
            self?.serviceEnded(definition, status: status, stopped: stopped)
        }
        do {
            try runner.start(arguments: [], environment: baseEnvironment(definition))
        } catch {
            AppLog.error("scripts", "\(definition.name): not started: \(error.localizedDescription)")
            note(definition.id) { $0.state = .failed; $0.errors.append(error.localizedDescription) }
            return
        }
        services[definition.id] = Service(runner: runner)
        AppLog.info("scripts", "\(definition.name): started as a service")
        note(definition.id) { $0.state = .running; $0.running = 1; $0.lastStarted = .now }
        if definition.protocol == .json { runner.send(hello(definition).line) }
    }

    private func stopService(_ id: UUID, reason: String) {
        guard let service = services.removeValue(forKey: id) else { return }
        if service.runner.definition.protocol == .json {
            service.runner.send(JSON.object(["type": "stop", "reason": .string(reason)]).line)
        }
        service.runner.stop()
        cancelTimers(of: service.runner.id)
        note(id) { $0.running = 0; if $0.state == .running { $0.state = .idle } }
    }

    private func serviceEnded(_ definition: ScriptDefinition, status: Int32, stopped: Bool) {
        if let service = services[definition.id], !service.runner.isRunning { services[definition.id] = nil }
        AppLog.log(status == 0 || stopped ? .info : .warning, "scripts",
                   "\(definition.name): ended with status \(status)\(stopped ? ", stopped" : "")")
        note(definition.id) { $0.running = 0; $0.lastExit = status; if $0.state == .running { $0.state = .idle } }
        guard !stopped, let current = definitions.first(where: { $0.id == definition.id }), current.enabled else { return }
        let restarting = current.restart == .always || (current.restart == .onFailure && status != 0)
        guard restarting else { return }
        let recent = (failures[definition.id] ?? []).filter { Date.now.timeIntervalSince($0) < 600 } + [.now]
        failures[definition.id] = recent
        guard recent.count < 5 else {
            AppLog.error("scripts", "\(definition.name): failed 5 times in 10 minutes, given up")
            note(definition.id) { $0.state = .failed }
            return
        }
        let delay = min(300, pow(2, Double(recent.count - 1)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.services[definition.id] == nil,
                  let latest = self.definitions.first(where: { $0.id == definition.id }), latest.enabled else { return }
            self.startService(latest)
        }
    }

    /// A one-shot for the event, or waiting for a free place.
    private func launch(_ definition: ScriptDefinition, event: ScriptEvent, groups: [String]) {
        let running = (oneShots[definition.id] ?? []).filter(\.isRunning)
        guard running.count < max(definition.maxInstances, 1) else {
            var queue = waiting[definition.id] ?? []
            queue.append((event, groups))
            if queue.count > 20 { queue.removeFirst(queue.count - 20) }
            waiting[definition.id] = queue
            return
        }
        let runner = makeRunner(definition)
        runner.onExit = { [weak self, weak runner] status, stopped in
            guard let self else { return }
            self.oneShots[definition.id]?.removeAll { $0 === runner || !$0.isRunning }
            if let runner { self.cancelTimers(of: runner.id); self.origins[runner.id] = nil; self.defaultOrigins[runner.id] = nil }
            let left = self.oneShots[definition.id]?.count ?? 0
            self.note(definition.id) { $0.running = left; $0.lastExit = status; if left == 0, $0.state == .running { $0.state = .idle } }
            if status != 0, !stopped {
                AppLog.warning("scripts", "\(definition.name): ended with status \(status)")
                if event.on == "run", let origin = event.origin, let errors = self.statuses[definition.id]?.errors.suffix(3),
                   (self.statuses[definition.id]?.output.isEmpty ?? true) {
                    self.show("\(definition.name) failed (status \(status)): \(errors.joined(separator: " / "))",
                              at: origin, error: true)
                }
            }
            if var queue = self.waiting[definition.id], !queue.isEmpty {
                let (next, nextGroups) = queue.removeFirst()
                self.waiting[definition.id] = queue
                self.launch(definition, event: next, groups: nextGroups)
            }
        }
        var environment = baseEnvironment(definition)
        let me = event.networkID.flatMap { app?.session(for: $0)?.nick }
        environment.merge(event.environment(groups: groups, me: me)) { _, new in new }
        let arguments = definition.protocol == .text ? (event.on == "run" ? event.arguments : groups) : []
        do {
            try runner.start(arguments: arguments, environment: environment)
        } catch {
            AppLog.error("scripts", "\(definition.name): not started: \(error.localizedDescription)")
            note(definition.id) { $0.state = .failed; $0.errors.append(error.localizedDescription) }
            if let origin = event.origin, event.on == "run" {
                show("\(definition.name) not started: \(error.localizedDescription)", at: origin, error: true)
            }
            return
        }
        oneShots[definition.id, default: []].append(runner)
        AppLog.debug("scripts", "\(definition.name): started for \(event.on)\(event.channel.map { " in \($0)" } ?? "")")
        if let origin = event.origin ?? frontOrigin() {
            defaultOrigins[runner.id] = origin
            remember(origin, for: event.id, runner: runner.id)
        }
        note(definition.id) { $0.state = .running; $0.running = (self.oneShots[definition.id] ?? []).count; $0.lastStarted = .now }
        switch definition.protocol {
        case .text:
            runner.send(event.text ?? "")
        case .json:
            runner.send(hello(definition).line)
            runner.send(event.json(groups: groups).line)
        }
        runner.closeInput()
        let timeout = max(definition.timeout, 1)
        Task { [weak runner] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let runner, runner.isRunning else { return }
            AppLog.warning("scripts", "\(definition.name): over its \(timeout) s, stopped")
            runner.stop(grace: .seconds(2))
        }
    }

    /// The conversation in front, for replies to events that have no place.
    private func frontOrigin() -> ScriptOrigin? {
        guard let session = app?.selectedSession, let buffer = session.selectedBuffer else { return nil }
        return ScriptOrigin(session: session.id, target: buffer.kind == .server ? "" : buffer.name,
                            isChannel: buffer.kind == .channel)
    }

    func stop(_ id: UUID) {
        stopService(id, reason: "disabled")
        for runner in oneShots[id] ?? [] { runner.stop(grace: .seconds(1)) }
        waiting[id] = nil
    }

    func restart(_ id: UUID) {
        stop(id)
        failures[id] = nil
        note(id) { if $0.state == .failed { $0.state = .idle } }
        guard let definition = definitions.first(where: { $0.id == id }), definition.enabled,
              definition.mode == .service else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.startService(definition)
        }
    }

    // MARK: - Timers

    private func fireTimers(now: Date = .now) {
        for definition in definitions where definition.enabled {
            for trigger in definition.triggers where trigger.on == "timer" {
                let key = trigger.id
                let last = timerFired[key] ?? started
                var due = false
                var schedule = ""
                if let seconds = ScriptDefinition.seconds(trigger.every), seconds >= 1 {
                    due = now.timeIntervalSince(last) >= seconds
                    schedule = "every \(trigger.every)"
                } else if !trigger.at.isEmpty, let today = ScriptHost.time(trigger.at, on: now) {
                    due = now >= today && last < today
                    schedule = "at \(trigger.at)"
                }
                guard due else { continue }
                timerFired[key] = now
                let sessions = (app?.sessions ?? []).filter { session in
                    trigger.networks.isEmpty || trigger.networks.contains { $0.caseInsensitiveCompare(session.displayName) == .orderedSame }
                }
                if trigger.networks.isEmpty || sessions.isEmpty {
                    deliver(ScriptEvent(on: "timer", fields: ["schedule": .string(schedule)]), groups: [], to: definition)
                } else {
                    for session in sessions {
                        deliver(ScriptEvent(on: "timer", network: session.displayName, networkID: session.id,
                                            fields: ["schedule": .string(schedule)]), groups: [], to: definition)
                    }
                }
            }
        }
    }

    /// "08:30" today.
    static func time(_ text: String, on day: Date) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    private func cancelTimers(of runner: UUID) {
        scriptTimers[runner]?.values.forEach { $0.cancel() }
        scriptTimers[runner] = nil
    }

    // MARK: - What scripts say

    private func handle(_ line: String, from runner: ScriptRunner, definition: ScriptDefinition) {
        switch definition.protocol {
        case .text: handleText(line, from: runner, definition: definition)
        case .json: handleJSON(line, from: runner, definition: definition)
        }
    }

    /// A text script's line: a message where the event came from, or a
    /// command typed there.
    private func handleText(_ line: String, from runner: ScriptRunner, definition: ScriptDefinition) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let origin = services[definition.id]?.lastOrigin ?? defaultOrigins[runner.id] ?? frontOrigin()
        guard let origin, let session = app?.session(for: origin.session) else {
            AppLog.warning("scripts", "\(definition.name): no conversation to send its line to")
            return
        }
        if line.hasPrefix("/") && !line.hasPrefix("//") {
            let command = String(line.dropFirst().prefix { $0 != " " })
            guard definition.permissions.allowsCommand(command) else {
                return refuse(definition, "may not run /\(command)")
            }
            guard countLine(definition) else { return }
            if definition.permissions.dryRun { return show("[\(definition.name)] would run: \(line)", at: origin) }
            session.submit(line, in: buffer(for: origin, in: session))
            return
        }
        let text = line.hasPrefix("//") ? String(line.dropFirst()) : line
        guard !origin.target.isEmpty else {
            return show("[\(definition.name)] \(text)", at: origin)
        }
        guard definition.permissions.allowsSending(to: origin.target, isChannel: origin.isChannel, isOrigin: true) else {
            return refuse(definition, "may not send to \(origin.target)")
        }
        guard countLine(definition) else { return }
        if definition.permissions.dryRun { return show("[\(definition.name)] would say: \(text)", at: origin) }
        session.scriptSend(text, to: origin.target, kind: .message)
    }

    private func handleJSON(_ line: String, from runner: ScriptRunner, definition: ScriptDefinition) {
        guard let message = JSON.parse(line), let fields = message.object else {
            return reply(runner, error: "bad_json", message: "Not a JSON object: \(line.prefix(80))", re: nil)
        }
        let id = fields["id"]?.string
        guard let type = fields["type"]?.string else {
            return reply(runner, error: "missing_field", message: "No type", re: id)
        }
        do {
            switch type {
            case "reply", "say", "act", "notice": try talk(type, fields, runner: runner, definition: definition)
            case "command": try command(fields, runner: runner, definition: definition)
            case "raw": try raw(fields, runner: runner, definition: definition)
            case "join", "part", "open", "close", "topic", "whois":
                try conversation(type, fields, runner: runner, definition: definition)
            case "show", "notify", "speak", "suggest", "away", "log":
                try forYou(type, fields, runner: runner, definition: definition)
            case "subscribe", "unsubscribe": subscribe(type == "subscribe", fields, definition: definition)
            case "timer": timer(fields, runner: runner, definition: definition)
            case "cancel_timer":
                if let timer = fields["id"]?.string { scriptTimers[runner.id]?.removeValue(forKey: timer)?.cancel() }
            case "store": try storeValue(fields, definition: definition)
            case "done": runner.stop(grace: .milliseconds(500))
            case "query": try query(fields, runner: runner, definition: definition)
            default: throw ScriptError("unknown_type", "Unknown type \(type)")
            }
            if fields["ack"]?.bool == true, let id { runner.send(JSON.object(["type": "ack", "re": .string(id)]).line) }
        } catch let error as ScriptError {
            reply(runner, error: error.code, message: error.message, re: id)
        } catch {
            reply(runner, error: "failed", message: error.localizedDescription, re: id)
        }
    }

    struct ScriptError: Error {
        var code: String
        var message: String
        init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    private func reply(_ runner: ScriptRunner, error code: String, message: String, re: String?) {
        AppLog.debug("scripts", "\(runner.definition.name): \(code): \(message)")
        runner.send(JSON.object(["type": "error", "re": JSON(re), "code": .string(code), "message": .string(message)]).line)
    }

    private func refuse(_ definition: ScriptDefinition, _ what: String) {
        AppLog.warning("scripts", "\(definition.name): \(what)")
    }

    /// The session a command acts on: named, or where the event it answers
    /// came from, or the only one connected.
    private func session(_ fields: [String: JSON], runner: ScriptRunner) throws -> (NetworkSession, ScriptOrigin?) {
        let origin = fields["re"]?.string.flatMap { origins[runner.id]?[$0] }
        let sessions = app?.sessions ?? []
        if let name = fields["network"]?.string ?? fields["network_id"]?.string {
            guard let session = sessions.first(where: {
                $0.displayName.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw ScriptError("unknown_target", "No network \(name)") }
            guard runner.definition.permissions.allowsNetwork(session.displayName, id: session.id) else {
                throw ScriptError("not_permitted", "This script may not act on \(session.displayName)")
            }
            return (session, origin)
        }
        if let origin, let session = app?.session(for: origin.session) { return (session, origin) }
        if let fallback = defaultOrigins[runner.id] ?? services[runner.definition.id]?.lastOrigin,
           let session = app?.session(for: fallback.session) { return (session, fallback) }
        let connected = sessions.filter(\.isConnected)
        if connected.count == 1 { return (connected[0], nil) }
        throw ScriptError("missing_field", "Which network: give network")
    }

    private func buffer(for origin: ScriptOrigin, in session: NetworkSession) -> ChatBuffer {
        guard !origin.target.isEmpty else { return session.serverBuffer }
        return session.buffer(named: origin.target)
            ?? session.openBuffer(named: origin.target, kind: origin.isChannel ? .channel : .query)
    }

    /// Counts a line to IRC against the script's limit; false when over it.
    private func countLine(_ definition: ScriptDefinition) -> Bool {
        let now = Date.now
        let recent = (sentLines[definition.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < max(definition.linesPerMinute, 1) else {
            sentLines[definition.id] = recent
            let since = overflowSince[definition.id] ?? now
            overflowSince[definition.id] = since
            AppLog.warning("scripts", "\(definition.name): over \(definition.linesPerMinute) lines a minute, a line dropped")
            if now.timeIntervalSince(since) > 60 {
                AppLog.error("scripts", "\(definition.name): flooding for a minute, stopped")
                app?.notifier?.post(title: "Script stopped", subtitle: definition.name,
                                    body: "It sent more lines than allowed for a minute.", sound: false,
                                    threadID: "scripts", userInfo: [:])
                stop(definition.id)
            }
            return false
        }
        overflowSince[definition.id] = nil
        sentLines[definition.id] = recent + [now]
        return true
    }

    private func checked(_ definition: ScriptDefinition, lines: Int) throws {
        for _ in 0..<max(lines, 1) where !countLine(definition) {
            throw ScriptError("rate_limited", "Over \(definition.linesPerMinute) lines a minute")
        }
    }

    private func talk(_ type: String, _ fields: [String: JSON], runner: ScriptRunner, definition: ScriptDefinition) throws {
        guard let text = fields["text"]?.string, !text.isEmpty else { throw ScriptError("missing_field", "No text") }
        let (session, origin) = try session(fields, runner: runner)
        let target: String
        var kind: NetworkSession.ScriptMessageKind = type == "act" ? .action : (type == "notice" ? .notice : .message)
        if type == "reply" {
            guard let origin = fields["re"]?.string.flatMap({ origins[runner.id]?[$0] }) ?? origin else {
                throw ScriptError("unknown_target", "No event \(fields["re"]?.string ?? "") to reply to")
            }
            target = origin.target
            if fields["as"]?.string == "action" { kind = .action }
            if fields["as"]?.string == "notice" { kind = .notice }
        } else {
            guard let named = fields["target"]?.string, !named.isEmpty else { throw ScriptError("missing_field", "No target") }
            target = named
        }
        guard session.isConnected || definition.permissions.dryRun else {
            throw ScriptError("not_connected", "\(session.displayName) is not connected")
        }
        let isChannel = session.isupport.isChannel(target)
        let isOrigin = origin.map { $0.session == session.id && $0.target.caseInsensitiveCompare(target) == .orderedSame } ?? false
        guard !target.isEmpty else {
            if let origin { show("[\(definition.name)] \(text)", at: origin) }
            return
        }
        guard definition.permissions.allowsSending(to: target, isChannel: isChannel, isOrigin: isOrigin) else {
            throw ScriptError("not_permitted", "This script may not send to \(target)")
        }
        try checked(definition, lines: text.split(whereSeparator: \.isNewline).count)
        if definition.permissions.dryRun {
            return show("[\(definition.name)] would \(type == "act" ? "act" : "say") to \(target): \(text)",
                        at: ScriptOrigin(session: session.id, target: target, isChannel: isChannel))
        }
        for line in text.split(whereSeparator: \.isNewline) {
            session.scriptSend(String(line), to: target, kind: kind)
        }
    }

    private func command(_ fields: [String: JSON], runner: ScriptRunner, definition: ScriptDefinition) throws {
        guard var line = fields["line"]?.string, !line.isEmpty else { throw ScriptError("missing_field", "No line") }
        if !line.hasPrefix("/") { line = "/" + line }
        let name = String(line.dropFirst().prefix { $0 != " " })
        guard definition.permissions.allowsCommand(name) else {
            throw ScriptError("not_permitted", "This script may not run /\(name)")
        }
        let (session, origin) = try session(fields, runner: runner)
        try checked(definition, lines: 1)
        let place = fields["conversation"]?.string.map {
            ScriptOrigin(session: session.id, target: $0, isChannel: session.isupport.isChannel($0))
        } ?? origin ?? ScriptOrigin(session: session.id, target: "", isChannel: false)
        if definition.permissions.dryRun { return show("[\(definition.name)] would run: \(line)", at: place) }
        session.submit(line, in: buffer(for: place, in: session))
    }

    private func raw(_ fields: [String: JSON], runner: ScriptRunner, definition: ScriptDefinition) throws {
        guard definition.permissions.raw else { throw ScriptError("not_permitted", "This script may not send raw lines") }
        guard let line = fields["line"]?.string, let message = IRCMessage(parsing: line) else {
            throw ScriptError("bad_field", "Not an IRC line")
        }
        let (session, origin) = try session(fields, runner: runner)
        try checked(definition, lines: 1)
        if definition.permissions.dryRun {
            return show("[\(definition.name)] would send: \(line)",
                        at: origin ?? ScriptOrigin(session: session.id, target: "", isChannel: false))
        }
        session.send(message)
    }

    private func conversation(_ type: String, _ fields: [String: JSON], runner: ScriptRunner,
                              definition: ScriptDefinition) throws {
        let (session, _) = try session(fields, runner: runner)
        if ["join", "part", "close"].contains(type), !definition.permissions.channelsJoined {
            throw ScriptError("not_permitted", "This script may not join, leave or close")
        }
        switch type {
        case "join":
            let channels = fields["channels"]?.array?.compactMap(\.string) ?? fields["channel"].flatMap(\.string).map { [$0] } ?? []
            guard !channels.isEmpty else { throw ScriptError("missing_field", "No channels") }
            let keys = fields["keys"]?.array?.compactMap(\.string) ?? []
            session.send(IRCMessage(command: "JOIN", params: [channels.joined(separator: ",")]
                + (keys.isEmpty ? [] : [keys.joined(separator: ",")])))
        case "part":
            guard let channel = fields["channel"]?.string else { throw ScriptError("missing_field", "No channel") }
            session.send(IRCMessage(command: "PART", params: [channel] + (fields["reason"]?.string.map { [$0] } ?? [])))
        case "open":
            guard let target = fields["target"]?.string else { throw ScriptError("missing_field", "No target") }
            let buffer = session.openBuffer(named: target, kind: session.isupport.isChannel(target) ? .channel : .query,
                                            select: fields["select"]?.bool == true)
            if fields["select"]?.bool == true {
                app?.selectedSessionID = session.id
                session.selectedBufferID = buffer.id
            }
        case "close":
            guard let target = fields["target"]?.string, let buffer = session.buffer(named: target) else {
                throw ScriptError("unknown_target", "No conversation \(fields["target"]?.string ?? "")")
            }
            session.close(buffer)
        case "topic":
            guard let channel = fields["channel"]?.string, let text = fields["text"]?.string else {
                throw ScriptError("missing_field", "No channel or text")
            }
            session.send(IRCMessage(command: "TOPIC", params: [channel, text]))
        default: // whois
            guard let nick = fields["nick"]?.string else { throw ScriptError("missing_field", "No nick") }
            session.send(IRCMessage("WHOIS", nick))
            if let id = fields["id"]?.string {
                Task { [weak self, weak runner] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, let runner else { return }
                    runner.send(JSON.object(["type": "result", "re": .string(id)]
                        .merging(self.userFields(nick, in: session)) { _, new in new }).line)
                }
            }
        }
    }

    private func forYou(_ type: String, _ fields: [String: JSON], runner: ScriptRunner, definition: ScriptDefinition) throws {
        let text = fields["text"]?.string ?? ""
        switch type {
        case "log":
            let level = LogLevel.allCases.first { $0.title.lowercased() == fields["level"]?.string?.lowercased() } ?? .info
            AppLog.log(level, "scripts", "\(definition.name): \(text)")
        case "notify":
            var info: [String: String] = [:]
            if let (session, _) = try? session(fields, runner: runner), let target = fields["target"]?.string {
                info = ["network": session.id.uuidString, "buffer": target.lowercased(),
                        "kind": session.isupport.isChannel(target) ? "channel" : "query"]
            }
            app?.notifier?.post(title: fields["title"]?.string ?? definition.name, subtitle: "", body: text, sound: false,
                                threadID: "script-\(definition.id)", userInfo: info)
        case "speak":
            guard !text.isEmpty else { throw ScriptError("missing_field", "No text") }
            Speaker.shared.say(ChatLine(time: .now, kind: .message, sender: fields["nick"]?.string ?? definition.name, text: text),
                               place: nil, announcing: false, buffer: UUID())
        case "away":
            let message = fields["message"]?.string
            let names = fields["networks"]?.array?.compactMap(\.string) ?? []
            if names.isEmpty {
                if let message { app?.goAwayEverywhere(message) } else { app?.comeBackEverywhere() }
            } else {
                for session in app?.sessions ?? [] where names.contains(where: { $0.caseInsensitiveCompare(session.displayName) == .orderedSame }) {
                    session.setAway(message)
                }
            }
        default: // show, suggest
            let (session, origin) = try session(fields, runner: runner)
            let place = fields["target"]?.string.map {
                ScriptOrigin(session: session.id, target: $0, isChannel: session.isupport.isChannel($0))
            } ?? origin ?? ScriptOrigin(session: session.id, target: "", isChannel: false)
            guard !text.isEmpty else { throw ScriptError("missing_field", "No text") }
            if type == "show" {
                show(text, at: place, error: fields["level"]?.string == "error")
            } else {
                buffer(for: place, in: session).suggestion = text
            }
        }
    }

    private func subscribe(_ adding: Bool, _ fields: [String: JSON], definition: ScriptDefinition) {
        guard let service = services[definition.id] else { return }
        let events = fields["events"]?.array?.compactMap(\.string) ?? []
        if adding {
            for name in events {
                var trigger = ScriptTrigger(on: name)
                trigger.networks = fields["networks"]?.array?.compactMap(\.string) ?? []
                trigger.channels = fields["channels"]?.string ?? ""
                trigger.nicks = fields["nicks"]?.string ?? ""
                trigger.notNicks = fields["not_nicks"]?.string ?? ""
                trigger.text = fields["text"]?.string ?? ""
                trigger.isSelf = fields["self"]?.bool
                trigger.ignored = fields["ignored"]?.bool ?? false
                service.subscriptions.append(trigger)
            }
        } else {
            service.subscriptions.removeAll { events.isEmpty || events.contains($0.on) }
        }
    }

    private func timer(_ fields: [String: JSON], runner: ScriptRunner, definition: ScriptDefinition) {
        guard let id = fields["id"]?.string else {
            return reply(runner, error: "missing_field", message: "No id", re: nil)
        }
        let every = fields["every"]?.string.flatMap(ScriptDefinition.seconds)
        let after = fields["after"]?.string.flatMap(ScriptDefinition.seconds) ?? every
        guard let first = after, first > 0 else { return reply(runner, error: "bad_field", message: "No after or every", re: id) }
        scriptTimers[runner.id]?[id]?.cancel()
        scriptTimers[runner.id, default: [:]][id] = Task { [weak runner] in
            var wait = first
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let runner, runner.isRunning else { return }
                runner.send(JSON.object(["type": "event", "event": "timer", "id": .string(id),
                                         "time": JSON(Date.now)]).line)
                guard let every else { return }
                wait = every
            }
        }
    }

    // MARK: - The store

    private func storeFile(_ definition: ScriptDefinition) -> URL {
        URL(filePath: baseEnvironment(definition)["IRCTELL_DATA"]!).appending(path: "store.json")
    }

    private func storedValues(_ definition: ScriptDefinition) -> [String: JSON] {
        (try? Data(contentsOf: storeFile(definition))).flatMap { try? JSONDecoder().decode([String: JSON].self, from: $0) } ?? [:]
    }

    private func storeValue(_ fields: [String: JSON], definition: ScriptDefinition) throws {
        guard let key = fields["key"]?.string else { throw ScriptError("missing_field", "No key") }
        var values = storedValues(definition)
        values[key] = fields["value"] ?? .null
        try JSONEncoder().encode(values).write(to: storeFile(definition), options: .atomic)
    }

    // MARK: - Queries

    private func query(_ fields: [String: JSON], runner: ScriptRunner, definition: ScriptDefinition) throws {
        guard let id = fields["id"]?.string else { throw ScriptError("missing_field", "No id") }
        guard let what = fields["what"]?.string else { throw ScriptError("missing_field", "No what") }
        var result: [String: JSON] = ["type": "result", "re": .string(id)]
        let sessions = (app?.sessions ?? []).filter { definition.permissions.allowsNetwork($0.displayName, id: $0.id) }
        func needLog() throws -> LogStore {
            guard definition.permissions.readLog else { throw ScriptError("not_permitted", "This script may not read the log") }
            guard let log = app?.log else { throw ScriptError("failed", "No message log") }
            return log
        }
        switch what {
        case "networks":
            result["networks"] = .array(sessions.map { session in
                ["name": .string(session.displayName), "id": .string(session.id.uuidString),
                 "connected": JSON(session.isConnected), "nick": .string(session.nick), "away": JSON(session.isAway)]
            })
        case "channels":
            let (session, _) = try self.session(fields, runner: runner)
            result["channels"] = .array(session.channels.map { channel in
                ["name": .string(channel.name), "joined": JSON(channel.isJoined), "topic": JSON(channel.topic),
                 "members": JSON(channel.members.count)]
            })
        case "members":
            let (session, _) = try self.session(fields, runner: runner)
            guard let name = fields["channel"]?.string, let channel = session.buffer(named: name) else {
                throw ScriptError("unknown_target", "No channel \(fields["channel"]?.string ?? "")")
            }
            result["members"] = .array(session.sortedMembers(of: channel).map { member in
                ["nick": .string(member.nick), "prefixes": .string(member.prefixes), "away": JSON(member.isAway),
                 "account": JSON(session.userInfo(for: member.nick)?.account)]
            })
        case "user":
            let (session, _) = try self.session(fields, runner: runner)
            guard let nick = fields["nick"]?.string else { throw ScriptError("missing_field", "No nick") }
            if fields["fresh"]?.bool == true {
                session.send(IRCMessage("WHOIS", nick))
                Task { [weak self, weak runner] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, let runner else { return }
                    runner.send(JSON.object(result.merging(self.userFields(nick, in: session)) { _, new in new }).line)
                }
                return
            }
            result.merge(userFields(nick, in: session)) { _, new in new }
        case "nicks":
            let (session, _) = try self.session(fields, runner: runner)
            let log = try needLog()
            let prefix = fields["starting_with"]?.string ?? ""
            let limit = min(fields["limit"]?.int ?? 50, 1000)
            let known = prefix.isEmpty ? log.recentNicks(network: session.id, limit: limit)
                : log.knownNicks(network: session.id, startingWith: prefix, limit: limit)
            result["nicks"] = .array(known.map { nick in
                ["nick": .string(nick.nick), "last_seen": JSON(nick.lastSeen), "had_private_chat": JSON(nick.hadPrivateChat),
                 "online": JSON(session.isOnline(nick.nick))]
            })
        case "history":
            let (session, _) = try self.session(fields, runner: runner)
            let log = try needLog()
            guard let target = fields["target"]?.string else { throw ScriptError("missing_field", "No target") }
            let limit = min(fields["limit"]?.int ?? 50, 1000)
            let kind: ChatBuffer.Kind = session.isupport.isChannel(target) ? .channel : .query
            let since = fields["since"]?.string.flatMap(LogArchive.parseTime).map { Date(timeIntervalSince1970: $0) }
            let before = fields["before"]?.string.flatMap(LogArchive.parseTime).map { Date(timeIntervalSince1970: $0) }
            var lines = log.lines(in: .buffer(network: session.id, key: LogStore.key(for: target, kind: kind)),
                                  matching: fields["search"]?.string, since: since, oldestFirst: since != nil,
                                  limit: before == nil ? limit : limit * 4)
            if let before { lines = Array(lines.filter { $0.time < before }.suffix(limit)) }
            result["lines"] = .array(lines.map(lineFields))
        case "mentions":
            let log = try needLog()
            let since = fields["since"]?.string.flatMap(LogArchive.parseTime) ?? 0
            let found = log.mentions(includingPrivateMessages: true, limit: min(fields["limit"]?.int ?? 50, 1000))
                .filter { $0.line.time.timeIntervalSince1970 >= since }
            result["lines"] = .array(found.map { mention in
                var line = lineFields(mention.line).object ?? [:]
                line["network"] = JSON(app?.session(for: mention.networkID)?.displayName ?? mention.line.network)
                line["target"] = .string(mention.bufferKey)
                return .object(line)
            })
        case "memos":
            _ = try needLog()
            let (session, _) = try self.session(fields, runner: runner)
            result["memos"] = .array(session.memos.inbox.map { memo in
                ["number": JSON(memo.number), "from": .string(memo.from), "date": .string(memo.date),
                 "unread": JSON(memo.isUnread), "text": JSON(memo.text)]
            })
        case "me":
            let (session, _) = try self.session(fields, runner: runner)
            result["nick"] = .string(session.nick)
            result["away"] = JSON(session.isAway)
            result["account"] = JSON(session.userInfo(for: session.nick)?.account)
        case "store":
            let values = storedValues(definition)
            if let key = fields["key"]?.string { result["value"] = values[key] ?? .null } else { result["values"] = .object(values) }
        default:
            throw ScriptError("bad_field", "Unknown query \(what)")
        }
        runner.send(JSON.object(result).line)
    }

    private func lineFields(_ line: ChatLine) -> JSON {
        ["time": JSON(line.time), "kind": .string(line.kind.rawValue), "nick": JSON(line.sender),
         "text": .string(IRCFormatting.strip(line.text)), "self": JSON(line.isSelf)]
    }

    private func userFields(_ nick: String, in session: NetworkSession) -> [String: JSON] {
        let info = session.userInfo(for: nick)
        let known = app?.log?.knownNick(nick, network: session.id)
        return ["nick": .string(info?.nick ?? known?.seen.nick ?? nick),
                "user": JSON(info?.username ?? known?.seen.user), "host": JSON(info?.host ?? known?.seen.host),
                "real_name": JSON(info?.realName ?? known?.seen.realName),
                "account": JSON(info?.account ?? known?.seen.account), "channels": JSON(info?.channels ?? []),
                "away": JSON(info?.awayMessage != nil), "online": JSON(session.isOnline(nick)),
                "first_seen": JSON(known?.firstSeen), "last_seen": JSON(known?.lastSeen),
                "last_spoke": JSON(session.lastActive(nick))]
    }

    /// A line in a conversation, for the user only.
    private func show(_ text: String, at origin: ScriptOrigin, error: Bool = false) {
        guard let session = app?.session(for: origin.session) else { return }
        session.addInfo(text, kind: error ? .error : .info, to: buffer(for: origin, in: session))
    }
}
