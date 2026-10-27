import AppKit
import Foundation
import Observation

/// The saved networks, and the ones open as tabs. A network can be in the
/// list for years without being opened; opening it adds a tab and connects,
/// closing the tab disconnects and leaves it in the list.
@MainActor @Observable
final class AppModel {
    /// Every saved network, in the order saved.
    private(set) var networks: [NetworkConfig]
    /// The open tabs, left to right.
    private(set) var sessions: [NetworkSession] = []
    var selectedSessionID: NetworkSession.ID? {
        didSet {
            for session in sessions { session.isFrontmost = session.id == selectedSessionID }
        }
    }

    /// The network the Channel List window shows; nil for the selected one.
    var channelListNetwork: NetworkSession.ID?

    /// The network being edited from its tab.
    var editing: NetworkEditorRequest?
    /// The last jump to another network for an unseen private chat: ⌥Tab
    /// goes back across it while still where it led.
    @ObservationIgnored var jump: (from: Place, to: Place)?
    /// The scripts' host; nil until started (and in tests that do not want it).
    var scriptHost: ScriptHost? { ScriptHost.shared.app === self ? ScriptHost.shared : testScriptHost }
    @ObservationIgnored var testScriptHost: ScriptHost?
    /// The side the Backup and Transfer window shows.
    var transferTab = TransferTab.export

    @ObservationIgnored private let store: NetworkStore
    @ObservationIgnored let settings: SettingsStore
    /// Nil in tests that do not look at notifications.
    @ObservationIgnored var notifier: Notifier?
    /// Pictures linked in messages; nil without a log to keep them in.
    @ObservationIgnored let media: MediaStore?
    /// Mentions and private messages that came while the user was away,
    /// shown at the top of the Mentions window until dismissed.
    var awayDigest: [Mention] = []
    /// Whether the user counted as away when last checked.
    @ObservationIgnored var wasAway = false
    /// Whether the Mac counted as idle when last checked.
    @ObservationIgnored var wasIdle = false
    /// The networks marked away, and whether muted, because the Mac went
    /// idle: undone when the user is back.
    @ObservationIgnored var autoAwaySessions: Set<NetworkSession.ID> = []
    /// The message the user went away with, from the toolbar, on every
    /// network; nil when not. Sent again after a reconnect, and to networks
    /// opened meanwhile.
    var awayByUser: String?
    /// When AWAY was last sent to a network for it, so it is not sent again
    /// before the server had time to confirm.
    @ObservationIgnored var awayAsked: [NetworkSession.ID: Date] = [:]
    @ObservationIgnored var autoMuted = false
    /// The loudspeaker's mute; replaceable for tests.
    @ObservationIgnored var isMuted: () -> Bool = { Speaker.shared.isMuted }
    @ObservationIgnored var setMuted: (Bool) -> Void = { Speaker.shared.isMuted = $0 }
    @ObservationIgnored var awayTask: Task<Void, Never>?
    /// What the app is doing, replaceable for tests.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApplication.shared.isActive }
    @ObservationIgnored var idleSeconds: () -> TimeInterval = AppModel.systemIdleSeconds
    /// Opens a window by its scene ID; set by the first view that has the
    /// SwiftUI action to do it.
    @ObservationIgnored var openWindow: ((String) -> Void)?
    /// Nil when the log database cannot be opened: conversations then show
    /// only what came in since launch.
    @ObservationIgnored let log: LogStore?
    @ObservationIgnored private var started = false
    private static let openTabsKey = "openNetworks"
    /// The channels and private chats open on each network, by network ID.
    private static let layoutsKey = "openBuffers"
    private static let addedKnownNetworksKey = "addedKnownNetworks"

    init(store: NetworkStore = .standard, settings: SettingsStore = .shared, log: LogStore? = LogStore.openStandard(),
         notifier: Notifier? = IrctellHome.isRunningTests ? nil : SystemNotifier.shared) {
        self.store = store
        self.settings = settings
        self.log = log
        self.notifier = notifier
        media = log.map { MediaStore(log: $0) }
        networks = store.load()
        media?.mode = { [weak self] network, key, kind in
            self?.mediaMode(network: network, bufferKey: key, kind: kind) ?? .off
        }
        media?.proxy = { [weak self] network in self?.network(network)?.proxy }
        media?.maxBytes = { [settings] in
            (settings.object(forKey: MediaSettings.maxMegabytes) as? Int ?? MediaSettings.defaultMaxMegabytes) << 20
        }
        media?.historyBytesPerSecond = { [settings] in
            (settings.object(forKey: MediaSettings.historySpeed) as? Int ?? MediaSettings.defaultHistorySpeed) << 10
        }
        notifier?.onOpen = { [weak self] info in self?.openNotification(info) }
        // Once, so the well-known networks are there to pick from -- also for
        // a list that was started before they came with the app.
        if !settings.bool(forKey: AppModel.addedKnownNetworksKey) {
            addKnownNetworks()
            settings.set(true, forKey: AppModel.addedKnownNetworksKey)
        }
    }

    var selectedSession: NetworkSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// Favourites first, then by name.
    var sortedNetworks: [NetworkConfig] {
        networks.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Pictures

    /// The global choice: off, collapsed or shown.
    var defaultMediaMode: MediaMode {
        guard settings.bool(forKey: MediaSettings.enabled, default: true) else { return .off }
        return settings.bool(forKey: MediaSettings.startCollapsed, default: false) ? .collapsed : .show
    }

    /// The conversation's own choice; nil for the global one.
    func ownMediaMode(network: UUID, buffer name: String, kind: ChatBuffer.Kind) -> MediaMode? {
        let modes = settings.dictionary(forKey: MediaSettings.modes)?[network.uuidString] as? [String: String]
        return modes?[LogStore.key(for: name, kind: kind)].flatMap(MediaMode.init(rawValue:))
    }

    func mediaMode(network: UUID, bufferKey key: String, kind: ChatBuffer.Kind) -> MediaMode {
        // Pictures are fetched directly, not through the proxy: that would
        // tell every site linked who is reading.
        if self.network(network)?.usesProxy == true { return .off }
        let modes = settings.dictionary(forKey: MediaSettings.modes)?[network.uuidString] as? [String: String]
        return modes?[key].flatMap(MediaMode.init(rawValue:)) ?? defaultMediaMode
    }

    func setMediaMode(_ mode: MediaMode?, network: UUID, buffer name: String, kind: ChatBuffer.Kind) {
        var all = settings.dictionary(forKey: MediaSettings.modes) ?? [:]
        var modes = all[network.uuidString] as? [String: String] ?? [:]
        modes[LogStore.key(for: name, kind: kind)] = mode?.rawValue
        all[network.uuidString] = modes.isEmpty ? nil : modes
        settings.set(all, forKey: MediaSettings.modes)
    }

    /// Every ignore, global and per network, as the log applies them.
    var ignoreRules: [IgnoreRule] {
        let global = HighlightRules.globalIgnores(in: settings).map {
            IgnoreRule(network: nil, nick: $0.nick.lowercased(), privateOnly: $0.scope == .privateMessages)
        }
        return global + networks.flatMap { network in
            network.ignores.map {
                IgnoreRule(network: network.id, nick: $0.nick.lowercased(), privateOnly: $0.scope == .privateMessages)
            }
        }
    }

    /// Ignores, or stops ignoring, a nick on one network.
    func setIgnore(_ nick: String, scope: IgnoreEntry.Scope?, network id: NetworkConfig.ID) {
        guard var config = network(id) else { return }
        config.ignores.removeAll { $0.nick.caseInsensitiveCompare(nick) == .orderedSame }
        if let scope { config.ignores.append(IgnoreEntry(nick: nick, scope: scope)) }
        save(config)
    }

    func network(_ id: NetworkConfig.ID) -> NetworkConfig? {
        networks.first { $0.id == id }
    }

    func session(for id: NetworkConfig.ID) -> NetworkSession? {
        sessions.first { $0.id == id }
    }

    /// Reopens the tabs that were open when Irctell last quit; once per run.
    func start() {
        guard !started else { return }
        started = true
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        AppLog.notice("app", "Irctell \(version) started; log \(log == nil ? "not available" : "open")")
        if !IrctellHome.isRunningTests {
            ScriptHost.shared.app = self
            ScriptHost.shared.start()
        }
        let ids = (settings.stringArray(forKey: AppModel.openTabsKey) ?? []).compactMap(UUID.init(uuidString:))
        for id in ids {
            open(id, select: false, connect: network(id)?.connectAtLaunch ?? true)
        }
        selectedSessionID = sessions.first?.id
        startAwayWatch()
    }

    func shutDown() async {
        // Where each conversation was scrolled to, kept for the next launch.
        for session in sessions { session.layoutChanged() }
        if ScriptHost.shared.app === self { await ScriptHost.shared.shutDown() }
        for session in sessions {
            await session.shutDown()
        }
        TorService.shared.stopIfStartedHere()
        SSHTunnelService.shared.closeAll()
    }

    // MARK: - Tabs

    /// Opens the network as a tab, or brings its tab forward, and connects.
    /// A new tab gets the channels and private chats it had last time.
    func open(_ id: NetworkConfig.ID, select: Bool = true, connect: Bool = true) {
        guard let config = network(id) else { return }
        let session: NetworkSession
        if let existing = self.session(for: id) {
            session = existing
        } else {
            session = NetworkSession(config: config, log: log)
            session.media = media
            session.prepareConnection = { [weak self] session in
                guard let config = self?.network(id) else { return }
                switch config.proxyKind {
                case .tor:
                    if !(await TorService.isListening()) { session.addInfo("Starting Tor…") }
                    try await TorService.shared.ensureRunning()
                case .ssh:
                    let tunnels = SSHTunnelService.shared
                    if !tunnels.isOpen(to: config.sshDestination, port: config.sshTunnelPort) {
                        session.addInfo("Opening the SSH tunnel to \(config.sshDestination)…")
                    }
                    try await tunnels.ensureOpen(to: config.sshDestination, port: config.sshTunnelPort)
                case .none, .socks:
                    break
                }
            }
            // A private chat not in front gets its suggested reply meanwhile;
            // the one in front asks for its own.
            session.heard = { [weak session] buffer in
                guard let session, buffer.kind == .query, !session.isShowing(buffer) else { return }
                ReplySuggester.shared.request(for: buffer, in: session, foreground: false)
            }
            session.scriptEvent = { [weak self] event in self?.scriptHost?.dispatch(event) }
            session.runScript = { [weak self, weak session] name, arguments, buffer in
                guard let session else { return }
                guard let host = self?.scriptHost else {
                    return session.addInfo("Scripts are not running.", kind: .error, to: buffer)
                }
                host.run(named: name, arguments: arguments, in: session, buffer: buffer)
            }
            session.autoReply = { [weak session] line, kind in
                guard let session else { return nil }
                var position = 1
                if kind == .query, let sender = line.sender {
                    position = AutoReplier.position(inConversation: session.recentLines(ofQuery: sender, limit: 60))
                }
                return AutoReplier.shared.reply(to: line, in: kind, network: session.id, me: session.nick,
                                                position: position)
            }
            if let layout = savedLayout(for: id) { session.restore(layout) }
            session.onLayoutChange = { [weak self] in self?.saveLayout($0, for: id) }
            session.onAttention = { [weak self, weak session] event in
                guard let self, let session else { return }
                self.handleAttention(event, in: session)
            }
            session.onRead = { [weak self] buffer in
                self?.notifier?.removeDelivered(threadID: AppModel.threadID(network: id, buffer: buffer))
            }
            sessions.append(session)
            rememberOpenTabs()
        }
        if connect, session.isOffline { session.connect() }
        if select { selectedSessionID = session.id }
    }

    func closeTab(_ session: NetworkSession) {
        session.disconnect(reason: "Leaving")
        let index = sessions.firstIndex { $0.id == session.id } ?? 0
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.isEmpty ? nil : sessions[max(0, index - 1)].id
        }
        rememberOpenTabs()
    }

    /// The private chats with messages not seen yet, on every network, the
    /// one waiting longest first. Ignored nicks do not count.
    var unseenPrivateChats: [(session: NetworkSession, buffer: ChatBuffer)] {
        sessions.flatMap { session in
            session.queries.filter { $0.hasHighlight && $0.unreadCount > 0 }.map { (session, $0) }
        }
        .sorted { ($0.buffer.firstUnseen ?? .distantFuture) < ($1.buffer.firstUnseen ?? .distantFuture) }
    }

    /// Opens the private chat whose unseen messages have waited longest.
    func showOldestUnseenPrivateChat() {
        guard let (session, buffer) = unseenPrivateChats.first else { return }
        // Onto another network: where it came from, for going back.
        if let here = currentPlace, here.session != session.id {
            jump = (from: here, to: Place(session: session.id, buffer: buffer.id))
        }
        selectedSessionID = session.id
        session.selectedBufferID = buffer.id
    }

    /// ⌥Tab: the unseen private chat waiting longest, as the red button; with
    /// none waiting, back and forth between the last two conversations --
    /// also across networks, after the button changed network.
    func unseenOrBack() {
        if !unseenPrivateChats.isEmpty { return showOldestUnseenPrivateChat() }
        if let jump, currentPlace == jump.to, let session = session(for: jump.from.session),
           session.buffers.contains(where: { $0.id == jump.from.buffer }) {
            self.jump = (from: jump.to, to: jump.from)
            selectedSessionID = session.id
            session.selectedBufferID = jump.from.buffer
            return
        }
        selectedSession?.selectPreviousBuffer()
    }

    /// A conversation on a network.
    struct Place: Equatable {
        var session: NetworkSession.ID
        var buffer: ChatBuffer.ID
    }

    private var currentPlace: Place? {
        guard let session = selectedSession, let buffer = session.selectedBufferID else { return nil }
        return Place(session: session.id, buffer: buffer)
    }

    /// Dragging a tab: puts it at the gap `index`, 0 before the first tab
    /// and `sessions.count` after the last. Kept for the next launch.
    func moveSession(_ id: NetworkSession.ID, toGap index: Int) {
        guard let from = sessions.firstIndex(where: { $0.id == id }), (0...sessions.count).contains(index) else { return }
        let to = index > from ? index - 1 : index
        guard to != from else { return }
        let moved = sessions.remove(at: from)
        sessions.insert(moved, at: to)
        rememberOpenTabs()
    }

    private func rememberOpenTabs() {
        settings.set(sessions.map(\.id.uuidString), forKey: AppModel.openTabsKey)
    }

    private func savedLayout(for id: NetworkConfig.ID) -> BufferLayout? {
        switch settings.dictionary(forKey: AppModel.layoutsKey)?[id.uuidString] {
        case let data as Data: // as earlier versions kept it
            try? JSONDecoder().decode(BufferLayout.self, from: data)
        case let object?:
            SettingsStore.decode(BufferLayout.self, from: object)
        case nil:
            nil
        }
    }

    /// Kept when the tab is closed, so opening it again brings them back.
    private func saveLayout(_ layout: BufferLayout?, for id: NetworkConfig.ID) {
        var all = settings.dictionary(forKey: AppModel.layoutsKey) ?? [:]
        all[id.uuidString] = layout.flatMap { SettingsStore.plistObject($0) }
        settings.set(all, forKey: AppModel.layoutsKey)
    }

    func selectSession(offset: Int) {
        guard !sessions.isEmpty else { return }
        let index = sessions.firstIndex { $0.id == selectedSessionID } ?? 0
        selectedSessionID = sessions[(index + offset + sessions.count) % sessions.count].id
    }

    func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedSessionID = sessions[index].id
    }

    // MARK: - The saved list

    func beginEditing(_ session: NetworkSession) {
        editing = NetworkEditorRequest(config: session.config, isNew: false)
    }

    /// Adds or updates a saved network; an open tab picks the change up.
    func save(_ config: NetworkConfig) {
        store.savePasswords(of: config)
        if let index = networks.firstIndex(where: { $0.id == config.id }) {
            networks[index] = config
        } else {
            networks.append(config)
        }
        session(for: config.id)?.apply(config)
        persist()
    }

    func remove(_ ids: Set<NetworkConfig.ID>) {
        for id in ids {
            if let session = session(for: id) { closeTab(session) }
            if let config = network(id) { store.deletePasswords(of: config) }
            saveLayout(nil, for: id)
        }
        networks.removeAll { ids.contains($0.id) }
        persist()
    }

    func toggleConnectAtLaunch(_ id: NetworkConfig.ID) {
        guard var config = network(id) else { return }
        config.connectAtLaunch.toggle()
        save(config)
    }

    func autoJoins(_ channel: String, on id: NetworkConfig.ID) -> Bool {
        network(id)?.autoJoin.contains { $0.caseInsensitiveCompare(channel) == .orderedSame } ?? false
    }

    /// Adds the channel to the network's channels joined on connect, or
    /// takes it off.
    func toggleAutoJoin(_ channel: String, on id: NetworkConfig.ID) {
        guard var config = network(id) else { return }
        if autoJoins(channel, on: id) {
            config.autoJoin.removeAll { $0.caseInsensitiveCompare(channel) == .orderedSame }
        } else {
            config.autoJoin.append(channel)
        }
        save(config)
    }

    func toggleFavorite(_ id: NetworkConfig.ID) {
        guard let index = networks.firstIndex(where: { $0.id == id }) else { return }
        networks[index].isFavorite.toggle()
        persist()
    }

    /// Adds the bundled well-known networks that are not in the list yet,
    /// matched by host; returns how many were added.
    @discardableResult
    func addKnownNetworks() -> Int {
        let hosts = Set(networks.map { $0.host.lowercased() })
        let missing = NetworkConfig.knownNetworks().filter { !hosts.contains($0.host.lowercased()) }
        networks += missing
        persist()
        return missing.count
    }

    private func persist() {
        store.save(networks)
    }
}

struct NetworkEditorRequest: Identifiable {
    var config: NetworkConfig
    var isNew: Bool
    var id: UUID { config.id }

    static func newNetwork() -> NetworkEditorRequest {
        NetworkEditorRequest(config: NetworkConfig(name: "", host: ""), isNew: true)
    }
}
