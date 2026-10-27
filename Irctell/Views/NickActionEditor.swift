import SwiftUI

/// The user's commands for a nick's right-click menu: added, changed,
/// switched off and deleted here.
struct NickActionEditor: View {
    static let windowID = "nickActions"

    @State private var actions: [NickAction] = []
    @State private var trialNick = "bob"
    @State private var trialChannel = "#channel"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Right-click a nick in the member list or in a conversation: these are under Actions. An action with channels is offered only in the channels matching one of them — * for anything, ? for one character, several separated by commas; without channels, everywhere. The command is run as if typed: “/msg Bot !info {nick}” asks a bot about the nick. {nick} is the nick, {channel} the conversation, {me} your nick, {network} the network. Several lines run one after the other.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    actions.append(NickAction(name: "", command: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Spacer()
                Text("Try with")
                    .foregroundStyle(.secondary)
                TextField("Nick", text: $trialNick)
                    .frame(width: 90)
                TextField("Channel", text: $trialChannel)
                    .frame(width: 160)
            }
            .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($actions) { $action in
                        ActionRow(action: $action, trialNick: trialNick, trialChannel: trialChannel) {
                            actions.removeAll { $0.id == action.id }
                        }
                    }
                }
            }
            .overlay {
                if actions.isEmpty {
                    ContentUnavailableView("No Actions", systemImage: "person.crop.circle.badge.questionmark",
                                           description: Text("Add one to have it in nicks' menus. For example: name “Info from Bot”, channels “#delta*”, command “/msg Bot !info {nick}”."))
                }
            }
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .onAppear { actions = NickActions.shared.list }
        .onChange(of: actions) { NickActions.shared.list = actions }
    }
}

private struct ActionRow: View {
    @Binding var action: NickAction
    let trialNick: String
    let trialChannel: String
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $action.isEnabled)
                    .labelsHidden()
                    .help("Offered in menus")
                TextField("Name in the menu", text: $action.name)
                    .font(.body.weight(.semibold))
                TextField("Channels: all", text: $action.channels)
                    .frame(width: 200)
                    .help("Offered only in these channels: #room*, #echo — empty for everywhere")
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            TextField("Command, e.g. /msg Data !view {nick}", text: $action.command, axis: .vertical)
                .font(.body.monospaced())
                .lineLimit(1...4)
            Text(preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .textFieldStyle(.roundedBorder)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .opacity(action.isEnabled ? 1 : 0.6)
    }

    private var preview: String {
        guard !action.command.isEmpty else { return " " }
        guard action.applies(to: trialChannel, isChannel: trialChannel.hasPrefix("#") || trialChannel.hasPrefix("&")) else {
            return "Not offered in \(trialChannel)"
        }
        return "In \(trialChannel) on \(trialNick): "
            + action.expanded(nick: trialNick, channel: trialChannel, me: "me", network: "Network")
                .replacingOccurrences(of: "\n", with: " ⏎ ")
    }
}
