import SwiftUI

/// Every saved network: open one or several as tabs, add, edit, remove.
struct NetworkListView: View {
    static let windowID = "networks"

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var selection = Set<NetworkConfig.ID>()
    @State private var search = ""
    @State private var editing: NetworkEditorRequest?
    @State private var confirmingRemoval = false

    private var rows: [NetworkConfig] {
        let all = app.sortedNetworks
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(term) || $0.host.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("") { network in
                    Button {
                        app.toggleFavorite(network.id)
                    } label: {
                        Image(systemName: network.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(network.isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.borderless)
                    .help(network.isFavorite ? "Remove from favourites" : "Add to favourites")
                }
                .width(22)

                TableColumn("Network") { network in
                    HStack(spacing: 6) {
                        Text(network.name)
                        if let session = app.session(for: network.id) {
                            StatusDot(state: session.state)
                                .help("Open in a tab")
                        }
                    }
                }
                .width(min: 120, ideal: 170)

                TableColumn("Server") { network in
                    HStack(spacing: 4) {
                        Image(systemName: network.useTLS ? "lock.fill" : "lock.open")
                            .foregroundStyle(network.useTLS ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            .help(network.useTLS ? "TLS" : "Not encrypted")
                        Text(verbatim: "\(network.host):\(network.port)")
                            .foregroundStyle(.secondary)
                    }
                }

                TableColumn("Nick") { network in
                    Text(network.nick.isEmpty ? "—" : network.nick)
                        .foregroundStyle(network.nick.isEmpty ? .tertiary : .primary)
                }
                .width(min: 60, ideal: 90)
            }
            .contextMenu(forSelectionType: NetworkConfig.ID.self) { ids in
                if !ids.isEmpty {
                    Button("Connect") { connect(ids) }
                    if ids.count == 1, let id = ids.first, let network = app.network(id) {
                        Button("Edit…") { editing = NetworkEditorRequest(config: network, isNew: false) }
                        Button(network.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
                            app.toggleFavorite(id)
                        }
                    }
                    Divider()
                    Button("Remove…", role: .destructive) {
                        selection = ids
                        confirmingRemoval = true
                    }
                }
            } primaryAction: { ids in
                connect(ids)
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    editing = .newNetwork()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a network")
                Button {
                    confirmingRemoval = true
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                .help("Remove the selected networks")
                Button("Edit…") {
                    if let id = selection.first, let network = app.network(id) {
                        editing = NetworkEditorRequest(config: network, isNew: false)
                    }
                }
                .disabled(selection.count != 1)
                Menu("More") {
                    Button("Add Missing Well-Known Networks") { app.addKnownNetworks() }
                }
                .fixedSize()

                Spacer()
                Text("\(app.networks.count) networks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Connect") { connect(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
            }
            .padding(10)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name or server")
        .frame(minWidth: 560, minHeight: 360)
        .sheet(item: $editing) { request in
            NetworkEditor(request: request) { config in
                app.save(config)
                selection = [config.id]
            }
        }
        .confirmationDialog(removalTitle, isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) {
                app.remove(selection)
                selection = []
            }
        } message: {
            Text("Open tabs of these networks close, and their saved passwords are deleted.")
        }
    }

    private var removalTitle: String {
        selection.count == 1
            ? "Remove \(selection.first.flatMap { app.network($0)?.name } ?? "the network")?"
            : "Remove \(selection.count) networks?"
    }

    private func connect(_ ids: Set<NetworkConfig.ID>) {
        // In list order, so the tabs come out the way they are listed.
        let ordered = app.sortedNetworks.map(\.id).filter(ids.contains)
        for id in ordered { app.open(id, select: id == ordered.first) }
        guard !ordered.isEmpty else { return }
        openWindow(id: IrctellApp.mainWindowID)
        dismissWindow(id: NetworkListView.windowID)
    }
}
