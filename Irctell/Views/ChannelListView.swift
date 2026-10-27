import SwiftUI

/// The channel list in a window of its own, which stays open while channels
/// are joined: the network it was opened for, or another open one.
struct ChannelListWindow: View {
    static let windowID = "channelList"

    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let session = app.sessions.first(where: { $0.id == app.channelListNetwork }) ?? app.selectedSession {
                ChannelListView(session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView("No Network Open", systemImage: "network.slash",
                                       description: Text("Open a network to see its channels."))
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .navigationTitle("Channel List")
        .toolbar {
            if app.sessions.count > 1 {
                ToolbarItem {
                    Picker("Network", selection: Binding(
                        get: { app.channelListNetwork ?? app.selectedSessionID },
                        set: { app.channelListNetwork = $0 })) {
                        ForEach(app.sessions) { session in
                            Text(session.displayName).tag(NetworkSession.ID?.some(session.id))
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }
}

/// The server's channels, fetched with LIST: searchable and sortable.
/// Channels are ticked -- through any number of searches -- and joined
/// together.
struct ChannelListView: View {
    @Bindable var session: NetworkSession

    @State private var search = ""
    @State private var minimumUsers = 0
    @State private var selection = Set<ListedChannel.ID>()
    @State private var sortOrder = [KeyPathComparator(\ListedChannel.users, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search names and topics", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Users", selection: $minimumUsers) {
                    Text("Any size").tag(0)
                    Text("10+ users").tag(10)
                    Text("50+ users").tag(50)
                    Text("200+ users").tag(200)
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    session.requestChannelList()
                } label: {
                    Label(session.channelListDate == nil ? "Fetch" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!session.isConnected || session.isListingChannels)
            }
            .padding(10)

            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { channel in
                    let joined = session.isJoined(channel.name)
                    Toggle("", isOn: Binding(
                        get: { joined || session.pickedChannels.contains(channel.name) },
                        set: { pick([channel.name], $0) }))
                        .labelsHidden()
                        .disabled(joined)
                        .help(joined ? "Already joined" : "Tick to join, with the other ticked channels")
                }
                .width(20)
                TableColumn("Channel", value: \.name) { channel in
                    Text(channel.name)
                }
                .width(min: 100, ideal: 180)
                TableColumn("Users", value: \.users) { channel in
                    Text("\(channel.users)").monospacedDigit()
                }
                .width(min: 50, ideal: 60, max: 80)
                TableColumn("Topic", value: \.topic) { channel in
                    Text(channel.topic)
                        .lineLimit(1)
                        .help(channel.topic)
                }
            }
            .contextMenu(forSelectionType: ListedChannel.ID.self) { names in
                if !names.isEmpty {
                    Button("Tick") { pick(names, true) }
                    Button("Untick") { pick(names, false) }
                    Divider()
                    Button(names.count > 1 ? "Join \(names.count) Channels Now" : "Join Now") { join(names) }
                }
            } primaryAction: { names in
                // Double-click ticks, or unticks, rather than joining at once.
                pick(names, !names.allSatisfy { session.pickedChannels.contains($0) })
            }
            .onKeyPress(.space) {
                guard !selection.isEmpty else { return .ignored }
                pick(selection, !selection.allSatisfy { session.pickedChannels.contains($0) })
                return .handled
            }
            .overlay {
                if session.channelList.isEmpty && !session.isListingChannels {
                    ContentUnavailableView {
                        Label("No Channel List", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text(session.isConnected
                             ? "Fetch the list of channels from the server. On large networks this takes a while."
                             : "Connect to the network to fetch its channels.")
                    }
                }
            }

            Divider()
            HStack {
                status
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if !session.pickedChannels.isEmpty {
                    Button("Untick All") { session.pickedChannels = [] }
                }
                Button(joinTitle) { join(toJoin) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(toJoin.isEmpty || !session.isConnected)
                    .help(session.pickedChannels.isEmpty ? "Join the selected channels"
                          : session.pickedChannels.sorted().joined(separator: " "))
            }
            .padding(10)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 560)
        .onAppear {
            session.loadSavedChannelList()
            if session.channelListDate == nil { session.requestChannelList() }
        }
    }

    private var shown: [ListedChannel] {
        session.channelList
            .filter { channel in
                channel.users >= minimumUsers
                    && (search.isEmpty
                        || channel.name.localizedCaseInsensitiveContains(search)
                        || channel.topic.localizedCaseInsensitiveContains(search))
            }
            .sorted(using: sortOrder)
    }

    @ViewBuilder private var status: some View {
        if session.isListingChannels {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Receiving… \(session.listingCount) channels")
            }
        } else if let date = session.channelListDate {
            let count = shown.count
            let picked = session.pickedChannels.isEmpty ? "" : " · \(session.pickedChannels.count) ticked"
            Text((count == session.channelList.count
                 ? "\(count) channels, fetched \(date.formatted(date: .omitted, time: .shortened))"
                 : "\(count) of \(session.channelList.count) channels, fetched \(date.formatted(date: .omitted, time: .shortened))") + picked)
        }
    }

    /// The ticked channels, or without any, the selected ones.
    private var toJoin: Set<String> {
        let names = session.pickedChannels.isEmpty ? selection : session.pickedChannels
        return names.filter { !session.isJoined($0) }
    }

    private var joinTitle: String {
        toJoin.count > 1 ? "Join \(toJoin.count) Channels" : "Join"
    }

    private func pick(_ names: Set<String>, _ on: Bool) {
        for name in names where !session.isJoined(name) {
            if on { session.pickedChannels.insert(name) } else { session.pickedChannels.remove(name) }
        }
    }

    private func join(_ names: Set<ListedChannel.ID>) {
        let names = names.filter { !session.isJoined($0) }
        guard !names.isEmpty, session.isConnected else { return }
        session.join(names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        session.pickedChannels.subtract(names)
    }
}
