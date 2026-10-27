import SwiftUI

/// A nick, to say which other nicks are the same person's.
struct AliasChoice: Identifiable {
    let nick: String
    var id: String { nick.lowercased() }
}

/// The nicks of the log, filtered by typing, to tick the ones that are the
/// same person as `nick`. A private chat with any of them then shows the
/// chats with all of them.
struct AliasPicker: View {
    let nick: String
    let log: LogStore?

    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var chosen: Set<String>

    init(nick: String, log: LogStore?) {
        self.nick = nick
        self.log = log
        _chosen = State(initialValue: Set(People.aliases(of: nick)).subtracting([nick.lowercased()]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Other nicks of \(nick)")
                .font(.headline)
            Text("Their private chats are shown together with \(nick)'s. Each nick's lines stay its own in the log.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SearchField(prompt: "Type to find nicks", text: $filter)
            List(candidates, id: \.self) { candidate in
                Toggle(candidate, isOn: Binding(
                    get: { chosen.contains(candidate.lowercased()) },
                    set: { on in
                        if on { chosen.insert(candidate.lowercased()) } else { chosen.remove(candidate.lowercased()) }
                    }))
                    .toggleStyle(.checkbox)
            }
            HStack {
                Text(chosen.isEmpty ? "No other nicks" : "\(chosen.count) other nick\(chosen.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    People.setAliases(chosen, of: nick)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420, height: 500)
    }

    /// The ticked ones first, then the log's nicks matching the filter, the
    /// most recently seen first.
    private var candidates: [String] {
        let ticked = chosen.sorted()
        let found = (log?.nicks(containing: filter, limit: 300) ?? [])
            .filter { $0.caseInsensitiveCompare(nick) != .orderedSame && !chosen.contains($0.lowercased()) }
        return ticked.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) } + found
    }
}
