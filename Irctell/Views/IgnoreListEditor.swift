import SwiftUI

/// The ignored nicks, each ignored everywhere or in private chats only.
struct IgnoreListEditor: View {
    @Binding var entries: [IgnoreEntry]
    @State private var newNick = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($entries) { $entry in
                HStack {
                    Text(entry.nick)
                    Spacer()
                    Picker("Ignore", selection: $entry.scope) {
                        ForEach(IgnoreEntry.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop ignoring \(entry.nick)")
                }
            }
            HStack {
                TextField("Nick to ignore", text: $newNick)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(nick.isEmpty)
            }
        }
    }

    private var nick: String {
        newNick.trimmingCharacters(in: .whitespaces)
    }

    private func add() {
        guard !nick.isEmpty, !entries.contains(where: { $0.id == nick.lowercased() }) else { return }
        entries.append(IgnoreEntry(nick: nick))
        newNick = ""
    }
}
