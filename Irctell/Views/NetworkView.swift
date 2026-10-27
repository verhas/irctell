import SwiftUI

/// One network: its conversations on the left, the selected one in the
/// middle, and the channel's members on the right.
struct NetworkView: View {
    @Bindable var session: NetworkSession
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    private var showsMembers: Binding<Bool> { SettingsStore.shared.binding("showsMemberList", default: true) }

    var body: some View {
        HSplitView {
            BufferSidebar(session: session)
                .frame(minWidth: 150, idealWidth: 200, maxWidth: 320)

            Group {
                if let buffer = session.selectedBuffer, session.isMemos(buffer) {
                    MemoView(session: session)
                } else if let buffer = session.selectedBuffer {
                    ConversationView(session: session, buffer: buffer)
                        .id(buffer.id)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

            if showsMembers.wrappedValue, let buffer = session.selectedBuffer, buffer.kind != .server,
               !session.isMemos(buffer) {
                MemberList(session: session, buffer: buffer)
                    .frame(minWidth: 120, idealWidth: 170, maxWidth: 280)
            }
        }
        .navigationTitle(session.selectedBuffer.map { session.isMemos($0) ? "Memos" : $0.name } ?? session.displayName)
        .navigationSubtitle(session.isConnected ? "\(session.displayName) — \(session.nick)" : session.displayName)
        // Asked for by the menu, the toolbar or /list: a window of its own.
        .onChange(of: session.showsChannelList, initial: true) {
            guard session.showsChannelList else { return }
            session.showsChannelList = false
            app.channelListNetwork = session.id
            openWindow(id: ChannelListWindow.windowID)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                UnseenPrivateButton()
            }
            ToolbarItem {
                AwayButton()
            }
            ToolbarItem {
                SkipButton()
            }
            ToolbarItem {
                MuteButton()
            }
            ToolbarItem {
                Button {
                    openWindow(id: MentionsView.windowID)
                } label: {
                    Label("Mentions", systemImage: "bell")
                }
                .help("Mentions on every network (⇧⌘M)")
            }
            ToolbarItem {
                Button {
                    session.showsChannelList = true
                } label: {
                    Label("Channel List", systemImage: "list.bullet.rectangle")
                }
                .help("Browse the server's channels (⌘L)")
            }
            ToolbarItem {
                Toggle(isOn: showsMembers) {
                    Label("Members", systemImage: "person.2")
                }
                .help("Show or hide the member list")
            }
        }
    }
}

struct BufferSidebar: View {
    @Bindable var session: NetworkSession

    var body: some View {
        List(selection: $session.selectedBufferID) {
            BufferRow(buffer: session.serverBuffer, session: session, icon: "server.rack")
                .tag(session.serverBuffer.id)
            BufferRow(buffer: session.memoBuffer, session: session, icon: "envelope")
                .tag(session.memoBuffer.id)

            let channels = session.channels
            if !channels.isEmpty {
                Section("Channels") {
                    ForEach(channels) { buffer in
                        BufferRow(buffer: buffer, session: session, icon: "number")
                            .tag(buffer.id)
                    }
                    .onMove { session.moveBuffers(of: .channel, from: $0, to: $1) }
                }
            }
            let queries = session.queries
            if !queries.isEmpty {
                Section("Private") {
                    ForEach(queries) { buffer in
                        BufferRow(buffer: buffer, session: session, icon: "person")
                            .tag(buffer.id)
                    }
                    .onMove { session.moveBuffers(of: .query, from: $0, to: $1) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NickOpener(session: session)
        }
    }
}

private struct BufferRow: View {
    @Environment(AppModel.self) private var app
    let buffer: ChatBuffer
    let session: NetworkSession
    let icon: String

    var body: some View {
        HStack {
            Label {
                Text(buffer.kind == .server ? session.displayName : isMemos ? "Memos" : buffer.name)
                    .lineLimit(1)
                    .fontWeight(buffer.unreadCount > 0 ? .semibold : .regular)
            } icon: {
                Image(systemName: icon)
            }
            .foregroundStyle(isInactive ? .tertiary : .primary)
            .italic(isInactive)
            Spacer(minLength: 4)
            if buffer.kind == .query, !isMemos, session.isConnected, buffer.partnerOnline == false {
                Text("offline")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if buffer.suggestion != nil, buffer.draft.isEmpty, session.selectedBufferID != buffer.id {
                Image(systemName: "apple.intelligence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("A suggested reply is waiting: Tab in the empty input field takes it")
            }
            if level == .none {
                Image(systemName: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Muted: no notifications")
            }
            if isMemos {
                // Memos not read, not lines from MemoServ.
                if session.memos.unreadCount > 0 {
                    UnreadBadge(count: session.memos.unreadCount, highlight: true)
                }
            } else if buffer.unreadCount > 0 {
                UnreadBadge(count: buffer.unreadCount, highlight: buffer.hasHighlight)
            }
            // Last, in a column of its own: the loudspeakers line up
            // however wide the badge before them is.
            if buffer.speaks {
                SpeakerMark(buffer: buffer)
                    .frame(width: 16)
            }
            if buffer.kind == .query, !isMemos {
                CloseMark { session.close(buffer) }
            }
        }
        // Double-click a channel left, or not joined yet, to go (back) in.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if buffer.kind == .channel, !buffer.isJoined, session.isConnected {
                session.join([buffer.name])
            }
        })
        .contextMenu {
            Picker("Notify", selection: Binding(
                get: { level },
                set: { app.setNotificationLevel($0, network: session.id, buffer: buffer.name, kind: buffer.kind) })) {
                ForEach(NotificationLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            Picker("Pictures", selection: Binding(
                get: { app.ownMediaMode(network: session.id, buffer: buffer.name, kind: buffer.kind) },
                set: { app.setMediaMode($0, network: session.id, buffer: buffer.name, kind: buffer.kind) })) {
                Text("As in Settings (\(app.defaultMediaMode.title))").tag(MediaMode?.none)
                ForEach(MediaMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(MediaMode?.some(mode))
                }
            }
            Divider()
            switch buffer.kind {
            case .server:
                Button("Channel List…") { session.showsChannelList = true }
            case .channel:
                if buffer.isJoined {
                    Button("Leave") { session.submit("/part \(buffer.name)", in: buffer) }
                } else {
                    Button("Join") { session.submit("/join \(buffer.name)", in: buffer) }
                }
                Toggle("Rejoin at Login", isOn: Binding(
                    get: { app.autoJoins(buffer.name, on: session.id) },
                    set: { _ in app.toggleAutoJoin(buffer.name, on: session.id) }))
                Divider()
                Button("Close") { session.close(buffer) }
                Button("Clear") { session.clear(buffer) }
            case .query:
                if isMemos {
                    Button("Check Memos") { session.memos.check() }
                        .disabled(!session.isConnected)
                } else {
                    Button("Close") { session.close(buffer) }
                }
                Button("Clear") { session.clear(buffer) }
            }
        }
    }

    private var isMemos: Bool { session.isMemos(buffer) }

    private var level: NotificationLevel {
        app.notificationLevel(network: session.id, buffer: buffer.name, kind: buffer.kind)
    }

    /// A channel we are not in, or a server we are not connected to.
    private var isInactive: Bool {
        switch buffer.kind {
        case .channel: !buffer.isJoined
        case .server: !session.isConnected
        case .query: !session.isConnected || (!isMemos && buffer.partnerOnline == false)
        }
    }
}

/// Red while private chats have messages not seen: how many, and a click
/// opens the one waiting longest, on whichever network.
struct UnseenPrivateButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let unseen = app.unseenPrivateChats
        Button {
            app.showOldestUnseenPrivateChat()
        } label: {
            if unseen.isEmpty {
                Label("Private Messages", systemImage: "bubble.left.and.bubble.right")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("\(unseen.count)")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.red, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .disabled(unseen.isEmpty)
        .help(help(unseen))
    }

    private func help(_ unseen: [(session: NetworkSession, buffer: ChatBuffer)]) -> String {
        guard let first = unseen.first else { return "No private messages waiting" }
        let names = unseen.prefix(5).map { $0.buffer.name }.joined(separator: ", ")
        let more = unseen.count > 5 ? " and \(unseen.count - 5) more" : ""
        return "Private messages not seen: \(names)\(more). Click (⌥Tab or ⌥⌘U) for \(first.buffer.name)"
            + "\(app.sessions.count > 1 ? " on \(first.session.displayName)" : ""), waiting longest."
    }
}

/// The user's nick actions offered in the conversation, for a nick.
struct NickActionsMenu: View {
    let session: NetworkSession
    let buffer: ChatBuffer
    let nick: String
    let edit: () -> Void

    var body: some View {
        let actions = NickActions.shared.offered(in: buffer.name, isChannel: buffer.kind == .channel)
        let scripts = ScriptHost.shared.nickActionScripts(in: buffer)
        Menu("Actions") {
            ForEach(actions) { action in
                Button(action.name) { session.run(action, nick: nick, in: buffer) }
            }
            ForEach(scripts) { script in
                Button(script.name) { ScriptHost.shared.runNickAction(script, nick: nick, session: session, buffer: buffer) }
            }
            if !actions.isEmpty || !scripts.isEmpty { Divider() }
            Button("Edit Actions…", action: edit)
        }
    }
}

/// Away on every connected network, or back: a click with the message from
/// Settings, or a message of the moment from the menu.
struct AwayButton: View {
    @Environment(AppModel.self) private var app
    @State private var asksMessage = false
    @State private var message = ""

    var body: some View {
        let away = app.isAwaySomewhere
        Menu {
            if away {
                Button("Back on Every Network") { app.comeBackEverywhere() }
            } else {
                Button("Away: “\(app.awayMessage)”") { app.goAwayEverywhere() }
                Button("Away with Message…") {
                    message = ""
                    asksMessage = true
                }
            }
        } label: {
            Label(away ? "Back" : "Away", systemImage: away ? "moon.zzz.fill" : "moon.zzz")
        } primaryAction: {
            if away { app.comeBackEverywhere() } else { app.goAwayEverywhere() }
        }
        .foregroundStyle(away ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .help(away ? "You are away\(app.awayByUser.map { ": “\($0)”" } ?? ""). Click to be back on every network (⌥⌘A)"
                   : "Set yourself away on every connected network (⌥⌘A); the arrow for a message of your own")
        .popover(isPresented: $asksMessage, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Away on every network with")
                    .font(.headline)
                TextField("Message", text: $message, prompt: Text(app.awayMessage))
                    .frame(width: 280)
                    .onSubmit(goAway)
                HStack {
                    Spacer()
                    Button("Cancel") { asksMessage = false }
                    Button("Away", action: goAway)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func goAway() {
        app.goAwayEverywhere(message)
        asksMessage = false
    }
}

/// Silences all of Irctell: reading aloud, and the sounds of notifications.
struct MuteButton: View {
    @Bindable private var speaker = Speaker.shared

    var body: some View {
        Toggle(isOn: $speaker.isMuted) {
            Label(speaker.isMuted ? "Unmute" : "Mute",
                  systemImage: speaker.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
        }
        .help(speaker.isMuted ? "Muted: nothing is read aloud, notifications are silent (⌃⌘M)"
                              : "Mute everything: reading aloud and notification sounds (⌃⌘M)")
    }
}

/// Stops the message being read aloud, and goes on with the next one.
struct SkipButton: View {
    private var speaker: Speaker { .shared }

    var body: some View {
        Button {
            speaker.skip()
        } label: {
            Label("Skip", systemImage: "forward.end")
        }
        .disabled(!speaker.isSpeaking)
        .help("Skip the message being read aloud (⌃⌘→)")
    }
}

/// In the sidebar: the conversation's loudspeaker is on. It pulses while one
/// of its messages is read.
/// Closes a private chat from its row, without the menu.
private struct CloseMark: View {
    let close: () -> Void
    @State private var isHovered = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Button(action: close) {
            Image(systemName: isHovered ? "xmark.circle.fill" : "xmark.circle")
                .font(.caption)
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.white)
                                 : isHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { isHovered = $0 }
        .help("Close this private chat")
    }
}

private struct SpeakerMark: View {
    let buffer: ChatBuffer
    private var speaker: Speaker { .shared }
    /// Increased on the selected row: the accent colour would vanish into
    /// the selection's own.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let speaking = speaker.speakingBuffer == buffer.id
        Image(systemName: speaker.isMuted ? "speaker.slash" : speaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
            .font(.caption)
            .foregroundStyle(style(speaking: speaking))
            .symbolEffect(.pulse, options: .repeating, isActive: speaking)
            .help(speaker.isMuted ? "Read aloud when Irctell is unmuted"
                  : speaking ? "Reading a message aloud: Skip in the toolbar goes to the next" : "Messages are read aloud")
    }

    private func style(speaking: Bool) -> AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(.white) }
        return speaking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }
}

struct MemberList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    let session: NetworkSession
    @Bindable var buffer: ChatBuffer
    /// Moves on every half minute, so the activity marks age.
    @State private var now = Date.now
    @State private var voiceChoice: VoiceChoice?
    @State private var aliasChoice: AliasChoice?

    var body: some View {
        VStack(spacing: 0) {
            members
            if buffer.selectedMembers.count == 1, let nick = buffer.selectedMembers.first {
                Divider()
                WhoisPanel(session: session, nick: nick)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = .now
            }
        }
        .sheet(item: $voiceChoice) { VoicePicker(nick: $0.nick) }
        .sheet(item: $aliasChoice) { AliasPicker(nick: $0.nick, log: session.log) }
    }

    private var members: some View {
        let all = session.sortedMembers(of: buffer)
        let filter = buffer.memberFilter
        let members = filter.isEmpty ? all : all.filter { $0.nick.localizedCaseInsensitiveContains(filter) }
        return List(selection: $buffer.selectedMembers) {
            ForEach(members, id: \.nick) { member in
                let info = session.userInfo(for: member.nick)
                HStack(spacing: 1) {
                    Text(member.prefixes.first.map(String.init) ?? "")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 10, alignment: .trailing)
                    // Marks the members a WHOIS is known for: hover for it.
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tint)
                        .opacity(info == nil ? 0 : 0.8)
                        .frame(width: 11)
                    // How recently they did something, when that is known.
                    let activity = session.lastActive(member.nick).map { Activity(since: $0, now: max(now, $0)) }
                    Text(activity?.emoji ?? "")
                        .font(.system(size: 7))
                        .frame(width: 11)
                        .help(activity?.title ?? "")
                    Text(member.nick)
                        .font(.callout)
                        .foregroundStyle(IRCFormatting.color(forNick: member.nick))
                        .opacity(member.isAway ? 0.5 : 1)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
                .help(info?.summary ?? "\(member.nick)\nNo WHOIS yet: right-click for Whois.")
                .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 4))
                .listRowSeparator(.hidden)
                .tag(member.nick)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 16)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 4) {
                SearchField(prompt: "Filter", text: $buffer.memberFilter)
                HStack {
                    Text(filter.isEmpty ? "\(all.count) members" : "\(members.count) of \(all.count) members")
                    Spacer()
                    if !session.whoisQueue.isEmpty {
                        Text("WHOIS: \(session.whoisQueue.count) to go")
                            .help("WHOIS requests are sent one at a time, so the server does not see a flood.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(.bar)
        }
        .contextMenu(forSelectionType: String.self) { nicks in
            if nicks.count == 1, let nick = nicks.first {
                // In a private chat both people are already in it.
                if buffer.kind == .channel, !session.isMe(nick) {
                    Button("Private Chat") { openQuery(nick) }
                }
                Button("Whois") { session.submit("/whois \(nick)", in: buffer) }
                NickActionsMenu(session: session, buffer: buffer, nick: nick) {
                    openWindow(id: NickActionEditor.windowID)
                }
                Button("Voice…") { voiceChoice = VoiceChoice(nick: nick) }
                if !session.isMe(nick) {
                    Button("Same Person…") { aliasChoice = AliasChoice(nick: nick) }
                }
                if !session.isMe(nick) {
                    Divider()
                    Picker("Ignore on \(session.displayName)", selection: Binding(
                        get: { app.network(session.id)?.ignores.first { $0.id == nick.lowercased() }?.scope },
                        set: { app.setIgnore(nick, scope: $0, network: session.id) })) {
                        Text("Not Ignored").tag(IgnoreEntry.Scope?.none)
                        ForEach(IgnoreEntry.Scope.allCases, id: \.self) { scope in
                            Text(scope.title).tag(IgnoreEntry.Scope?.some(scope))
                        }
                    }
                }
            } else if nicks.count > 1 {
                Button("Whois \(nicks.count) Users") {
                    session.queueWhois(nicks.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
                }
            }
        } primaryAction: { nicks in
            if buffer.kind == .channel, nicks.count == 1, let nick = nicks.first { openQuery(nick) }
        }
    }

    private func openQuery(_ nick: String) {
        guard !session.isMe(nick) else { return }
        session.openBuffer(named: nick, kind: .query, select: true)
    }
}

/// The selected member's WHOIS, under the member list: collapsible, with a
/// button to ask again, and their channels to join with a click.
private struct WhoisPanel: View {
    let session: NetworkSession
    let nick: String
    private var expanded: Binding<Bool> { SettingsStore.shared.binding("whoisPanelExpanded", default: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy) { expanded.wrappedValue.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                        .frame(width: 10)
                    Text(nick)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if session.isWhoisPending(nick) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        session.queueWhois([nick], includingMe: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!session.isConnected)
                    .help(session.userInfo(for: nick) == nil ? "Look up with WHOIS" : "Ask WHOIS again")
                }
            }
            .font(.caption)
            if expanded.wrappedValue {
                ScrollView {
                    details
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder private var details: some View {
        if let info = session.userInfo(for: nick) {
            VStack(alignment: .leading, spacing: 3) {
                if let activity = session.lastActive(nick).map({ Activity(since: $0) }) {
                    Text("\(activity.emoji) \(activity.title)")
                }
                if let username = info.username, let host = info.host {
                    Text("\(username)@\(host)").foregroundStyle(.secondary).textSelection(.enabled)
                }
                field("Name", info.realName)
                field("Account", info.account)
                field("From", info.actualHost)
                field("Server", info.server)
                field("Away", info.awayMessage)
                if info.isOperator { Text("IRC operator") }
                if info.isBot { Text("Bot") }
                if info.isSecure { Text("Secure connection").foregroundStyle(.secondary) }
                if !info.channels.isEmpty {
                    Text("Channels").foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) {
                        ForEach(info.channels, id: \.self) { entry in
                            channelButton(entry)
                        }
                    }
                }
                Text("WHOIS from \(info.updated.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        } else {
            Text(session.isConnected ? "No WHOIS yet: ↻ looks it up." : "No WHOIS yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            Text("\(Text(label + ": ").foregroundStyle(.secondary))\(value)")
                .textSelection(.enabled)
        }
    }

    /// `@#alpha` from a WHOIS: the prefix says they are an op there.
    private func channelButton(_ entry: String) -> some View {
        let (_, channel) = session.isupport.splitMembership(entry)
        let joined = session.isJoined(channel)
        return Button(entry) {
            if joined, let buffer = session.buffer(named: channel) {
                session.selectedBufferID = buffer.id
            } else {
                session.join([channel])
            }
        }
        .buttonStyle(.link)
        .help(joined ? "Go to \(channel)" : "Join \(channel)")
    }
}

/// Lays its children out left to right, wrapping onto further rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
