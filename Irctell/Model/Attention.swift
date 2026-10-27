import AppKit
import Foundation

/// The settings of notifications and of being away.
enum AttentionSettings {
    static let notifyMentions = "notify.mentions"
    static let notifyPrivateMessages = "notify.privateMessages"
    static let sound = "notify.sound"
    static let bounce = "notify.bounce"
    static let dockBadge = "notify.dockBadge"
    /// Minutes without keyboard or mouse that count as away; 0 for never.
    static let idleMinutes = "away.idleMinutes"
    static let awayDigest = "away.digest"
    /// When idle: marked away on every network, with this message.
    static let setAwayWhenIdle = "away.setOnNetworks"
    static let awayMessage = "away.message"
    static let defaultAwayMessage = "Away from the keyboard"
    /// When idle: nothing read aloud, notifications silent.
    static let muteWhenIdle = "away.mute"
    static let levels = "notificationLevels"
    static let mentionsIncludePrivate = "mentions.includePrivate"

    static let defaultIdleMinutes = 10
}

/// Deciding what to notify about, the Dock badge, and being away.
extension AppModel {

    // MARK: - Notification levels

    /// The level of a conversation: set by the user, or the default for its
    /// kind.
    func notificationLevel(network: UUID, buffer name: String, kind: ChatBuffer.Kind) -> NotificationLevel {
        let levels = settings.dictionary(forKey: AttentionSettings.levels)?[network.uuidString] as? [String: String]
        return levels?[LogStore.key(for: name, kind: kind)].flatMap(NotificationLevel.init(rawValue:))
            ?? .default(for: kind)
    }

    func setNotificationLevel(_ level: NotificationLevel, network: UUID, buffer name: String, kind: ChatBuffer.Kind) {
        var all = settings.dictionary(forKey: AttentionSettings.levels) ?? [:]
        var levels = all[network.uuidString] as? [String: String] ?? [:]
        levels[LogStore.key(for: name, kind: kind)] = level == .default(for: kind) ? nil : level.rawValue
        all[network.uuidString] = levels.isEmpty ? nil : levels
        settings.set(all, forKey: AttentionSettings.levels)
    }

    // MARK: - Notifying

    static func threadID(network: UUID, buffer: ChatBuffer) -> String {
        "\(network.uuidString)/\(LogStore.key(for: buffer.name, kind: buffer.kind))"
    }

    /// A line from someone else: notifies, counts for the Dock, and goes in
    /// the away digest, as the conversation's level and the settings say --
    /// unless the user is looking at that conversation.
    func handleAttention(_ event: AttentionEvent, in session: NetworkSession) {
        let level = notificationLevel(network: event.networkID, buffer: event.bufferName, kind: event.bufferKind)
        let wanted = switch level {
        case .none: false
        case .mentions: event.reason != .message
        case .all: true
        }
        guard wanted else { return }
        let buffer = event.bufferKind == .server ? session.serverBuffer
            : session.buffer(named: event.bufferName) ?? session.serverBuffer
        if isAppActive() && selectedSessionID == session.id && session.isShowing(buffer) { return }

        buffer.attentionCount += 1
        if isAway(on: session), event.reason != .message, settings.bool(forKey: AttentionSettings.awayDigest, default: true) {
            awayDigest.insert(Mention(line: event.line, networkID: event.networkID,
                                      bufferKey: LogStore.key(for: event.bufferName, kind: event.bufferKind),
                                      bufferKind: event.bufferKind), at: 0)
        }

        let enabled = switch event.reason {
        case .mention: settings.bool(forKey: AttentionSettings.notifyMentions, default: true)
        case .privateMessage: settings.bool(forKey: AttentionSettings.notifyPrivateMessages, default: true)
        case .message: true // the conversation is set to notify on every message
        }
        guard enabled else { return }
        let sender = event.line.sender ?? event.networkName
        let title = switch event.bufferKind {
        case .query: sender
        case .channel: "\(sender) in \(event.bufferName)"
        case .server: sender
        }
        let body = event.line.kind == .action ? "• \(sender) \(IRCFormatting.strip(event.line.text))"
            : IRCFormatting.strip(event.line.text)
        notifier?.post(title: title, subtitle: event.networkName, body: body,
                       sound: settings.bool(forKey: AttentionSettings.sound, default: true) && !Speaker.shared.isMuted,
                       threadID: AppModel.threadID(network: event.networkID, buffer: buffer),
                       userInfo: ["network": event.networkID.uuidString,
                                  "buffer": LogStore.key(for: event.bufferName, kind: event.bufferKind),
                                  "kind": event.bufferKind.rawValue])
        if settings.bool(forKey: AttentionSettings.bounce, default: false), !isAppActive() {
            NSApplication.shared.requestUserAttention(.informationalRequest)
        }
    }

    /// Notifications waiting to be looked at, on every open network.
    var attentionTotal: Int {
        sessions.reduce(0) { total, session in total + session.buffers.reduce(0) { $0 + $1.attentionCount } }
    }

    /// The Dock badge: the count, unless switched off.
    var dockBadge: String? {
        let total = attentionTotal
        guard total > 0, settings.bool(forKey: AttentionSettings.dockBadge, default: true) else { return nil }
        return total > 999 ? "999+" : "\(total)"
    }

    // MARK: - Opening what a notification is about

    func openNotification(_ info: [String: String]) {
        if info["digest"] != nil {
            showWindow(MentionsView.windowID)
        } else if let network = info["network"].flatMap(UUID.init(uuidString:)) {
            reveal(network: network, bufferKey: info["buffer"] ?? "",
                   kind: info["kind"].flatMap(ChatBuffer.Kind.init(rawValue:)) ?? .channel)
        }
    }

    /// Shows the conversation in the main window: its tab opened, without
    /// connecting, if it is not open.
    func reveal(network id: UUID, bufferKey: String, kind: ChatBuffer.Kind) {
        guard network(id) != nil else { return }
        open(id, select: true, connect: false)
        guard let session = session(for: id) else { return }
        if kind == .server || bufferKey.isEmpty {
            session.selectedBufferID = session.serverBuffer.id
        } else {
            session.openBuffer(named: bufferKey, kind: kind, select: true)
        }
        showWindow(IrctellApp.mainWindowID)
    }

    /// Brings a window forward: the user asked for it with a click.
    func showWindow(_ id: String) {
        NSApplication.shared.activate()
        openWindow?(id)
    }

    // MARK: - Away

    /// Idle for longer than the setting, or marked away on the network.
    func isAway(on session: NetworkSession) -> Bool {
        session.isAway || isIdle
    }

    var isIdle: Bool {
        let minutes = settings.object(forKey: AttentionSettings.idleMinutes) as? Int ?? AttentionSettings.defaultIdleMinutes
        return minutes > 0 && idleSeconds() >= TimeInterval(minutes * 60)
    }

    /// Seconds since the last keyboard or mouse input, on the whole Mac.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Whether the user is marked away on any connected network: by the
    /// toolbar, /away, or going idle.
    var isAwaySomewhere: Bool {
        awayByUser != nil || sessions.contains { $0.isConnected && $0.isAway }
    }

    /// The default away message, or the one set in Settings.
    var awayMessage: String {
        settings.string(forKey: AttentionSettings.awayMessage)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? AttentionSettings.defaultAwayMessage
    }

    /// Away on every connected network, and on those that connect later,
    /// until `comeBackEverywhere`. Coming back from idle leaves it alone.
    func goAwayEverywhere(_ message: String? = nil) {
        let text = message.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? awayMessage
        awayByUser = text
        autoAwaySessions = []
        awayAsked = [:]
        AppLog.info("away", "away on every network")
        keepAwayByUser()
    }

    /// Back on every network: what the toolbar, /away and idling set.
    func comeBackEverywhere() {
        awayByUser = nil
        autoAwaySessions = []
        awayAsked = [:]
        AppLog.info("away", "back on every network")
        for session in sessions where session.isConnected && session.isAway {
            session.setAway(nil)
        }
    }

    /// The user's away, on the networks that lost it: after a reconnect the
    /// server has forgotten it.
    func keepAwayByUser(now: Date = .now) {
        guard let message = awayByUser else { return }
        for session in sessions where session.isConnected && !session.isAway {
            if let asked = awayAsked[session.id], now.timeIntervalSince(asked) < 30 { continue }
            awayAsked[session.id] = now
            session.setAway(message)
        }
    }

    func startAwayWatch() {
        guard awayTask == nil else { return }
        awayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.checkAway()
            }
        }
    }

    /// When the user is back, after being idle or /away: one notification
    /// summing up what came meanwhile, opening the Mentions window.
    func checkAway() {
        keepAwayByUser()
        let idle = isIdle
        if idle != wasIdle {
            wasIdle = idle
            if idle { wentIdle() } else { cameBack() }
        }
        let away = idle || sessions.contains { $0.isAway }
        defer { wasAway = away }
        guard wasAway, !away, !awayDigest.isEmpty else { return }
        let mentions = awayDigest.filter { !$0.isPrivateMessage }.count
        let privates = awayDigest.count - mentions
        var parts: [String] = []
        if mentions > 0 { parts.append(mentions == 1 ? "1 mention" : "\(mentions) mentions") }
        if privates > 0 { parts.append(privates == 1 ? "1 private message" : "\(privates) private messages") }
        notifier?.post(title: "While you were away", subtitle: "", body: parts.joined(separator: " and "),
                       sound: false, threadID: "away", userInfo: ["digest": "1"])
    }

    /// The Mac went idle: away on the networks, and quiet, as set. What the
    /// user had set already is left as it is, and not undone on return.
    private func wentIdle() {
        if settings.bool(forKey: AttentionSettings.setAwayWhenIdle, default: true), awayByUser == nil {
            let message = awayMessage
            for session in sessions where session.isConnected && !session.isAway {
                session.setAway(message)
                autoAwaySessions.insert(session.id)
            }
        }
        if settings.bool(forKey: AttentionSettings.muteWhenIdle, default: true), !isMuted() {
            setMuted(true)
            autoMuted = true
        }
    }

    /// Back at the Mac: undoes what going idle did.
    private func cameBack() {
        for session in sessions where autoAwaySessions.contains(session.id) && session.isConnected {
            session.setAway(nil)
        }
        autoAwaySessions = []
        if autoMuted {
            autoMuted = false
            if isMuted() { setMuted(false) }
        }
    }
}
