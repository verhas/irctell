import SwiftUI

/// The window: a tab per network along the top, the selected network below.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            NetworkTabBar()
            Divider()
            if let session = app.selectedSession {
                NetworkView(session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView {
                    Label("No Open Networks", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Pick a network from the list to connect to it.")
                } actions: {
                    Button("Open Network…") { openWindow(id: NetworkListView.windowID) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .sheet(item: $app.editing) { request in
            NetworkEditor(request: request) { app.save($0) }
        }
        .environment(\.ignoreRules, app.ignoreRules)
        .onAppear { app.openWindow = { openWindow(id: $0) } }
        .onChange(of: app.dockBadge, initial: true) {
            NSApplication.shared.dockTile.badgeLabel = app.dockBadge
        }
    }
}

struct NetworkTabBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    /// The tab being dragged, and the gap it would go to: 0 before the first
    /// tab, the number of tabs after the last.
    @State private var dragged: NetworkSession.ID?
    @State private var gap: Int?
    @State private var widths: [NetworkSession.ID: CGFloat] = [:]

    /// The gap shown: none where the tab would not move.
    private var shownGap: Int? {
        guard let gap, let dragged, let from = app.sessions.firstIndex(where: { $0.id == dragged }) else { return nil }
        return gap == from || gap == from + 1 ? nil : gap
    }

    private func move(_ id: NetworkSession.ID, _ gap: Int) {
        app.moveSession(id, toGap: gap)
    }

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(app.sessions.enumerated()), id: \.element.id) { index, session in
                        NetworkTab(session: session, isSelected: session.id == app.selectedSessionID)
                            .overlay(alignment: .leading) { if shownGap == index { GapMarker().offset(x: -4) } }
                            .overlay(alignment: .trailing) {
                                if shownGap == app.sessions.count, index == app.sessions.count - 1 {
                                    GapMarker().offset(x: 4)
                                }
                            }
                            .background(GeometryReader { geometry in
                                Color.clear
                                    .onAppear { widths[session.id] = geometry.size.width }
                                    .onChange(of: geometry.size.width) { widths[session.id] = $1 }
                            })
                            .onDrag {
                                dragged = session.id
                                return NSItemProvider(object: session.id.uuidString as NSString)
                            } preview: {
                                Text(session.displayName)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.selection.opacity(0.35), in: .rect(cornerRadius: 6))
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(
                                index: index, width: widths[session.id], dragged: $dragged, gap: $gap, move: move))
                    }
                    // Past the last tab: dropped there, it goes last.
                    // A fixed height: a colour takes all the height it is
                    // offered, and the tab bar would grow with it.
                    Color.clear
                        .frame(width: 60, height: 22)
                        .contentShape(.rect)
                        .onDrop(of: [.text], delegate: TabDropDelegate(
                            index: app.sessions.count, width: nil, dragged: $dragged, gap: $gap, move: move))
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
            Button {
                openWindow(id: NetworkListView.windowID)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Open a network (⇧⌘N)")
            .padding(.trailing, 10)
        }
        .padding(.vertical, 5)
        .background(.bar)
    }
}

/// Where a dragged tab would go: a bar in the gap between two tabs.
private struct GapMarker: View {
    var body: some View {
        Capsule()
            .fill(.tint)
            .frame(width: 3, height: 22)
            .allowsHitTesting(false)
    }
}

/// A tab dragged over a tab: before it over its left half, after it over
/// the right one. Over the empty space past the tabs: last.
private struct TabDropDelegate: DropDelegate {
    let index: Int
    /// The tab's width; nil for the space past the tabs.
    let width: CGFloat?
    @Binding var dragged: NetworkSession.ID?
    @Binding var gap: Int?
    let move: (NetworkSession.ID, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragged != nil }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if gap == target(info) { gap = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragged = nil
            gap = nil
        }
        guard let id = dragged else { return false }
        move(id, target(info))
        return true
    }

    private func update(_ info: DropInfo) {
        gap = target(info)
    }

    private func target(_ info: DropInfo) -> Int {
        guard let width else { return index }
        return info.location.x < width / 2 ? index : index + 1
    }
}

private struct NetworkTab: View {
    @Environment(AppModel.self) private var app
    let session: NetworkSession
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            // The close button takes the status dot's place on hover.
            ZStack {
                StatusDot(state: session.state)
                    .opacity(isHovering ? 0 : 1)
                if isHovering {
                    Button {
                        app.closeTab(session)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Close tab and disconnect")
                }
            }
            .frame(width: 10, height: 10)
            Text(session.displayName)
                .fontWeight(isSelected ? .semibold : .regular)
            if !isSelected, session.unreadCount > 0 {
                UnreadBadge(count: session.unreadCount, highlight: session.hasHighlight)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture { app.selectedSessionID = session.id }

        .contextMenu {
            if session.isOffline {
                Button("Connect") { session.connect() }
            } else {
                Button("Disconnect") { session.disconnect() }
            }
            Toggle("Connect at Launch", isOn: Binding(
                get: { app.network(session.id)?.connectAtLaunch ?? true },
                set: { _ in app.toggleConnectAtLaunch(session.id) }))
            Button("Edit…") { app.beginEditing(session) }
            Divider()
            Button("Close Tab") { app.closeTab(session) }
        }
        .help(statusText)
    }

    private var statusText: String {
        switch session.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .registering: "Logging in…"
        case .registered: "Connected as \(session.nick)"
        case .waitingToReconnect(let attempt, _): "Reconnecting (attempt \(attempt))…"
        }
    }
}

struct StatusDot: View {
    let state: IRCConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .registered: .green
        case .connecting, .registering: .yellow
        case .waitingToReconnect: .orange
        case .disconnected: .secondary.opacity(0.5)
        }
    }
}

struct UnreadBadge: View {
    let count: Int
    let highlight: Bool

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(highlight ? .white : .primary)
            .background(highlight ? AnyShapeStyle(.red) : AnyShapeStyle(.quaternary), in: .capsule)
    }
}
