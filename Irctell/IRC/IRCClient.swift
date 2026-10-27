import Foundation

enum IRCConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    /// Connected; CAP negotiation, SASL and NICK/USER are under way.
    case registering
    /// The server sent 001: the connection is usable.
    case registered
    case waitingToReconnect(attempt: Int, delay: Duration)
}

enum IRCClientEvent: Sendable {
    case stateChanged(IRCConnectionState)
    /// Every line from the server, after the client has acted on it.
    case received(IRCMessage)
    /// Every line written to the server, for a raw console.
    case sent(IRCMessage)
    case registered(nick: String)
    case nickChanged(old: String, new: String)
    case capabilitiesChanged(Set<String>)
    case saslSucceeded(account: String)
    case saslFailed(reason: String)
    /// A connection ended or never came up; a reconnect follows unless the
    /// user disconnected.
    case connectionLost(reason: String)
}

enum IRCClientError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected"
        }
    }
}

/// One connection to one network: registers, keeps the connection alive, and
/// reconnects when it drops. It knows nothing about channels or windows; it
/// reports everything it receives as events for the model to interpret.
actor IRCClient {
    /// The IRCv3 capabilities requested whenever the server offers them.
    /// `sasl` is requested separately, and only when there are credentials.
    static let wantedCapabilities: Set<String> = [
        "account-notify", "account-tag", "away-notify", "batch", "cap-notify",
        "chghost", "echo-message", "extended-join", "invite-notify",
        "message-tags", "multi-prefix", "server-time", "setname",
        "userhost-in-names", "chathistory", "draft/chathistory",
    ]

    static let versionString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Irctell \(version) on macOS"
    }()

    let config: IRCServerConfig
    nonisolated let events: AsyncStream<IRCClientEvent>
    private let eventSink: AsyncStream<IRCClientEvent>.Continuation
    private let makeTransport: @Sendable (IRCServerConfig) throws -> any IRCTransport

    private(set) var state: IRCConnectionState = .disconnected
    /// The nick the server knows us by, which may differ from the configured one.
    private(set) var nick: String
    private(set) var capabilities: Set<String> = []
    /// Capability names the server offers, with their values ("" for none).
    private(set) var availableCapabilities: [String: String] = [:]
    private(set) var isupport = ISupport()
    /// The services account SASL logged in to.
    private(set) var account: String?

    private var transport: (any IRCTransport)?
    /// Bumped per connection, so a line delayed by flood control is not
    /// written to a later connection than the one it was meant for.
    private var connectionID = 0
    private var runTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var nickAttempt = 0
    private var negotiatingCapabilities = false
    private var saslInProgress = false
    private var dropReason: String?
    private var lastReceived = ContinuousClock.now
    private var pingSentAt: ContinuousClock.Instant?
    private var penaltyClock = ContinuousClock.now
    /// Run before every attempt to connect, the retries too: starts what the
    /// connection goes through. An error counts as a failed attempt.
    private var preparation: (@Sendable () async throws -> Void)?

    init(config: IRCServerConfig,
         makeTransport: @escaping @Sendable (IRCServerConfig) throws -> any IRCTransport = {
             try NetworkTransport(config: $0)
         }) {
        self.config = config
        self.makeTransport = makeTransport
        self.nick = config.nick
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        eventSink.finish()
    }

    // MARK: - Public interface

    /// Connects, and keeps reconnecting after failures until `disconnect`.
    func connect() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    func setPreparation(_ preparation: (@Sendable () async throws -> Void)?) {
        self.preparation = preparation
    }

    /// Sends QUIT when registered, closes the connection and stops reconnecting.
    func disconnect(reason: String = "Leaving") async {
        guard let task = runTask else { return }
        runTask = nil
        if state == .registered || state == .registering {
            try? await write(IRCMessage("QUIT", reason), throttled: false)
        }
        dropReason = "Disconnected"
        transport?.close()
        task.cancel()
        await task.value
    }

    /// Sends a line, subject to flood control.
    func send(_ message: IRCMessage) async throws {
        try await write(message, throttled: true)
    }

    // MARK: - Connection lifecycle

    private func run() async {
        while !Task.isCancelled {
            setState(.connecting)
            dropReason = nil
            do {
                if let preparation {
                    try await preparation()
                    try Task.checkCancellation()
                }
                let transport = try makeTransport(config)
                self.transport = transport
                connectionID += 1
                let incoming = try await transport.open()
                try await session(incoming: incoming)
                emit(.connectionLost(reason: dropReason ?? "The server closed the connection"))
            } catch is CancellationError {
                break
            } catch is IRCTransportError {
                // A configuration error: retrying will not fix it.
                emit(.connectionLost(reason: dropReason ?? "Invalid server configuration"))
                transport = nil
                break
            } catch {
                emit(.connectionLost(reason: dropReason ?? error.localizedDescription))
            }
            transport?.close()
            transport = nil
            if Task.isCancelled { break }

            reconnectAttempt += 1
            let delay = reconnectDelay(attempt: reconnectAttempt)
            setState(.waitingToReconnect(attempt: reconnectAttempt, delay: delay))
            do { try await Task.sleep(for: delay) } catch { break }
        }
        transport?.close()
        transport = nil
        setState(.disconnected)
        // When cancelled, `disconnect` already cleared it, and a new `connect`
        // may have set it to a task of its own since.
        if !Task.isCancelled { runTask = nil }
    }

    func reconnectDelay(attempt: Int) -> Duration {
        let doubled = config.timeouts.reconnectInitial * (1 << min(attempt - 1, 16))
        return min(doubled, config.timeouts.reconnectMaximum)
    }

    private func session(incoming: AsyncThrowingStream<Data, Error>) async throws {
        nick = config.nick
        nickAttempt = 0
        capabilities = []
        availableCapabilities = [:]
        isupport = ISupport()
        account = nil
        saslInProgress = false
        lastReceived = .now
        pingSentAt = nil
        setState(.registering)

        let watchdog = Task { await self.watchLiveness() }
        defer { watchdog.cancel() }

        try await register()

        var buffer = IRCLineBuffer()
        for try await chunk in incoming {
            lastReceived = .now
            pingSentAt = nil
            for line in buffer.append(chunk) {
                guard let message = IRCMessage(parsing: line) else { continue }
                try await handle(message)
            }
        }
    }

    /// CAP LS first, so the server holds registration until CAP END and SASL
    /// can complete before the network sees the user. A server without CAP
    /// answers 421 and registers on NICK/USER alone.
    private func register() async throws {
        negotiatingCapabilities = true
        try await write(IRCMessage("CAP", "LS", "302"), throttled: false)
        if let password = config.serverPassword, !password.isEmpty {
            try await write(IRCMessage("PASS", password), throttled: false)
        }
        try await write(IRCMessage("NICK", config.nick), throttled: false)
        try await write(IRCMessage("USER", config.username, "0", "*", config.realName), throttled: false)
    }

    /// Notices a connection that died without saying so: after a quiet spell
    /// it sends a PING, and drops the connection if nothing comes back.
    private func watchLiveness() async {
        let timeouts = config.timeouts
        let tick = min(min(timeouts.idleBeforePing, timeouts.pingReply) / 4, .seconds(5))
        while !Task.isCancelled {
            do { try await Task.sleep(for: tick) } catch { return }
            let now = ContinuousClock.now
            if let sent = pingSentAt {
                if now - sent > timeouts.pingReply {
                    dropReason = "Ping timeout"
                    transport?.close()
                    return
                }
            } else if now - lastReceived > timeouts.idleBeforePing {
                pingSentAt = now
                try? await write(IRCMessage("PING", "irctell"), throttled: false)
            }
        }
    }

    // MARK: - Incoming

    private func handle(_ message: IRCMessage) async throws {
        emit(.received(message))

        switch message.command {
        case "PING":
            try await write(IRCMessage(command: "PONG", params: message.params), throttled: false)

        case "CAP":
            try await handleCapability(message)

        case "AUTHENTICATE":
            if saslInProgress, message[param: 0] == "+", let sasl = config.sasl {
                for piece in SASL.plainPayload(account: sasl.account, password: sasl.password) {
                    try await write(IRCMessage("AUTHENTICATE", piece), throttled: false)
                }
            }

        case "900": // RPL_LOGGEDIN
            account = message[param: 2]

        case "903": // RPL_SASLSUCCESS
            saslInProgress = false
            emit(.saslSucceeded(account: account ?? config.sasl?.account ?? ""))
            try await endCapabilityNegotiation()

        case "902", "904", "905", "906", "907": // the SASL failures
            if saslInProgress {
                saslInProgress = false
                emit(.saslFailed(reason: message.params.last ?? "SASL authentication failed"))
                try await endCapabilityNegotiation()
            }

        case "001": // RPL_WELCOME
            negotiatingCapabilities = false
            if let assigned = message[param: 0] { nick = assigned }
            reconnectAttempt = 0
            setState(.registered)
            emit(.registered(nick: nick))

        case "005": // RPL_ISUPPORT
            isupport.apply(message)

        case "432", "433", "436", "437": // nick unusable or taken
            if state == .registering {
                try await write(IRCMessage("NICK", nextNick()), throttled: false)
            }

        case "NICK":
            if let source = message.prefix?.name, let new = message[param: 0],
               isupport.caseMapping.equal(source, nick) {
                nick = new
                emit(.nickChanged(old: source, new: new))
            }

        case "PRIVMSG":
            try await answerCTCP(message)

        case "ERROR":
            dropReason = message.params.last
            transport?.close()

        default:
            break
        }
    }

    private func handleCapability(_ message: IRCMessage) async throws {
        guard message.params.count >= 3, let list = message.params.last else { return }
        let subcommand = message.params[1].uppercased()
        // `CAP * LS * :...` -- the `*` says more lines of the reply follow.
        let continued = message.params.count >= 4 && message.params[2] == "*"
        let offered = list.split(separator: " ").map { item -> (String, String) in
            guard let eq = item.firstIndex(of: "=") else { return (String(item), "") }
            return (String(item[..<eq]), String(item[item.index(after: eq)...]))
        }

        switch subcommand {
        case "LS", "NEW":
            for (name, value) in offered { availableCapabilities[name] = value }
            guard !continued else { return }
            // LS may have come in several lines; NEW names only what is new.
            let candidates = subcommand == "LS" ? Array(availableCapabilities.keys) : offered.map(\.0)
            let request = capabilitiesToRequest(from: candidates)
            if !request.isEmpty {
                try await write(IRCMessage("CAP", "REQ", request.sorted().joined(separator: " ")),
                                throttled: false)
            } else if subcommand == "LS" {
                try await endCapabilityNegotiation()
            }

        case "ACK":
            for (name, _) in offered {
                if name.hasPrefix("-") {
                    capabilities.remove(String(name.dropFirst()))
                } else {
                    capabilities.insert(name)
                }
            }
            emit(.capabilitiesChanged(capabilities))
            guard !continued, negotiatingCapabilities else { return }
            if config.sasl != nil, offered.contains(where: { $0.0 == "sasl" }) {
                saslInProgress = true
                try await write(IRCMessage("AUTHENTICATE", "PLAIN"), throttled: false)
            } else {
                try await endCapabilityNegotiation()
            }

        case "NAK":
            if !continued { try await endCapabilityNegotiation() }

        case "DEL":
            for (name, _) in offered {
                availableCapabilities[name] = nil
                capabilities.remove(name)
            }
            emit(.capabilitiesChanged(capabilities))

        default:
            break
        }
    }

    private func capabilitiesToRequest(from offered: [String]) -> Set<String> {
        var request = Set(offered).intersection(IRCClient.wantedCapabilities).subtracting(capabilities)
        // Both names for chathistory are offered during its draft period;
        // one is enough.
        if request.contains("chathistory") { request.remove("draft/chathistory") }

        if negotiatingCapabilities, config.sasl != nil {
            if let mechanisms = availableCapabilities["sasl"],
               mechanisms.isEmpty || mechanisms.split(separator: ",").contains("PLAIN") {
                request.insert("sasl")
            } else {
                emit(.saslFailed(reason: "The server does not offer SASL PLAIN"))
            }
        }
        return request
    }

    private func endCapabilityNegotiation() async throws {
        guard negotiatingCapabilities, state == .registering else { return }
        negotiatingCapabilities = false
        try await write(IRCMessage("CAP", "END"), throttled: false)
    }

    private func nextNick() -> String {
        nickAttempt += 1
        if nickAttempt <= config.alternateNicks.count {
            return config.alternateNicks[nickAttempt - 1]
        }
        return config.nick + String(repeating: "_", count: nickAttempt - config.alternateNicks.count)
    }

    /// Answers CTCP queries sent to us directly. Queries to a channel are not
    /// answered: a channel full of clients replying at once is a flood.
    private func answerCTCP(_ message: IRCMessage) async throws {
        guard config.answersCTCP,
              let target = message[param: 0], isupport.caseMapping.equal(target, nick),
              let sender = message.prefix?.name,
              let text = message.params.last, let query = CTCP(text: text),
              let reply = query.reply(version: IRCClient.versionString) else { return }
        try await write(IRCMessage("NOTICE", sender, reply.text), throttled: true)
    }

    // MARK: - Outgoing

    private func write(_ message: IRCMessage, throttled: Bool) async throws {
        let forConnection = connectionID
        if throttled {
            let now = ContinuousClock.now
            if penaltyClock < now { penaltyClock = now }
            let wait = penaltyClock - now - config.timeouts.floodBurst
            penaltyClock += config.timeouts.floodLineInterval
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        guard let transport, connectionID == forConnection else { throw IRCClientError.notConnected }
        try await transport.send(Data((message.serialized + "\r\n").utf8))
        emit(.sent(message))
    }

    // MARK: - Events

    private func setState(_ new: IRCConnectionState) {
        guard new != state else { return }
        state = new
        emit(.stateChanged(new))
    }

    private func emit(_ event: IRCClientEvent) {
        eventSink.yield(event)
    }
}
