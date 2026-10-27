import Foundation
import Observation

/// One network in the window: its connection, and the conversations on it.
/// Turns the client's protocol events into buffers, lines and members, and
/// what the user types into protocol messages.
@MainActor @Observable
final class NetworkSession: Identifiable {
    let id: UUID
    private(set) var config: NetworkConfig
    private(set) var state: IRCConnectionState = .disconnected
    private(set) var nick: String
    private(set) var isupport = ISupport()
    private(set) var capabilities: Set<String> = []

    let serverBuffer: ChatBuffer
    /// The conversation with MemoServ: memos read and sent, and what it
    /// tells. Always there, under the server window; not a private chat.
    let memoBuffer: ChatBuffer
    static let memoServ = "MemoServ"
    /// The inbox and outbox, made from what MemoServ answers.
    let memos: MemoBox
    /// Whether the memos were listed since the last login.
    @ObservationIgnored var memosChecked = false
    private(set) var buffers: [ChatBuffer] {
        didSet { layoutChanged() }
    }
    var selectedBufferID: ChatBuffer.ID? {
        didSet {
            if let buffer = selectedBuffer { markRead(buffer) }
            if oldValue != selectedBufferID, let oldValue { previousBufferID = oldValue }
            if selectedBufferID != oldValue { layoutChanged() }
        }
    }
    /// Whether this network's tab is the one shown, so the selected buffer's
    /// new lines are being read as they come and do not count as unread.
    var isFrontmost = false {
        didSet { if isFrontmost, let buffer = selectedBuffer { markRead(buffer) } }
    }
    /// The conversation selected before the current one, for ⌥Tab.
    @ObservationIgnored private var previousBufferID: ChatBuffer.ID?
    /// When each user, by folded nick, last said something anywhere on the
    /// network: for how idle they are.
    private(set) var lastSpoke: [String: Date] = [:]
    /// What VERSION queries are answered with; nil to not answer them.
    @ObservationIgnored var clientVersion: () -> String? = { ClientIdentity.current }
    @ObservationIgnored private var lastCTCPReply = ContinuousClock.now - .seconds(10)

    /// Lines the user has sent, newest last, for the input field's history.
    private(set) var inputHistory: [String] = []
    /// The last WHOIS of each user, keyed by the case-folded nick.
    private(set) var users: [String: UserInfo] = [:]

    /// The server's channel list, from the last LIST that finished.
    private(set) var channelList: [ListedChannel] = []
    private(set) var channelListDate: Date?
    /// Entries of a LIST still coming in, counted for the progress shown.
    private(set) var isListingChannels = false
    private(set) var listingCount = 0
    var showsChannelList = false
    /// Channels ticked in the channel list to be joined together; kept while
    /// searching and when the list is closed and opened again.
    var pickedChannels: Set<String> = []
    @ObservationIgnored private var listing: [ListedChannel] = []

    /// Called with the open channels and private chats whenever they change,
    /// so they can be saved and opened again on the next launch.
    @ObservationIgnored var onLayoutChange: ((BufferLayout) -> Void)?

    @ObservationIgnored private var client: IRCClient?
    @ObservationIgnored private var outgoing: AsyncStream<IRCMessage>.Continuation?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let makeClient: @MainActor (IRCServerConfig) -> IRCClient
    /// The channel a /join asked for, to be selected once the server confirms.
    @ObservationIgnored private var pendingSelection: String?
    @ObservationIgnored private var hasShownFirstChannel = false
    /// Where every line is written; nil keeps them in memory only.
    @ObservationIgnored let log: LogStore?
    /// Fetches the pictures linked in lines; nil for none.
    @ObservationIgnored var media: MediaStore?
    /// The highlight words, patterns and ignored nicks, as they are now.
    @ObservationIgnored var highlightRules: () -> HighlightRules = { .current() }
    /// The automatic reply to a line, if any; replaceable for tests.
    @ObservationIgnored var autoReply: (ChatLine, ChatBuffer.Kind) -> String? = { _, _ in nil }
    /// Told when someone else's message or action comes into a channel or
    /// private chat, not ignored: for suggesting a reply.
    @ObservationIgnored var heard: (ChatBuffer) -> Void = { _ in }
    /// Told of everything scripts can be triggered by (SCRIPTING.md).
    @ObservationIgnored var scriptEvent: (ScriptEvent) -> Void = { _ in }
    /// `/run NAME words`: false when there is no such script.
    @ObservationIgnored var runScript: (String, [String], ChatBuffer) -> Void = { _, _, _ in }
    /// How long an automatic reply waits, so it does not look instant.
    @ObservationIgnored var autoReplyDelay: () -> Duration = { .milliseconds(Int.random(in: 1000...3000)) }

    /// Reads a line aloud; replaceable for tests.
    /// The line, where it was when that is not on screen, whether to say who
    /// wrote it, and the buffer.
    @ObservationIgnored var speak: (ChatLine, String?, Bool, ChatBuffer.ID) -> Void = {
        Speaker.shared.say($0, place: $1, announcing: $2, buffer: $3)
    }
    /// Told of every line from someone else, to decide on notifications.
    @ObservationIgnored var onAttention: ((AttentionEvent) -> Void)?
    /// Told when a conversation is looked at, so its notifications can go.
    @ObservationIgnored var onRead: ((ChatBuffer) -> Void)?

    private func markRead(_ buffer: ChatBuffer) {
        buffer.markRead()
        onRead?(buffer)
    }
    /// Marked away on this network with /away.
    private(set) var isAway = false

    /// Nicks waiting for a WHOIS asked for from the member list, sent one at
    /// a time so the server does not take it for flooding.
    private(set) var whoisQueue: [String] = []
    /// Folded nicks whose WHOIS replies are kept but not printed.
    @ObservationIgnored private var quietWhois: Set<String> = []
    private(set) var whoisInFlight: String?
    @ObservationIgnored private var whoisTask: Task<Void, Never>?
    @ObservationIgnored private var lastListPublish = ContinuousClock.now
    @ObservationIgnored private var performTask: Task<Void, Never>?
    /// Logged in to the network's services: by SASL, a NickServ IDENTIFY,
    /// or as RPL_LOGGEDIN or user mode +r tell.
    @ObservationIgnored private(set) var isLoggedIn = false
    /// The channels the last automatic join asked for, folded; refusals of
    /// these are tried again once logged in.
    @ObservationIgnored private var autoJoinRequested: Set<String> = []
    @ObservationIgnored private var retryAfterLogin: [String] = []
    /// Asks every minute which private chat partners are online.
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    /// The folded nicks the last ISON asked about; empty when the user
    /// asked, whose answer is printed.
    @ObservationIgnored private var isonAsked: [Set<String>] = []

    init(config: NetworkConfig, log: LogStore? = nil,
         makeClient: @escaping @MainActor (IRCServerConfig) -> IRCClient = { IRCClient(config: $0) }) {
        self.id = config.id
        self.config = config
        self.log = log
        self.nick = config.effectiveNick(defaults: .current)
        self.makeClient = makeClient
        serverBuffer = ChatBuffer(kind: .server, name: config.name)
        memoBuffer = ChatBuffer(kind: .query, name: NetworkSession.memoServ)
        memos = MemoBox(fileURL: IrctellHome.directory.appending(path: "memos/\(config.id.uuidString).json"))
        buffers = [serverBuffer, memoBuffer]
        selectedBufferID = serverBuffer.id
        memos.command = { [weak self] in self?.memoCommand($0) }
        memos.onNewMemo = { [weak self] from in
            guard let self else { return }
            self.emit("memo", in: self.memoBuffer, nick: from, fields: ["from": JSON(from)])
        }
        highlightRules = { [weak self] in .current(for: self?.config) }
    }

    var displayName: String {
        config.name.isEmpty ? (isupport.networkName ?? config.host) : config.name
    }

    var selectedBuffer: ChatBuffer? {
        buffers.first { $0.id == selectedBufferID }
    }

    var isConnected: Bool { state == .registered }
    var isOffline: Bool { state == .disconnected }

    var unreadCount: Int { buffers.reduce(0) { $0 + $1.unreadCount } }
    var hasHighlight: Bool { buffers.contains { $0.hasHighlight } }

    // MARK: - Connection

    /// Connects when offline. A fresh client each time, so the connection
    /// uses the identity and settings as they are now.
    func connect() {
        guard client == nil || state == .disconnected else { return }
        retireClient()
        let client = startClient()
        Task {
            if prepareConnection != nil {
                await client.setPreparation { @MainActor [weak self] in
                    guard let self, let prepare = self.prepareConnection else { return }
                    do {
                        try await prepare(self)
                        self.preparationFailed = false
                    } catch {
                        AppLog.error("network", "\(self.displayName): not connecting: \(error.localizedDescription)")
                        self.preparationFailed = true
                        throw error
                    }
                }
            }
            await client.connect()
        }
    }

    /// Run before each attempt to connect, the retries too: starts Tor or the
    /// SSH tunnel for a network that goes through one. An error fails the
    /// attempt, and another follows later.
    @ObservationIgnored var prepareConnection: ((NetworkSession) async throws -> Void)?
    /// Whether the last attempt failed before reaching the server: Tor or the
    /// tunnel would not start.
    @ObservationIgnored private var preparationFailed = false
    /// Said once per launch: why a Tor connection may be turned away.
    @ObservationIgnored private var hasExplainedTorRefusal = false

    func reconnect() {
        guard let old = client else { return connect() }
        Task {
            await old.disconnect(reason: "Reconnecting")
            connect()
        }
    }

    private func retireClient() {
        eventTask?.cancel()
        eventTask = nil
        outgoing?.finish()
        outgoing = nil
        client = nil
    }

    func disconnect(reason: String = "Leaving") {
        guard let client else { return }
        Task { await client.disconnect(reason: reason) }
    }

    /// Disconnects and waits until the QUIT is out; used when the app quits.
    /// Saves what is half typed first.
    func shutDown() async {
        layoutChanged()
        await client?.disconnect(reason: "Irctell quit")
    }

    /// Takes an edited configuration; a change to how to connect starts a
    /// new connection with it.
    func apply(_ newConfig: NetworkConfig) {
        let reconnect = newConfig.needsReconnect(comparedTo: config)
        config = newConfig
        serverBuffer.name = newConfig.name
        guard reconnect, let old = client else { return }
        let wasOnline = state != .disconnected
        retireClient()
        Task { await old.disconnect(reason: "Reconnecting") }
        state = .disconnected
        markAllParted(reason: "Settings changed")
        if wasOnline { connect() }
    }

    private func startClient() -> IRCClient {
        let client = makeClient(config.serverConfig(defaults: .current))
        self.client = client

        // One sender, so lines go out in the order they were typed.
        let (stream, outgoing) = AsyncStream<IRCMessage>.makeStream()
        self.outgoing = outgoing
        Task { [weak self] in
            for await message in stream {
                do {
                    try await client.send(message)
                } catch {
                    self?.addInfo("Not sent: \(error.localizedDescription)", kind: .error,
                                  to: self?.selectedBuffer)
                }
            }
        }

        eventTask = Task { [weak self] in
            for await event in client.events {
                self?.handle(event)
            }
        }
        return client
    }

    func send(_ message: IRCMessage) {
        sent?(message)
        outgoing?.yield(message)
    }

    /// Told of every message sent; for tests without a server.
    @ObservationIgnored var sent: ((IRCMessage) -> Void)?

    // MARK: - Buffers

    /// The open channels and private chats, in the order opened, and the one
    /// selected.
    var layout: BufferLayout {
        BufferLayout(buffers: buffers.filter { $0.kind != .server }.map(BufferLayout.Buffer.init),
                     selected: selectedBuffer.flatMap { $0.kind == .server ? nil : $0.name },
                     serverSearch: serverBuffer.search.isEmpty ? nil : serverBuffer.search,
                     serverDraft: serverBuffer.draft.isEmpty ? nil : serverBuffer.draft,
                     userOrdered: true,
                     closed: closedBuffers.isEmpty ? nil : closedBuffers)
    }

    /// Opens the buffers saved from an earlier run, not joined: the channels
    /// set to rejoin are joined once connected.
    func restore(_ layout: BufferLayout) {
        closedBuffers = layout.closed ?? []
        for saved in layout.buffers where saved.kind != .server {
            saved.apply(to: openBuffer(named: saved.name, kind: saved.kind))
        }
        serverBuffer.search = layout.serverSearch ?? ""
        serverBuffer.draft = layout.serverDraft ?? ""
        // Saved before the order could be changed: as the sidebar showed them.
        if layout.userOrdered != true {
            buffers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if let selected = layout.selected, let buffer = buffer(named: selected) {
            selectedBufferID = buffer.id
            // The user's own choice stands; no jumping to the first channel.
            hasShownFirstChannel = true
        }
    }

    /// Marked away on the network with the message; nil for back.
    func setAway(_ message: String?) {
        send(message.map { IRCMessage("AWAY", $0) } ?? IRCMessage("AWAY"))
    }

    /// Saves the layout; also for changes the views make to a buffer's
    /// search and history settings.
    func layoutChanged() {
        onLayoutChange?(layout)
    }

    /// Empties the transcript, and keeps the log's history out of it until
    /// the next launch.
    func clear(_ buffer: ChatBuffer) {
        buffer.clear(upTo: log?.lastInsertedID)
    }

    /// Closed conversations as they were, the most recently closed last.
    @ObservationIgnored private(set) var closedBuffers: [BufferLayout.Buffer] = []
    static let closedBuffersKept = 200

    /// The last lines of the private chat with the nick, oldest first: from
    /// the log, so they are there after a restart too.
    func recentLines(ofQuery nick: String, limit: Int) -> [ChatLine] {
        if let log {
            return log.lines(in: .buffer(network: id, key: LogStore.key(for: nick, kind: .query)), limit: limit)
        }
        return Array((buffer(named: nick)?.lines ?? []).suffix(limit))
    }

    func buffer(named name: String) -> ChatBuffer? {
        buffers.first { $0.kind != .server && isupport.caseMapping.equal($0.name, name) }
    }

    @discardableResult
    func openBuffer(named name: String, kind: ChatBuffer.Kind, select: Bool = false) -> ChatBuffer {
        let buffer: ChatBuffer
        if let existing = self.buffer(named: name) {
            buffer = existing
        } else {
            buffer = ChatBuffer(kind: kind, name: name)
            // Opened again: as it was when closed.
            if let index = closedBuffers.lastIndex(where: { $0.kind == kind && isupport.caseMapping.equal($0.name, name) }) {
                closedBuffers.remove(at: index).apply(to: buffer)
            }
            buffers.append(buffer)
            if kind == .query, isConnected {
                isonAsked.append([fold(name)])
                send(IRCMessage("ISON", name))
            }
        }
        if select { selectedBufferID = buffer.id }
        return buffer
    }

    /// Closes a channel or private chat; leaves the channel first.
    func close(_ buffer: ChatBuffer, reason: String? = nil) {
        guard buffer.kind != .server, buffer !== memoBuffer else { return }
        if buffer.kind == .channel, buffer.isJoined {
            send(IRCMessage(command: "PART", params: [buffer.name] + (reason.map { [$0] } ?? [])))
        }
        buffer.wantsJoin = false
        closedBuffers.removeAll { $0.kind == buffer.kind && isupport.caseMapping.equal($0.name, buffer.name) }
        closedBuffers.append(BufferLayout.Buffer(buffer))
        if closedBuffers.count > NetworkSession.closedBuffersKept {
            closedBuffers.removeFirst(closedBuffers.count - NetworkSession.closedBuffersKept)
        }
        if selectedBufferID == buffer.id {
            let index = buffers.firstIndex { $0.id == buffer.id } ?? 1
            selectedBufferID = buffers[max(0, index - 1)].id
        }
        buffers.removeAll { $0.id == buffer.id }
    }

    /// In the order the user put them in the sidebar; new ones at the end.
    var channels: [ChatBuffer] { buffers.filter { $0.kind == .channel } }
    var queries: [ChatBuffer] { buffers.filter { $0.kind == .query && $0 !== memoBuffer } }

    func isMemos(_ buffer: ChatBuffer) -> Bool { buffer === memoBuffer }

    /// Sends a command to MemoServ, shown in the Memos conversation.
    func memoCommand(_ command: String) {
        submit(command, in: memoBuffer)
    }

    /// Dragging in the sidebar: moves channels, or private chats, among
    /// themselves.
    func moveBuffers(of kind: ChatBuffer.Kind, from source: IndexSet, to destination: Int) {
        var moved = kind == .query ? queries : channels
        moved.move(fromOffsets: source, toOffset: destination)
        buffers = buffers.filter { buffer in !moved.contains { $0 === buffer } } + moved
    }

    /// Moves the selection through the buffers in sidebar order.
    func selectBuffer(offset: Int) {
        let ordered = [serverBuffer, memoBuffer] + channels + queries
        let index = ordered.firstIndex { $0.id == selectedBufferID } ?? 0
        selectedBufferID = ordered[(index + offset + ordered.count) % ordered.count].id
    }

    /// Back to the conversation selected before this one.
    func selectPreviousBuffer() {
        guard let previous = previousBufferID, buffers.contains(where: { $0.id == previous }) else { return }
        selectedBufferID = previous
    }

    /// The next conversation, in sidebar order, with lines not yet seen;
    /// false when there is none.
    @discardableResult
    func selectUnreadBuffer(offset: Int) -> Bool {
        let ordered = [serverBuffer, memoBuffer] + channels + queries
        let start = ordered.firstIndex { $0.id == selectedBufferID } ?? 0
        for step in 1..<max(ordered.count, 1) {
            let buffer = ordered[((start + step * offset) % ordered.count + ordered.count) % ordered.count]
            if buffer.unreadCount > 0 {
                selectedBufferID = buffer.id
                return true
            }
        }
        return false
    }

    // MARK: - Presence of private chat partners

    private func query(with nick: String) -> ChatBuffer? {
        buffers.first { $0.kind == .query && isupport.caseMapping.equal($0.name, nick) }
    }

    private func seenOnline(_ nick: String) {
        query(with: nick)?.partnerOnline = true
    }

    /// ISON for the open private chats now and every minute: a QUIT, a
    /// message or a channel shows it sooner.
    private func startPresenceChecks() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkPresence()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func stopPresenceChecks() {
        presenceTask?.cancel()
        presenceTask = nil
        isonAsked = []
        for buffer in queries { buffer.partnerOnline = nil }
    }

    func checkPresence() {
        guard isConnected else { return }
        var batch: [String] = []
        func flush() {
            guard !batch.isEmpty else { return }
            isonAsked.append(Set(batch.map(fold)))
            send(IRCMessage(command: "ISON", params: [batch.joined(separator: " ")]))
            batch = []
        }
        for buffer in queries {
            if (batch + [buffer.name]).joined(separator: " ").utf8.count > 400 { flush() }
            batch.append(buffer.name)
        }
        flush()
    }

    // MARK: - Idleness

    /// When the user was last known to be active: their last message on
    /// this network, or what a WHOIS said of their idle time.
    func lastActive(_ nick: String) -> Date? {
        let key = fold(nick)
        let byWhois = users[key].flatMap { info in
            info.idleSeconds.map { info.updated.addingTimeInterval(-Double($0)) }
        }
        return [lastSpoke[key], byWhois].compactMap { $0 }.max()
    }

    func isShowing(_ buffer: ChatBuffer) -> Bool {
        isFrontmost && selectedBufferID == buffer.id
    }

    private func add(_ line: ChatLine, to buffer: ChatBuffer) {
        // A private chat: its partner marked as one.
        if buffer.kind == .query, buffer !== memoBuffer, line.isActivity {
            log?.noteNicks([LogStore.SeenNick(nick: buffer.name)], network: id, privateChat: true, time: line.time)
        }
        let line = log?.append(line, networkID: id, networkName: displayName,
                               bufferName: buffer.name, bufferKind: buffer.kind) ?? line
        buffer.append(line)
        media?.process(line, networkID: id, bufferName: buffer.name, kind: buffer.kind)
        if line.isActivity, !line.isSelf { readAloud(line, in: buffer) }
        guard line.isActivity, !line.isSelf else { return }
        let ignored = highlightRules().isIgnored(line.sender)
        if !isShowing(buffer) {
            buffer.unreadCount += 1
            if line.isHighlight || (buffer.kind == .query && !ignored) {
                if !buffer.hasHighlight { buffer.firstUnseen = line.time }
                buffer.hasHighlight = true
            }
        }
        guard !ignored else { return }
        if buffer.kind != .server, buffer !== memoBuffer, line.kind == .message || line.kind == .action {
            heard(buffer)
        }
        let reason: AttentionEvent.Reason = line.isHighlight ? .mention
            : buffer.kind == .query ? .privateMessage : .message
        onAttention?(AttentionEvent(networkID: id, networkName: displayName, bufferName: buffer.name,
                                    bufferKind: buffer.kind, line: line, reason: reason))
    }

    /// Sends an automatic reply after a moment, if the conversation is still
    /// there to answer in.
    /// With the conversation's loudspeaker on: reads the line aloud. Who
    /// wrote it and where is said only for a channel not on screen; in a
    /// private chat, and in what is open, each nick's voice tells.
    private func readAloud(_ line: ChatLine, in buffer: ChatBuffer) {
        guard buffer.speaks else { return }
        let showing = isShowing(buffer)
        let announcing = buffer.kind != .query && !showing
        speak(line, announcing ? buffer.name : nil, announcing, buffer.id)
    }

    private func answer(_ reply: String, in buffer: ChatBuffer) {
        let delay = autoReplyDelay()
        Task { [weak self, weak buffer] in
            try? await Task.sleep(for: delay)
            guard let self, let buffer, self.isConnected, self.buffers.contains(where: { $0 === buffer }) else { return }
            self.say(reply, in: buffer)
            // Not typed by the user, so not known to them: read aloud as if
            // someone else had written it -- in the user's nick and voice.
            self.readAloud(ChatLine(time: .now, kind: .message, sender: self.nick, text: reply), in: buffer)
        }
    }

    /// Answers a CTCP query sent to us -- not to a channel, where every client
    /// answering at once is a flood -- at most one every two seconds, so a
    /// flood of queries does not get us thrown off for flooding.
    private func answer(_ query: CTCP, from sender: String, target: String) {
        guard isMe(target), ContinuousClock.now - lastCTCPReply >= .seconds(2),
              let reply = query.reply(version: clientVersion()) else { return }
        lastCTCPReply = .now
        send(IRCMessage("NOTICE", sender, reply.text))
    }

    /// Writes a line to the log only, for a conversation that may not even
    /// be open.
    private func logSilently(_ line: ChatLine, in bufferName: String, kind: ChatBuffer.Kind) {
        log?.append(line, networkID: id, networkName: displayName, bufferName: bufferName, bufferKind: kind)
    }

    func addInfo(_ text: String, kind: ChatLine.Kind = .info, to buffer: ChatBuffer? = nil, time: Date = .now) {
        add(ChatLine(time: time, kind: kind, text: text), to: buffer ?? serverBuffer)
    }

    private func markAllParted(reason: String) {
        for buffer in buffers where buffer.kind == .channel {
            if buffer.isJoined {
                addInfo("Left the channel: \(reason)", to: buffer)
            }
            buffer.isJoined = false
            buffer.members = [:]
        }
    }

    // MARK: - Events

    func handle(_ event: IRCClientEvent) {
        switch event {
        case .stateChanged(let new):
            state = new
            switch new {
            case .connecting:
                addInfo("Connecting to \(config.host):\(config.port)\(config.useTLS ? " (TLS)" : "")…")
            case .waitingToReconnect(let attempt, let delay):
                addInfo("Reconnecting in \(delay.components.seconds) s (attempt \(attempt))")
            case .disconnected:
                addInfo("Disconnected")
                isLoggedIn = false
                retryAfterLogin = []
                stopPresenceChecks()
                isAway = false
                stopWhoisQueue()
            default:
                break
            }
        case .registered(let nick):
            AppLog.info("network", "\(displayName): logged in as \(nick)")
            emit("connect", in: serverBuffer, nick: nick, fields: ["nick": .string(nick), "server": .string(config.host)])
            memosChecked = false
            self.nick = nick
            addInfo("Connected as \(nick)")
            startPresenceChecks()
            if config.performCommands.isEmpty {
                rejoinChannels()
            } else {
                performTask?.cancel()
                performTask = Task { [weak self] in
                    await self?.runPerformCommands()
                    await self?.waitForServicesLogin()
                    guard let self, !Task.isCancelled, self.isConnected else { return }
                    self.rejoinChannels()
                }
            }
        case .nickChanged(_, let new):
            nick = new
        case .capabilitiesChanged(let capabilities):
            self.capabilities = capabilities
        case .saslSucceeded(let account):
            addInfo("Logged in as \(account)")
            loggedIn()
        case .saslFailed(let reason):
            addInfo("SASL: \(reason)", kind: .error)
        case .connectionLost(let reason):
            AppLog.warning("network", "\(displayName): connection lost: \(reason)")
            emit("disconnect", in: serverBuffer, fields: ["reason": .string(reason)])
            addInfo("Connection lost: \(reason)", kind: .error)
            if config.proxyKind == .tor, !hasExplainedTorRefusal, !preparationFailed {
                hasExplainedTorRefusal = true
                addInfo("Through Tor, many servers turn away some exit relays, or all of them. Each new try leaves from another exit; if none gets in, the network may not accept Tor at all, or only with SASL, or at an .onion address of its own.")
            }
            markAllParted(reason: reason)
            isLoggedIn = false
            retryAfterLogin = []
            isListingChannels = false
            stopWhoisQueue()
            performTask?.cancel()
            stopPresenceChecks()
        case .received(let message):
            handle(message)
        case .sent:
            break
        }
    }

    /// The network's startup commands. Messages go out without being shown
    /// or logged, as they are usually a password for services.
    private func runPerformCommands() async {
        for command in config.performCommands {
            let line = command.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !Task.isCancelled, isConnected else { continue }
            guard line.hasPrefix("/") else {
                // A raw protocol line.
                if let message = IRCMessage(parsing: line) { send(message) }
                continue
            }
            let words = line.dropFirst().split(separator: " ", maxSplits: 2).map(String.init)
            switch words.first?.lowercased() {
            case "wait", "sleep":
                let seconds = words.count > 1 ? Double(words[1]) ?? 1 : 1
                try? await Task.sleep(for: .seconds(min(seconds, 60)))
            case "msg", "privmsg", "notice":
                guard words.count == 3 else { continue }
                send(IRCMessage(command: words[0].lowercased() == "notice" ? "NOTICE" : "PRIVMSG",
                                params: [words[1], words[2]]))
            case "quote", "raw":
                if let message = IRCMessage(parsing: String(line.drop { $0 != " " }.dropFirst())) { send(message) }
            default:
                submit(line, in: serverBuffer)
            }
        }
    }

    /// When the startup commands identify to services, the channels wait for
    /// the login -- for at most 15 seconds: channels for registered users
    /// refuse anyone not yet logged in.
    private func waitForServicesLogin() async {
        let identifies = config.performCommands.contains {
            let line = $0.lowercased()
            return line.contains("nickserv") || line.contains("identify") || line.hasPrefix("/ns ")
        }
        guard identifies else { return }
        let started = ContinuousClock.now
        while !isLoggedIn, isConnected, !Task.isCancelled, ContinuousClock.now - started < .seconds(15) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Services say we are logged in: the channels that refused us before
    /// are tried again, once.
    private func loggedIn() {
        guard !isLoggedIn else { return }
        isLoggedIn = true
        guard !retryAfterLogin.isEmpty else { return }
        addInfo("Logged in: joining \(retryAfterLogin.joined(separator: ", ")) again")
        sendJoins(retryAfterLogin)
        retryAfterLogin = []
    }

    private func rejoinChannels() {
        var channels: [String] = []
        for name in config.autoJoin where !name.isEmpty {
            channels.append(name)
            openBuffer(named: name, kind: .channel).wantsJoin = true
        }
        for buffer in buffers where buffer.kind == .channel && buffer.wantsJoin
            && !channels.contains(where: { isupport.caseMapping.equal($0, buffer.name) }) {
            channels.append(buffer.name)
        }
        autoJoinRequested = Set(channels.map(fold))
        sendJoins(channels)
    }

    /// Several channels per JOIN, each line kept well short of the limit.
    private func sendJoins(_ channels: [String]) {
        var batch: [String] = []
        for channel in channels {
            if (batch + [channel]).joined(separator: ",").utf8.count > 400 {
                send(IRCMessage("JOIN", batch.joined(separator: ",")))
                batch = []
            }
            batch.append(channel)
        }
        if !batch.isEmpty { send(IRCMessage("JOIN", batch.joined(separator: ","))) }
    }

    /// Joins the channels, the first of them shown once joined.
    func join(_ channels: [String]) {
        guard isConnected, let first = channels.first else { return }
        pendingSelection = first
        sendJoins(channels)
    }

    func isJoined(_ channel: String) -> Bool {
        buffer(named: channel)?.isJoined ?? false
    }

    func isMe(_ name: String?) -> Bool {
        guard let name else { return false }
        return isupport.caseMapping.equal(name, nick)
    }

    private func fold(_ nick: String) -> String {
        isupport.caseMapping.fold(nick)
    }

    func handle(_ message: IRCMessage) {
        let source = message.prefix?.name ?? ""
        let time = message.serverTime ?? .now
        let fromMe = isMe(source)

        switch message.command {
        case "PRIVMSG", "NOTICE":
            handleText(message, source: source, time: time, fromMe: fromMe)

        case "JOIN":
            guard let channel = message[param: 0] else { return }
            let buffer = openBuffer(named: channel, kind: .channel)
            if fromMe {
                buffer.isJoined = true
                buffer.wantsJoin = true
                buffer.members = [:]
                if let pending = pendingSelection, isupport.caseMapping.equal(pending, channel) {
                    selectedBufferID = buffer.id
                    pendingSelection = nil
                } else if !hasShownFirstChannel, selectedBufferID == serverBuffer.id {
                    // Opening a network shows its first channel, not the MOTD.
                    selectedBufferID = buffer.id
                }
                hasShownFirstChannel = true
            }
            buffer.members[fold(source)] = ChannelMember(nick: source)
            seenOnline(source)
            // extended-join: the account, "*" for none, and the real name.
            let account = message[param: 1].flatMap { $0 == "*" ? nil : $0 }
            noteNick(source, prefix: message.prefix, account: account, realName: message[param: 2], time: time)
            let mask = message.prefix.map { "\($0.user ?? "")@\($0.host ?? "")" } ?? ""
            add(ChatLine(time: time, kind: .join, sender: source,
                         text: "\(source) (\(mask)) joined \(channel)", isSelf: fromMe), to: buffer)
            emit("join", in: buffer, nick: source, isSelf: fromMe, fields: [
                "channel": .string(channel), "nick": .string(source), "user": JSON(message.prefix?.user),
                "host": JSON(message.prefix?.host), "account": JSON(account), "real_name": JSON(message[param: 2]),
                "self": JSON(fromMe)], time: time)

        case "PART":
            guard let channel = message[param: 0], let buffer = buffer(named: channel) else { return }
            if fromMe {
                buffer.isJoined = false
                buffer.members = [:]
            } else {
                buffer.members[fold(source)] = nil
            }
            let reason = message[param: 1].map { " (\($0))" } ?? ""
            add(ChatLine(time: time, kind: .part, sender: source,
                         text: "\(source) left \(channel)\(reason)", isSelf: fromMe), to: buffer)
            emit("part", in: buffer, nick: source, isSelf: fromMe, fields: [
                "channel": .string(channel), "nick": .string(source), "reason": JSON(message[param: 1]),
                "self": JSON(fromMe)], time: time)

        case "KICK":
            guard let channel = message[param: 0], let victim = message[param: 1],
                  let buffer = buffer(named: channel) else { return }
            if isMe(victim) {
                buffer.isJoined = false
                buffer.members = [:]
            } else {
                buffer.members[fold(victim)] = nil
            }
            let reason = message[param: 2].map { " (\($0))" } ?? ""
            add(ChatLine(time: time, kind: .kick, sender: source,
                         text: "\(source) kicked \(victim) from \(channel)\(reason)",
                         isHighlight: isMe(victim)), to: buffer)
            emit("kick", in: buffer, nick: victim, isSelf: isMe(victim), fields: [
                "channel": .string(channel), "nick": .string(source), "target": .string(victim),
                "reason": JSON(message[param: 2]), "self": JSON(isMe(victim))], time: time)

        case "QUIT":
            let reason = message[param: 0].map { " (\($0))" } ?? ""
            let key = fold(source)
            let shared = channels.filter { $0.members[key] != nil }.map(\.name)
            emit("quit", in: nil, nick: source, fields: [
                "nick": .string(source), "reason": JSON(message[param: 0]), "channels": JSON(shared)], time: time)
            query(with: source)?.partnerOnline = false
            for buffer in buffers {
                let present = buffer.kind == .channel ? buffer.members[key] != nil
                    : buffer.kind == .query && isupport.caseMapping.equal(buffer.name, source)
                guard present else { continue }
                buffer.members[key] = nil
                add(ChatLine(time: time, kind: .quit, sender: source,
                             text: "\(source) quit\(reason)"), to: buffer)
            }

        case "NICK":
            guard let new = message[param: 0] else { return }
            noteNick(new, prefix: message.prefix, time: time)
            emit("nick", in: nil, nick: source, isSelf: fromMe, fields: [
                "old": .string(source), "new": .string(new), "self": JSON(fromMe)], time: time)
            let oldKey = fold(source)
            if var info = users.removeValue(forKey: oldKey) {
                info.nick = new
                users[fold(new)] = info
            }
            if let spoke = lastSpoke.removeValue(forKey: oldKey) { lastSpoke[fold(new)] = spoke }
            for buffer in buffers {
                if buffer.kind == .channel, var member = buffer.members.removeValue(forKey: oldKey) {
                    member.nick = new
                    buffer.members[fold(new)] = member
                } else if buffer.kind == .query, isupport.caseMapping.equal(buffer.name, source) {
                    buffer.name = new
                    layoutChanged()
                } else if !(fromMe && buffer.kind != .query) {
                    continue
                }
                let text = fromMe ? "You are now known as \(new)" : "\(source) is now known as \(new)"
                add(ChatLine(time: time, kind: .nick, sender: source, text: text, isSelf: fromMe), to: buffer)
            }

        case "TOPIC":
            guard let channel = message[param: 0], let buffer = buffer(named: channel) else { return }
            let topic = message[param: 1] ?? ""
            buffer.topic = topic.isEmpty ? nil : topic
            add(ChatLine(time: time, kind: .topic, sender: source,
                         text: topic.isEmpty ? "\(source) cleared the topic"
                             : "\(source) changed the topic to: \(topic)"), to: buffer)
            emit("topic", in: buffer, nick: source, text: IRCFormatting.strip(topic), isSelf: fromMe, fields: [
                "channel": .string(channel), "nick": .string(source), "text": .string(IRCFormatting.strip(topic))],
                 time: time)

        case "MODE":
            handleMode(message, source: source, time: time)

        case "AWAY":
            let key = fold(source)
            for buffer in buffers where buffer.kind == .channel {
                buffer.members[key]?.isAway = !message.params.isEmpty
            }

        case "INVITE":
            guard let channel = message[param: 1] else { return }
            addInfo("\(source) invites you to \(channel)", to: selectedBuffer, time: time)
            var event = ScriptEvent(on: "invite", network: displayName, networkID: id, channel: channel, nick: source,
                                    fields: ["channel": .string(channel), "nick": .string(source)],
                                    origin: ScriptOrigin(session: id, target: source, isChannel: false))
            event.time = time
            scriptEvent(event)

        case "ERROR":
            addInfo(message.params.last ?? "Error", kind: .error, time: time)

        case "PING", "PONG", "CAP", "AUTHENTICATE", "CHGHOST", "ACCOUNT", "BATCH", "SETNAME", "TAGMSG":
            break

        default:
            if let numeric = message.numeric {
                handleNumeric(numeric, message, time: time)
            } else {
                addInfo(message.serialized, time: time)
            }
        }
    }

    /// Keeps a nick in the network's list, with what came with it.
    private func noteNick(_ nick: String, prefix: IRCPrefix?, account: String? = nil, realName: String? = nil,
                          time: Date) {
        guard !nick.isEmpty, !nick.contains("."), prefix?.user != nil || prefix == nil else { return }
        log?.noteNicks([LogStore.SeenNick(nick: nick, user: prefix?.user, host: prefix?.host, account: account,
                                          realName: realName)], network: id, time: time)
    }

    /// Whether the nick is around now: in a channel joined, or online in a
    /// private chat.
    func isOnline(_ nick: String) -> Bool {
        let key = fold(nick)
        if channels.contains(where: { $0.isJoined && $0.members[key] != nil }) { return true }
        return query(with: nick)?.partnerOnline == true
    }

    private func handleText(_ message: IRCMessage, source: String, time: Date, fromMe: Bool) {
        guard message.params.count >= 2, var target = message[param: 0],
              let text = message.params.last else { return }
        let isNotice = message.command == "NOTICE"

        // STATUSMSG: `@#channel` reaches only the channel's ops.
        if let first = target.first, isupport.membershipPrefixes.contains(where: { $0.symbol == first }),
           isupport.isChannel(String(target.dropFirst())) {
            target = String(target.dropFirst())
        }

        let ctcp = CTCP(text: text)
        if !fromMe, message.prefix?.user != nil, !source.isEmpty {
            seenOnline(source)
            if ctcp == nil || ctcp?.command == "ACTION" {
                let key = fold(source)
                if (lastSpoke[key] ?? .distantPast) < time { lastSpoke[key] = time }
            }
        }
        let ignore = fromMe ? nil : highlightRules().ignore(of: source)
        if let ignore, ctcp == nil || ctcp?.command == "ACTION" {
            let inChannel = isupport.isChannel(target)
            if !inChannel || ignore == .everything {
                // Logged, not shown: taking the ignore off brings it back.
                logSilently(ChatLine(time: time, kind: ctcp != nil ? .action : (isNotice ? .notice : .message),
                                     sender: source, text: ctcp?.argument ?? text, isIgnored: true),
                            in: inChannel ? target : source, kind: inChannel ? .channel : .query)
                let ignoredText = IRCFormatting.strip(ctcp?.argument ?? text)
                var event = ScriptEvent(on: inChannel ? (ctcp != nil ? "action" : (isNotice ? "notice" : "message"))
                                            : "private_message", network: displayName, networkID: id,
                                        channel: inChannel ? target : source, nick: source, text: ignoredText,
                                        isSelf: false, fields: ["channel": inChannel ? .string(target) : .null,
                                                                "nick": .string(source), "text": .string(ignoredText)],
                                        origin: ScriptOrigin(session: id, target: inChannel ? target : source,
                                                             isChannel: inChannel))
                event.time = time
                event.isIgnored = true
                scriptEvent(event)
                return
            }
        } else if ignore != nil {
            return // CTCP requests from someone ignored: not even mentioned
        }
        if let ctcp, ctcp.command != "ACTION" {
            if isNotice {
                addInfo("CTCP \(ctcp.command) reply from \(source): \(ctcp.argument ?? "")",
                        to: selectedBuffer, time: time)
            } else if !fromMe {
                addInfo("\(source) sent a CTCP \(ctcp.command) request", time: time)
                answer(ctcp, from: source, target: target)
                var event = ScriptEvent(on: "ctcp", network: displayName, networkID: id, nick: source,
                                        text: "\(ctcp.command) \(ctcp.argument ?? "")".trimmingCharacters(in: .whitespaces),
                                        fields: ["nick": .string(source), "command": .string(ctcp.command),
                                                 "argument": JSON(ctcp.argument)],
                                        origin: ScriptOrigin(session: id, target: source, isChannel: false))
                event.time = time
                scriptEvent(event)
            }
            return
        }

        let buffer: ChatBuffer
        if isupport.isChannel(target) {
            buffer = openBuffer(named: target, kind: .channel)
        } else if fromMe {
            buffer = openBuffer(named: target, kind: .query)
        } else if message.prefix?.user == nil || source.isEmpty {
            // From the server itself, not a user.
            buffer = serverBuffer
        } else if isNotice {
            // Notices from services and bots: where the user is looking, or
            // an open private chat with the sender.
            buffer = self.buffer(named: source) ?? selectedBuffer ?? serverBuffer
        } else {
            buffer = openBuffer(named: source, kind: .query)
        }

        if buffer.kind == .query, !fromMe { buffer.partnerOnline = true }
        let kind: ChatLine.Kind = ctcp != nil ? .action : (isNotice ? .notice : .message)
        let body = ctcp?.argument ?? (ctcp != nil ? "" : text)
        let highlight = !fromMe && ignore == nil && mentionsMe(body)
        let line = ChatLine(time: time, kind: kind, sender: source.isEmpty ? nil : source, text: body,
                            isSelf: fromMe, isHighlight: highlight)
        if !fromMe, message.prefix?.user != nil { noteNick(source, prefix: message.prefix, time: time) }
        add(line, to: buffer)
        if buffer === memoBuffer, !fromMe { memos.received(body) }
        emitText(line, raw: body, kind: kind, in: buffer, message: message, fromMe: fromMe)
        if buffer.kind != .server, buffer !== memoBuffer, let reply = autoReply(line, buffer.kind) {
            answer(reply, in: buffer)
        }
    }

    /// A message, action or notice, told to scripts: in a channel, as a
    /// mention when it is one; in a private chat, also as a new conversation
    /// when it starts one.
    private func emitText(_ line: ChatLine, raw: String, kind: ChatLine.Kind, in buffer: ChatBuffer, message: IRCMessage,
                          fromMe: Bool) {
        guard buffer !== memoBuffer, let source = line.sender else { return }
        // A script's own line, echoed back by the server: not for scripts.
        if fromMe, capabilities.contains("echo-message"), let target = message[param: 0], isScriptEcho(raw, to: target) {
            return
        }
        let text = IRCFormatting.strip(raw)
        var fields: [String: JSON] = [
            "nick": .string(source), "user": JSON(message.prefix?.user), "host": JSON(message.prefix?.host),
            "account": JSON(message.tags["account"] ?? users[fold(source)]?.account), "text": .string(text),
            "raw_text": .string(raw), "self": JSON(fromMe), "highlight": JSON(line.isHighlight),
            "tags": .object(message.tags.mapValues { JSON.string($0) })]
        switch buffer.kind {
        case .channel:
            fields["channel"] = .string(buffer.name)
            let on = kind == .action ? "action" : (kind == .notice ? "notice" : "message")
            emit(on, in: buffer, nick: source, text: text, isSelf: fromMe, fields: fields, time: line.time)
            if line.isHighlight {
                fields["words"] = JSON(highlightRules().words.filter { text.localizedCaseInsensitiveContains($0) })
                emit("mention", in: buffer, nick: source, text: text, isSelf: fromMe, fields: fields, time: line.time)
            }
        case .query where kind == .notice, .server:
            emit("notice", in: buffer.kind == .server ? nil : buffer, nick: source, text: text, isSelf: fromMe,
                 fields: fields, time: line.time)
        case .query:
            fields["is_action"] = JSON(kind == .action)
            emit("private_message", in: buffer, nick: source, text: text, isSelf: fromMe, fields: fields, time: line.time)
            let recent = recentLines(ofQuery: buffer.name, limit: 30)
            if !fromMe, AutoReplier.position(inConversation: recent) == 1 {
                let said = recent.filter { $0.kind == .message || $0.kind == .action }
                fields["previous"] = JSON(said.count >= 2 ? said[said.count - 2].time : nil)
                emit("new_private_chat", in: buffer, nick: source, text: text, isSelf: fromMe, fields: fields,
                     time: line.time)
            }
        }
    }

    private func handleMode(_ message: IRCMessage, source: String, time: Date) {
        guard let target = message[param: 0], message.params.count >= 2 else { return }
        // +r on ourselves: services registered us, as Anope and others do.
        if isMe(target), let modes = message[param: 1], let plus = modes.firstIndex(of: "+"),
           modes[plus...].prefix(while: { $0 != "-" }).contains("r") {
            loggedIn()
        }
        let modeText = message.params.dropFirst().joined(separator: " ")
        emit("mode", in: isupport.isChannel(target) ? buffer(named: target) : nil, nick: source, text: modeText,
             isSelf: isMe(source), fields: [
                "target": .string(target), "nick": .string(source), "modes": .string(message.params[1]),
                "arguments": JSON(Array(message.params.dropFirst(2)))], time: time)
        guard isupport.isChannel(target), let buffer = buffer(named: target) else {
            addInfo("\(source) sets mode \(modeText) on \(target)", time: time)
            return
        }
        var arguments = message.params.dropFirst(2).makeIterator()
        var adding = true
        for mode in message.params[1] {
            switch mode {
            case "+": adding = true
            case "-": adding = false
            default:
                guard isupport.modeTakesParameter(mode, adding: adding) else { continue }
                let argument = arguments.next()
                guard let symbol = isupport.membershipSymbol(for: mode), let nick = argument,
                      var member = buffer.members[fold(nick)] else { continue }
                if adding {
                    if !member.prefixes.contains(symbol) {
                        let order = isupport.membershipPrefixes.map(\.symbol)
                        member.prefixes = String((member.prefixes + String(symbol))
                            .sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) })
                    }
                } else {
                    member.prefixes.removeAll { $0 == symbol }
                }
                buffer.members[fold(nick)] = member
            }
        }
        add(ChatLine(time: time, kind: .mode, sender: source,
                     text: "\(source) sets mode \(modeText)"), to: buffer)
    }

    private func handleNumeric(_ numeric: Int, _ message: IRCMessage, time: Date) {
        // The first parameter of every numeric is our own nick.
        let params = Array(message.params.dropFirst())
        let text = params.joined(separator: " ")

        switch numeric {
        case 5:
            isupport.apply(message)
            if let network = isupport.networkName, config.name.isEmpty {
                serverBuffer.name = network
            }

        case 332: // RPL_TOPIC
            guard params.count >= 2, let buffer = buffer(named: params[0]) else { break }
            buffer.topic = params[1]
            addInfo("Topic: \(params[1])", kind: .topic, to: buffer, time: time)

        case 333: // RPL_TOPICWHOTIME
            guard params.count >= 3, let buffer = buffer(named: params[0]) else { break }
            let setter = IRCPrefix(parsing: Substring(params[1])).name
            let when = Double(params[2]).map { Date(timeIntervalSince1970: $0).formatted() } ?? params[2]
            addInfo("Topic set by \(setter) on \(when)", kind: .topic, to: buffer, time: time)

        case 353: // RPL_NAMREPLY: `<nick> <symbol> <channel> :<names>`
            guard params.count >= 3, let buffer = buffer(named: params[1]) else { break }
            if !buffer.namesInProgress {
                buffer.members = [:]
                buffer.namesInProgress = true
            }
            var seen: [LogStore.SeenNick] = []
            for entry in params[2].split(separator: " ") {
                let (symbols, rest) = isupport.splitMembership(String(entry))
                // userhost-in-names sends `nick!user@host`.
                let prefix = IRCPrefix(parsing: Substring(rest))
                let nick = prefix.name
                buffer.members[fold(nick)] = ChannelMember(nick: nick, prefixes: symbols)
                seenOnline(nick)
                seen.append(LogStore.SeenNick(nick: nick, user: prefix.user, host: prefix.host))
            }
            // The channel's people, kept in the network's nick list.
            log?.noteNicks(seen, network: id, time: time)

        case 366: // RPL_ENDOFNAMES
            if let channel = params.first, let buffer = buffer(named: channel) {
                buffer.namesInProgress = false
            }

        case 331, 324, 329: // no topic, channel modes, creation time
            if let channel = params.first, let buffer = buffer(named: channel) {
                addInfo(params.dropFirst().joined(separator: " "), to: buffer, time: time)
            }

        case 321: // RPL_LISTSTART
            break

        case 322: // RPL_LIST: `<channel> <users> :<topic>`
            guard let name = params.first else { break }
            if !isListingChannels { beginListing() } // a LIST typed with /quote
            listing.append(ListedChannel(name: name, users: params.count > 1 ? Int(params[1]) ?? 0 : 0,
                                         topic: params.count > 2 ? IRCFormatting.strip(params[2]) : ""))
            // Shown as it comes, but a few times a second: redrawing for
            // every one of tens of thousands of channels would stall.
            if ContinuousClock.now - lastListPublish > .milliseconds(400) { publishListing() }

        case 323: // RPL_LISTEND
            publishListing()
            channelListDate = time
            isListingChannels = false
            log?.saveChannelList(channelList, network: id, fetched: time)

        case 305: // RPL_UNAWAY
            if isAway { emit("back", in: serverBuffer) }
            isAway = false
            addInfo(text, time: time)

        case 306: // RPL_NOWAWAY
            if !isAway { emit("away", in: serverBuffer, fields: ["message": .null]) }
            isAway = true
            addInfo(text, time: time)

        case 301: // RPL_AWAY
            guard params.count >= 2 else { break }
            users[fold(params[0])]?.awayMessage = params[1]
            if quietWhois.contains(fold(params[0])) { break }
            addInfo("\(params[0]) is away: \(params[1])", to: buffer(named: params[0]) ?? selectedBuffer, time: time)

        case 311...319, 330, 338, 378, 671, 276, 307, 320, 335: // WHOIS
            recordWhois(numeric, params, time: time)
            if numeric == 311, params.count >= 5 { // RPL_WHOISUSER: nick user host * :real name
                log?.noteNicks([LogStore.SeenNick(nick: params[0], user: params[1], host: params[2],
                                                  realName: params[4])], network: id, time: time)
            }
            if let nick = params.first, quietWhois.contains(fold(nick)) {
                if numeric == 318 { finishQuietWhois(nick) }
                break
            }
            addInfo(text, to: selectedBuffer, time: time)

        case 263, 416: // RPL_TRYAGAIN, ERR_TOOMANYMATCHES: the server refused
            if params.first?.uppercased() == "WHOIS", let nick = whoisInFlight {
                // Asked too fast after all: the nick goes back in the queue.
                whoisQueue.insert(nick, at: 0)
                whoisInFlight = nil
                whoisBackoff = .seconds(10)
            } else {
                publishListing()
                isListingChannels = false
            }
            addInfo(text, kind: .error, to: selectedBuffer, time: time)

        case 401 where quietWhois.contains(fold(params.first ?? "")): // no such nick, asked quietly
            query(with: params[0])?.partnerOnline = false
            finishQuietWhois(params[0])

        case 303 where !isonAsked.isEmpty && !isonAsked[0].isEmpty: // RPL_ISON, to our own check
            let asked = isonAsked.removeFirst()
            let online = Set((params.last ?? "").split(separator: " ").map { fold(String($0)) })
            for buffer in buffers where buffer.kind == .query && asked.contains(fold(buffer.name)) {
                buffer.partnerOnline = online.contains(fold(buffer.name))
            }

        case 303:
            if !isonAsked.isEmpty { isonAsked.removeFirst() }
            addInfo("Online: \(params.last ?? "")", time: time)

        case 401: // ERR_NOSUCHNICK
            query(with: params.first ?? "")?.partnerOnline = false
            addInfo(text, kind: .error, to: selectedBuffer, time: time)

        case 900: // RPL_LOGGEDIN
            addInfo(params.last ?? text, time: time)
            loggedIn()

        case 400...599:
            // About a channel: said in the channel, not wherever the user is.
            if let channel = params.first, isupport.isChannel(channel) {
                if !isLoggedIn, autoJoinRequested.contains(fold(channel)),
                   !retryAfterLogin.contains(where: { fold($0) == fold(channel) }) {
                    retryAfterLogin.append(channel)
                }
                addInfo(params.dropFirst().joined(separator: " "), kind: .error,
                        to: buffer(named: channel) ?? selectedBuffer, time: time)
            } else {
                addInfo(text, kind: .error, to: selectedBuffer, time: time)
            }

        default:
            addInfo(text, time: time)
        }
    }

    // MARK: - Channel list

    /// The channel list as last fetched, from the log database, so it is not
    /// downloaded on every launch.
    func loadSavedChannelList() {
        guard channelListDate == nil, !isListingChannels, let saved = log?.savedChannelList(network: id) else { return }
        channelList = saved.channels
        listingCount = saved.channels.count
        channelListDate = saved.fetched
    }

    /// Asks the server for its channels, all of them unless `arguments`
    /// narrow it (`>10`, a mask); the answer fills `channelList`.
    func requestChannelList(arguments: [String] = []) {
        guard isConnected, !isListingChannels else { return }
        beginListing()
        send(IRCMessage(command: "LIST", params: arguments))
    }

    private func beginListing() {
        listing = []
        channelList = []
        listingCount = 0
        isListingChannels = true
        lastListPublish = .now
    }

    private func publishListing() {
        channelList.append(contentsOf: listing)
        listing = []
        listingCount = channelList.count
        lastListPublish = .now
    }

    /// Keeps a WHOIS reply's fields; `params` start with the nick asked about.
    private func recordWhois(_ numeric: Int, _ params: [String], time: Date) {
        guard let nick = params.first else { return }
        let key = fold(nick)
        if numeric == 311 {
            // The first line of a reply: start over, so nothing stale is kept.
            var info = UserInfo(nick: nick, updated: time)
            info.username = params[safe: 1]
            info.host = params[safe: 2]
            info.realName = params.count >= 5 ? params.last : nil
            users[key] = info
            return
        }
        // 314 and 315 share the range but answer WHOWAS and WHO.
        guard numeric != 314, numeric != 315, var info = users[key] else { return }
        let last = params.last ?? ""
        switch numeric {
        case 312:
            info.server = params[safe: 1]
            info.serverInfo = params.count >= 3 ? last : nil
        case 313: info.isOperator = true
        case 317:
            info.idleSeconds = params[safe: 1].flatMap { Int($0) }
            info.signedOn = params[safe: 2].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        case 318: break
        case 319: info.channels += last.split(separator: " ").map(String.init)
        case 330: info.account = params[safe: 1]
        case 338: info.actualHost = params.count >= 3 ? params[1...].dropLast().joined(separator: " ") : params[safe: 1]
        case 378: info.actualHost = last.replacingOccurrences(of: "is connecting from ", with: "")
        case 671: info.isSecure = true
        case 335: info.isBot = true
        default:
            if !last.isEmpty { info.notes.append(last) }
        }
        info.updated = time
        users[key] = info
    }

    // MARK: - WHOIS for several users

    /// WHOIS for each nick, one at a time: the next goes when the reply to
    /// the last is complete, and no sooner than two seconds after it. The
    /// replies are kept for the member list, not printed.
    func queueWhois(_ nicks: [String], includingMe: Bool = false) {
        for nick in nicks where (includingMe || !isMe(nick)) && !whoisQueue.contains(where: { fold($0) == fold(nick) }) {
            whoisQueue.append(nick)
        }
        guard whoisTask == nil, isConnected else { return }
        whoisTask = Task { [weak self] in
            await self?.runWhoisQueue()
            self?.whoisTask = nil
        }
    }

    @ObservationIgnored private var whoisBackoff: Duration = .zero
    /// The least time between two queued WHOIS requests.
    @ObservationIgnored var whoisSpacing: Duration = .seconds(2)
    private static let whoisTimeout: Duration = .seconds(15)

    private func runWhoisQueue() async {
        while isConnected, !whoisQueue.isEmpty, !Task.isCancelled {
            let nick = whoisQueue.removeFirst()
            let key = fold(nick)
            quietWhois.insert(key)
            whoisInFlight = key
            let started = ContinuousClock.now
            send(IRCMessage("WHOIS", nick))
            while whoisInFlight == key, ContinuousClock.now - started < NetworkSession.whoisTimeout {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if whoisInFlight == key { // no end of reply came
                whoisInFlight = nil
                quietWhois.remove(key)
            }
            let wait = max(whoisSpacing - (ContinuousClock.now - started), whoisBackoff)
            whoisBackoff = .zero
            try? await Task.sleep(for: wait)
        }
    }

    /// Whether a WHOIS for the nick is waiting or on its way.
    func isWhoisPending(_ nick: String) -> Bool {
        whoisInFlight == fold(nick) || whoisQueue.contains { fold($0) == fold(nick) }
    }

    private func stopWhoisQueue() {
        whoisTask?.cancel()
        whoisTask = nil
        whoisQueue = []
        quietWhois = []
        whoisInFlight = nil
    }

    private func finishQuietWhois(_ nick: String) {
        let key = fold(nick)
        quietWhois.remove(key)
        if whoisInFlight == key { whoisInFlight = nil }
    }

    func userInfo(for nick: String) -> UserInfo? {
        users[fold(nick)]
    }

    /// The nick, a highlight word, or a highlight pattern in the text.
    func mentionsMe(_ text: String) -> Bool {
        highlightRules().matches(text, nick: nick)
    }

    // MARK: - Input

    /// Runs what the user typed in a buffer: text is said there, a line that
    /// starts with `/` is a command, and `//` sends a line starting with `/`.
    func submit(_ input: String, in buffer: ChatBuffer) {
        let lines = input.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        inputHistory.append(input)
        if inputHistory.count > 200 { inputHistory.removeFirst() }

        for line in lines {
            if line.hasPrefix("/") && !line.hasPrefix("//") {
                runCommand(line, in: buffer)
            } else {
                say(line.hasPrefix("//") ? String(line.dropFirst()) : line, in: buffer)
            }
        }
    }

    private func requireConnection(_ buffer: ChatBuffer) -> Bool {
        if state == .registered || state == .registering { return true }
        addInfo("Not connected. Use /connect.", kind: .error, to: buffer)
        return false
    }

    func say(_ text: String, in buffer: ChatBuffer) {
        guard buffer.kind != .server else {
            addInfo("This is the server window; use /msg, /join or /quote here.", kind: .error, to: buffer)
            return
        }
        guard buffer.kind != .channel || buffer.isJoined else {
            addInfo("You are not in \(buffer.name); /join to go back in.", kind: .error, to: buffer)
            return
        }
        sendText(text, to: buffer.name, command: "PRIVMSG", action: false, echoIn: buffer)
    }

    enum ScriptMessageKind { case message, action, notice }

    /// A message from a script: to a channel or nick, shown where it went.
    func scriptSend(_ text: String, to target: String, kind: ScriptMessageKind) {
        sendingForScript = true
        defer { sendingForScript = false }
        let echo = isupport.isChannel(target) ? buffer(named: target) : echoBuffer(for: target)
        sendText(text, to: target, command: kind == .notice ? "NOTICE" : "PRIVMSG", action: kind == .action,
                 echoIn: echo ?? (kind == .notice ? nil : openBuffer(named: target, kind: .query)))
    }

    /// Builds an event for scripts and hands it on: `buffer` is where it
    /// happened and where replies go.
    private func emit(_ on: String, in buffer: ChatBuffer?, nick: String? = nil, text: String? = nil,
                      isSelf: Bool? = nil, ignored: Bool = false, fields: [String: JSON] = [:], time: Date = .now) {
        let target = buffer.map { $0.kind == .server ? "" : $0.name }
        var event = ScriptEvent(on: on, network: displayName, networkID: id,
                                channel: buffer?.kind == .channel ? buffer?.name : (buffer?.kind == .query ? buffer?.name : nil),
                                nick: nick, text: text, isSelf: isSelf, fields: fields,
                                origin: target.map { ScriptOrigin(session: id, target: $0, isChannel: buffer?.kind == .channel) })
        event.time = time
        event.isIgnored = ignored
        scriptEvent(event)
    }

    private func sendText(_ text: String, to target: String, command: String, action: Bool,
                          echoIn buffer: ChatBuffer?) {
        guard requireConnection(buffer ?? serverBuffer) else { return }
        var limit = IRCTextSplitter.maximumTextBytes(command: command, target: target, nick: nick)
        if action { limit -= 9 } // \u{01}ACTION ... \u{01}
        for piece in IRCTextSplitter.split(text, maxBytes: limit) {
            let body = action ? CTCP(command: "ACTION", argument: piece).text : piece
            send(IRCMessage(command, target, body))
            // With echo-message the server sends our own messages back, with
            // its timestamp, and they are shown then.
            if sendingForScript { scriptSent.append((target.lowercased(), piece, .now)) }
            if !capabilities.contains("echo-message"), let buffer {
                let kind: ChatLine.Kind = action ? .action : (command == "NOTICE" ? .notice : .message)
                let line = ChatLine(time: .now, kind: kind, sender: nick, text: piece, isSelf: true)
                add(line, to: buffer)
                // What the user typed reaches scripts too, as their own line;
                // with echo-message it does when it comes back.
                if !sendingForScript {
                    emitText(line, raw: piece, kind: kind, in: buffer, message: IRCMessage(command, target, body), fromMe: true)
                }
            }
        }
    }

    /// Set while a script's line is sent: it must not trigger scripts, or a
    /// script could answer itself for ever.
    @ObservationIgnored private var sendingForScript = false
    /// A script's lines lately sent, for knowing them when the server echoes
    /// them back.
    @ObservationIgnored private var scriptSent: [(target: String, text: String, time: Date)] = []

    /// Whether the line is one a script sent a moment ago, echoed back.
    private func isScriptEcho(_ text: String, to target: String) -> Bool {
        scriptSent.removeAll { Date.now.timeIntervalSince($0.time) > 30 }
        guard let index = scriptSent.firstIndex(where: { $0.target == target.lowercased() && $0.text == text }) else {
            return false
        }
        scriptSent.remove(at: index)
        return true
    }

    /// Irctell's own commands, by their full names: what a word glued to
    /// its argument -- `/melooks around` -- is split into.
    private static let splittableCommands = [
        "help", "connect", "server", "reconnect", "disconnect", "quit", "clear", "join", "part", "leave",
        "close", "msg", "privmsg", "query", "me", "action", "notice", "nick", "topic", "whois", "away", "back",
        "kick", "invite", "mode", "list", "quote", "raw",
    ]

    /// Commands that are words of their own, though they start like one of
    /// Irctell's: never split. The rest go to the server as they are.
    private static let wholeCommands: Set<String> = [
        "j", "q", "wi", "nickserv", "chanserv", "memoserv", "operserv", "hostserv", "botserv", "helpserv",
        "ns", "cs", "ms", "os", "hs", "bs", "motd", "names", "who", "whowas", "info", "version", "time", "admin",
        "lusers", "links", "stats", "knock", "silence", "watch", "monitor", "userhost", "ison", "oper", "kill",
        "wallops", "ping", "map", "rules", "setname", "cycle", "kickban", "partall", "listen", "modes",
        "quiet", "servlist", "squery", "connectinfo",
    ]

    /// `/melooks around` as `/me looks around`: a known command run into
    /// its first word gets its space. Nil when the command is fine as it is.
    static func insertingMissingSpace(_ line: String) -> String? {
        let body = line.dropFirst()
        let word = body.prefix { $0 != " " }
        let lowered = word.lowercased()
        guard !splittableCommands.contains(lowered), !wholeCommands.contains(lowered) else { return nil }
        let command = splittableCommands
            .filter { lowered.hasPrefix($0) && lowered.count > $0.count }
            .max { $0.count < $1.count }
        guard let command else { return nil }
        let glued = word.dropFirst(command.count)
        return "/" + word.prefix(command.count) + " " + glued + body.dropFirst(word.count)
    }

    static let commandHelp = """
        /join #channel [key]   /part [#channel] [reason]   /close
        /msg nick text   /query nick [text]   /me action   /notice target text
        /nick newnick   /topic [text]   /whois nick   /away [message]
        /mode [modes]   /kick nick [reason]   /invite nick [#channel]
        /connect   /disconnect [reason]   /clear   /list   /quote raw line
        Anything else is sent to the server as it is: /motd, /info, ...
        """

    private func runCommand(_ line: String, in buffer: ChatBuffer) {
        if let spaced = NetworkSession.insertingMissingSpace(line) {
            return runCommand(spaced, in: buffer)
        }
        let body = line.dropFirst()
        let command = body.prefix { $0 != " " }.lowercased()
        let rest = body.dropFirst(command.count).drop { $0 == " " }
        let args = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        /// Everything after the first `n` arguments, spaces kept.
        func tail(after n: Int) -> String? {
            var remaining = rest
            for _ in 0..<n {
                remaining = remaining.drop { $0 != " " }.drop { $0 == " " }
            }
            return remaining.isEmpty ? nil : String(remaining)
        }
        let currentChannel = buffer.kind == .channel ? buffer.name : nil

        switch command {
        case "help":
            addInfo(NetworkSession.commandHelp, to: buffer)

        case "run":
            guard let name = args.first else {
                return addInfo("Usage: /run NAME [arguments] — a script with a /run trigger", kind: .error, to: buffer)
            }
            runScript(name, Array(args.dropFirst()), buffer)

        case "connect", "server", "reconnect":
            if command == "reconnect" { reconnect() } else { connect() }

        case "disconnect", "quit":
            disconnect(reason: tail(after: 0) ?? "Leaving")

        case "clear":
            clear(buffer)

        case "join", "j":
            guard let channels = args.first else { return addInfo("Usage: /join #channel [key]", kind: .error, to: buffer) }
            guard requireConnection(buffer) else { return }
            let names = channels.split(separator: ",").map { name -> String in
                isupport.isChannel(String(name)) ? String(name) : "#" + name
            }
            pendingSelection = names.first
            if let existing = names.first.flatMap(self.buffer(named:)), existing.isJoined {
                selectedBufferID = existing.id
            }
            send(IRCMessage(command: "JOIN", params: [names.joined(separator: ",")] + args.dropFirst().prefix(1)))

        case "part", "leave":
            var channel = currentChannel
            var reason = tail(after: 0)
            if let first = args.first, isupport.isChannel(first) {
                channel = first
                reason = tail(after: 1)
            }
            guard let channel else { return addInfo("Usage: /part #channel [reason]", kind: .error, to: buffer) }
            self.buffer(named: channel)?.wantsJoin = false
            send(IRCMessage(command: "PART", params: [channel] + (reason.map { [$0] } ?? [])))

        case "close":
            close(buffer, reason: tail(after: 0))

        case "msg", "privmsg":
            guard args.count >= 2, let text = tail(after: 1) else {
                return addInfo("Usage: /msg target text", kind: .error, to: buffer)
            }
            sendText(text, to: args[0], command: "PRIVMSG", action: false, echoIn: echoBuffer(for: args[0]))

        case "query", "q":
            guard let target = args.first else { return addInfo("Usage: /query nick [text]", kind: .error, to: buffer) }
            let query = openBuffer(named: target, kind: isupport.isChannel(target) ? .channel : .query, select: true)
            if let text = tail(after: 1) { say(text, in: query) }

        case "me", "action":
            guard buffer.kind != .server, let text = tail(after: 0) else { return }
            sendText(text, to: buffer.name, command: "PRIVMSG", action: true, echoIn: buffer)

        case "notice":
            guard args.count >= 2, let text = tail(after: 1) else {
                return addInfo("Usage: /notice target text", kind: .error, to: buffer)
            }
            sendText(text, to: args[0], command: "NOTICE", action: false, echoIn: echoBuffer(for: args[0]))

        case "nick":
            guard let new = args.first else { return addInfo("You are \(nick)", to: buffer) }
            guard requireConnection(buffer) else { return }
            send(IRCMessage("NICK", new))

        case "topic":
            guard let channel = currentChannel else { return addInfo("/topic works in a channel", kind: .error, to: buffer) }
            if let text = tail(after: 0) {
                send(IRCMessage("TOPIC", channel, text))
            } else {
                send(IRCMessage("TOPIC", channel))
            }

        case "whois", "wi":
            guard let target = args.first ?? (buffer.kind == .query ? buffer.name : nil) else { return }
            send(IRCMessage("WHOIS", target))

        case "away":
            setAway(tail(after: 0))

        case "back":
            setAway(nil)

        case "kick":
            guard let channel = currentChannel, let victim = args.first else {
                return addInfo("Usage: /kick nick [reason] (in a channel)", kind: .error, to: buffer)
            }
            send(IRCMessage(command: "KICK", params: [channel, victim] + (tail(after: 1).map { [$0] } ?? [])))

        case "invite":
            guard let who = args.first, let channel = args.dropFirst().first ?? currentChannel else {
                return addInfo("Usage: /invite nick [#channel]", kind: .error, to: buffer)
            }
            send(IRCMessage("INVITE", who, channel))

        case "mode":
            var params = args
            if params.first.map({ !isupport.isChannel($0) && !isMe($0) }) ?? true {
                params.insert(currentChannel ?? nick, at: 0)
            }
            send(IRCMessage(command: "MODE", params: params))

        case "list":
            guard requireConnection(buffer) else { return }
            showsChannelList = true
            requestChannelList(arguments: args)

        case "quote", "raw":
            guard let raw = tail(after: 0), let message = IRCMessage(parsing: raw) else { return }
            send(message)

        default:
            // Unknown here, perhaps known to the server: /list, /motd, /who ...
            guard requireConnection(buffer), let message = IRCMessage(parsing: String(body)) else { return }
            send(message)
        }
    }

    /// Where an outgoing /msg or /notice is shown: the target's buffer when
    /// one is open, else wherever the user is.
    private func echoBuffer(for target: String) -> ChatBuffer? {
        buffer(named: target) ?? selectedBuffer
    }

    // MARK: - Completion

    /// Nicks in a channel that start with `prefix`, for tab completion.
    func completions(for prefix: String, in buffer: ChatBuffer) -> [String] {
        let folded = fold(prefix)
        var candidates = buffer.members.values.map(\.nick)
        if buffer.kind == .query { candidates.append(buffer.name) }
        return candidates
            .filter { fold($0).hasPrefix(folded) && !isMe($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The members sorted the way the nick list shows them: by rank, then
    /// name. A private chat has two: us, and the other one.
    func sortedMembers(of buffer: ChatBuffer) -> [ChannelMember] {
        if buffer.kind == .query {
            return [ChannelMember(nick: nick), ChannelMember(nick: buffer.name)]
        }
        return buffer.members.values.sorted { lhs, rhs in
            let l = isupport.rank(ofPrefixes: lhs.prefixes), r = isupport.rank(ofPrefixes: rhs.prefixes)
            if l != r { return l < r }
            return lhs.nick.localizedStandardCompare(rhs.nick) == .orderedAscending
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// One channel in the server's channel list.
struct ListedChannel: Identifiable, Hashable, Sendable {
    var name: String
    var users: Int
    /// With the formatting codes removed.
    var topic: String
    var id: String { name }
}

/// The channels and private chats open on a network, saved between runs.
struct BufferLayout: Codable, Equatable, Sendable {
    struct Buffer: Codable, Equatable, Sendable {
        var name: String
        var kind: ChatBuffer.Kind
        /// The transcript's search, nil when empty.
        var search: String?
        var aggregatesHistory: Bool?
        var showsNetworkNames: Bool?
        var speaks: Bool?
        var messagesOnly: Bool?
        var draft: String?
        /// Where the transcript was scrolled back to, and what was selected.
        var anchorLine: Int64?
        var selection: TranscriptSelection?
    }
    var buffers: [Buffer] = []
    /// The name of the selected one; nil for the server window.
    var selected: String?
    var serverSearch: String?
    var serverDraft: String?
    /// The buffers are in the order the user arranged; nil in layouts saved
    /// when the sidebar sorted them by name.
    var userOrdered: Bool?
    /// Closed conversations, as they were, for when they are opened again;
    /// the most recently closed last.
    var closed: [Buffer]?
}

extension BufferLayout.Buffer {
    /// What is kept of a conversation.
    @MainActor init(_ buffer: ChatBuffer) {
        self.init(name: buffer.name, kind: buffer.kind,
                  search: buffer.search.isEmpty ? nil : buffer.search,
                  aggregatesHistory: buffer.aggregatesHistory ? true : nil,
                  showsNetworkNames: buffer.showsNetworkNames ? true : nil,
                  speaks: buffer.speaks ? true : nil,
                  messagesOnly: buffer.messagesOnly ? true : nil,
                  draft: buffer.draft.isEmpty ? nil : buffer.draft,
                  anchorLine: buffer.anchorLine, selection: buffer.selection)
    }

    /// Gives the conversation what was kept of it.
    @MainActor func apply(to buffer: ChatBuffer) {
        buffer.search = search ?? ""
        buffer.aggregatesHistory = aggregatesHistory ?? false
        buffer.showsNetworkNames = showsNetworkNames ?? false
        buffer.speaks = speaks ?? false
        buffer.messagesOnly = messagesOnly ?? false
        buffer.draft = draft ?? ""
        buffer.anchorLine = anchorLine
        buffer.selection = selection
    }
}

/// What the client tells others it is, in answer to CTCP VERSION.
enum ClientIdentity {
    static let revealKey = "ctcp.revealClient"
    static let versionKey = "ctcp.version"

    static var standard: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Irctell \(version) on macOS"
    }

    /// The text set in the settings, or "Irctell <version> on macOS"; nil
    /// when the user does not want to tell.
    @MainActor static var current: String? {
        let settings = SettingsStore.shared
        guard settings.bool(forKey: revealKey, default: true) else { return nil }
        let text = (settings.string(forKey: versionKey) ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? standard : text
    }
}

/// How recently a user did something, by the 1, 5 and 30 minute marks.
enum Activity: Sendable {
    case active, recent, idle, gone

    init(since date: Date, now: Date = .now) {
        let seconds = now.timeIntervalSince(date)
        self = seconds < 60 ? .active : seconds < 300 ? .recent : seconds < 1800 ? .idle : .gone
    }

    var emoji: String {
        switch self {
        case .active: "🟢"
        case .recent: "🟡"
        case .idle: "🟠"
        case .gone: "💤"
        }
    }

    var title: String {
        switch self {
        case .active: "Active in the last minute"
        case .recent: "Active in the last 5 minutes"
        case .idle: "Active in the last 30 minutes"
        case .gone: "Idle for more than 30 minutes"
        }
    }
}
