import SwiftUI

/// The abbreviations read out in full when messages are read aloud: what is
/// written, and what is said.
struct AbbreviationEditor: View {
    static let windowID = "abbreviations"

    @State private var list: [Abbreviation] = []
    @State private var filter = ""
    @State private var trial = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When a message is read aloud, these are said in full: “wtf” is “what the fuck”, not “W T F”. Only whole words count, in any case. Laughs like lol and rofl are played as sounds while those are on in Settings › Speech; then these are not used for them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    filter = ""
                    list.insert(Abbreviation(short: "", spoken: ""), at: 0)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button("Restore Samples") { list = Abbreviations.samples }
                    .help("The list Irctell came with")
                Spacer()
                SearchField(prompt: "Filter", text: $filter)
                    .frame(width: 180)
            }

            List {
                ForEach($list) { $entry in
                    if shows(entry) {
                        HStack {
                            TextField("abbr", text: $entry.short)
                                .font(.body.monospaced())
                                .frame(width: 90)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            TextField("Said as", text: $entry.spoken)
                            Button(role: .destructive) {
                                list.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                SearchField(prompt: "Try a line, as someone would write it", text: $trial)
                if !trial.isEmpty {
                    Text(Abbreviations.expand(trial, with: list))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
        .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 640)
        .onAppear { list = Abbreviations.shared.list }
        .onChange(of: list) { Abbreviations.shared.list = list }
    }

    private func shows(_ entry: Abbreviation) -> Bool {
        filter.isEmpty || entry.short.isEmpty || entry.short.localizedCaseInsensitiveContains(filter)
            || entry.spoken.localizedCaseInsensitiveContains(filter)
    }
}
