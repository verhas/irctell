import AVFoundation
import SwiftUI

/// A nick, to choose a voice for.
struct VoiceChoice: Identifiable {
    let nick: String
    var id: String { nick.lowercased() }
}

/// Chooses the voice a nick's messages are read in: one of Kokoro's natural
/// voices, an English Apple voice that speaks like a person, or any voice on
/// the Mac.
struct VoicePicker: View {
    let nick: String

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var showsAll = false
    @State private var search = ""
    @State private var gender: GenderFilter

    /// Which voices are listed: all, or only women's or men's.
    enum GenderFilter: String, CaseIterable {
        case all = "All", female = "Female", male = "Male"
    }

    init(nick: String) {
        self.nick = nick
        _selection = State(initialValue: Voices.chosen(for: nick) ?? Voices.voice(for: nick)?.id)
        // Starts with what the nick looks like.
        let looks: GenderFilter = switch NickGender.guess(nick) {
        case .female: .female
        case .male: .male
        case .unknown: .all
        }
        _gender = State(initialValue: looks)
    }

    private struct Row: Identifiable {
        let voice: VoiceRef
        let details: String
        var id: String { voice.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice for \(nick)")
                .font(.headline)
            Picker("Voices", selection: $gender) {
                ForEach(GenderFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            HStack {
                Toggle("Show every Apple voice, in every language", isOn: $showsAll)
                    .toggleStyle(.checkbox)
                Spacer()
                SearchField(prompt: "Search", text: $search)
                    .frame(width: 160)
            }
            List(selection: $selection) {
                if KokoroEngine.isInstalled {
                    Section("Natural voices") {
                        ForEach(rows(natural: true)) { row($0) }
                    }
                }
                Section("Apple voices") {
                    ForEach(rows(natural: false)) { row($0) }
                }
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { use(id) }
            }
            HStack {
                Button("Automatic") {
                    Voices.choose(nil, for: nick)
                    dismiss()
                }
                .help("A voice is given by itself again: a woman's for a nick that looks like a woman's")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use") { selection.map(use) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding()
        .frame(width: 480, height: 560)
    }

    private func row(_ row: Row) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.voice.name)
                Text(row.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Speaker.shared.listen(to: row.voice, saying: "Hello, this is how \(nick) sounds.")
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Listen")
        }
        .tag(row.id)
    }

    private func rows(natural: Bool) -> [Row] {
        let all: [Row] = natural
            ? KokoroVoice.english.filter { fits(female: $0.isFemale) }
                .map { Row(voice: .kokoro($0), details: $0.details) }
            : (showsAll ? Voices.all : Voices.english)
                .filter { gender == .all || ($0.gender != .unspecified && fits(female: $0.gender == .female)) }
                .map { Row(voice: .apple($0), details: details(of: $0)) }
        guard !search.isEmpty else { return all }
        return all.filter { $0.voice.name.localizedCaseInsensitiveContains(search)
            || $0.details.localizedCaseInsensitiveContains(search) }
    }

    /// Whether a voice of this kind is listed under the chosen filter.
    private func fits(female: Bool) -> Bool {
        switch gender {
        case .all: true
        case .female: female
        case .male: !female
        }
    }

    private func details(of voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        let gender = switch voice.gender {
        case .female: "female"
        case .male: "male"
        default: "voice"
        }
        let quality = switch voice.quality {
        case .premium: " · premium"
        case .enhanced: " · enhanced"
        default: ""
        }
        return "\(language) · \(gender)\(quality)"
    }

    private func use(_ id: String) {
        Voices.choose(id, for: nick)
        dismiss()
    }
}
