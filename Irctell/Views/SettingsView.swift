import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Identity", systemImage: "person.crop.circle") { IdentitySettings() }
            Tab("Notifications", systemImage: "bell.badge") { NotificationSettings() }
            Tab("Pictures", systemImage: "photo") { PictureSettings() }
            Tab("Speech", systemImage: "waveform") { SpeechSettings() }
            Tab("Away", systemImage: "moon.zzz") { AwaySettings() }
        }
        .frame(width: 500)
    }
}

/// Settings keys of the app itself.
enum GeneralSettingsKeys {
    static let confirmQuit = "confirmQuit"
}

private struct GeneralSettings: View {
    private let settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Ask before quitting", isOn: settings.binding(GeneralSettingsKeys.confirmQuit, default: true))
            } footer: {
                Text("Quitting disconnects from every network. Logging out or shutting down the Mac never asks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Suggest replies", isOn: settings.binding(ReplySuggester.enabledKey, default: true))
                Toggle("Also for private chats in the background",
                       isOn: settings.binding(ReplySuggester.backgroundKey, default: true))
                    .disabled(!settings.bool(forKey: ReplySuggester.enabledKey, default: true))
                if let reason = ReplySuggester.shared.unavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("When someone writes and your input field is empty, Apple Intelligence reads the last \(ReplySuggester.contextLines) messages and suggests a reply, shown in the empty field; Tab puts it there to edit or send. In the background, private chats get theirs as messages come, so it is ready when you look; a ✦ in the sidebar shows one is waiting. The conversation in front always goes first. Only the model on this Mac is used: the conversation never leaves it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Tell others which client I use", isOn: settings.binding(ClientIdentity.revealKey, default: true))
                TextField("Client", text: settings.binding(ClientIdentity.versionKey), prompt: Text(ClientIdentity.standard))
                    .disabled(!settings.bool(forKey: ClientIdentity.revealKey, default: true))
            } header: {
                Text("Client version")
            } footer: {
                Text("The answer to a CTCP VERSION query, which some networks and users send to see what you run. Off, such queries go unanswered. Ignored nicks never get an answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct IdentitySettings: View {
    private let settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                TextField("Nick", text: settings.binding(Identity.nickKey), prompt: Text(NSUserName()))
                TextField("Alternative nicks", text: settings.binding(Identity.alternateNicksKey),
                          prompt: Text("\(effectiveNick)_, \(effectiveNick)2"))
                TextField("Username", text: settings.binding(Identity.usernameKey), prompt: Text(""))
                TextField("Real name", text: settings.binding(Identity.realNameKey), prompt: Text(""))
            } footer: {
                Text("Kept in \(IrctellHome.displayPath)/settings.plist. Used on every network that does not set its own. An empty username or real name sends your nick. Takes effect on the next connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var effectiveNick: String {
        let nick = settings.string(forKey: Identity.nickKey) ?? ""
        return nick.isEmpty ? NSUserName() : nick
    }
}

private struct NotificationSettings: View {
    private let settings = SettingsStore.shared
    @State private var words = ""
    @State private var patterns = ""

    var body: some View {
        Form {
            Section {
                Toggle("Mentions", isOn: settings.binding(AttentionSettings.notifyMentions, default: true))
                Toggle("Private messages", isOn: settings.binding(AttentionSettings.notifyPrivateMessages, default: true))
                Toggle("Play a sound", isOn: settings.binding(AttentionSettings.sound, default: true))
                Toggle("Bounce the Dock icon when Irctell is in the background",
                       isOn: settings.binding(AttentionSettings.bounce, default: false))
                Toggle("Count them on the Dock icon", isOn: settings.binding(AttentionSettings.dockBadge, default: true))
            } header: {
                Text("Notify about")
            } footer: {
                Text("A conversation's right-click menu sets how much it notifies: every message, mentions only, or never. Nothing is notified about the conversation you are looking at.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Words", text: $words, prompt: Text("e.g. irctell, Peter"))
                    .onChange(of: words) { settings.set(list(words), forKey: HighlightRules.wordsKey) }
                VStack(alignment: .leading) {
                    Text("Patterns, one regular expression per line")
                    TextEditor(text: $patterns)
                        .font(.body.monospaced())
                        .frame(height: 60)
                        .onChange(of: patterns) {
                            settings.set(lines(patterns), forKey: HighlightRules.patternsKey)
                        }
                    ForEach(lines(patterns).compactMap(HighlightRules.error(in:)), id: \.self) { error in
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Highlight")
            } footer: {
                Text("Your nick always highlights. Words match whole words, ignoring case. Each network can add its own in its settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                IgnoreListEditor(entries: Binding(get: { HighlightRules.globalIgnores(in: settings) },
                                                  set: { HighlightRules.setGlobalIgnores($0, in: settings) }))
            } header: {
                Text("Ignore on every network")
            } footer: {
                Text("Everything: their messages are not shown, in channels either. Private messages: channel messages are shown, private messages open no chat. Ignored messages are still logged, silently: stop ignoring, and they are there when you scroll back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            words = (settings.stringArray(forKey: HighlightRules.wordsKey) ?? []).joined(separator: ", ")
            patterns = (settings.stringArray(forKey: HighlightRules.patternsKey) ?? []).joined(separator: "\n")
        }
    }

    private func list(_ text: String) -> [String] {
        text.split { $0 == "," || $0 == " " }.map(String.init)
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private struct PictureSettings: View {
    private let settings = SettingsStore.shared

    private var maxMegabytes: Binding<Int> {
        Binding(get: { settings.object(forKey: MediaSettings.maxMegabytes) as? Int ?? MediaSettings.defaultMaxMegabytes },
                set: { settings.set($0, forKey: MediaSettings.maxMegabytes) })
    }

    private var historySpeed: Binding<Int> {
        Binding(get: { settings.object(forKey: MediaSettings.historySpeed) as? Int ?? MediaSettings.defaultHistorySpeed },
                set: { settings.set($0, forKey: MediaSettings.historySpeed) })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Download pictures linked in messages", isOn: settings.binding(MediaSettings.enabled, default: true))
                Toggle("Show them collapsed, opened with a click",
                       isOn: settings.binding(MediaSettings.startCollapsed, default: false))
                    .disabled(!settings.bool(forKey: MediaSettings.enabled, default: true))
                Picker("Largest picture", selection: maxMegabytes) {
                    ForEach([1, 2, 5, 10, 25, 50], id: \.self) { Text("\($0) MB").tag($0) }
                }
                .disabled(!settings.bool(forKey: MediaSettings.enabled, default: true))
                Picker("Downloading a history", selection: historySpeed) {
                    ForEach([50, 100, 200, 500, 1000, 2000], id: \.self) { speed in
                        Text(speed >= 1000 ? "\(speed / 1000) MB a second" : "\(speed) KB a second").tag(speed)
                    }
                }
            } footer: {
                Text("Links to pictures, in anyone's messages and your own, are downloaded and shown under the message, and kept in the message log. Downloading tells the picture's site your IP address. A conversation's right-click menu can show its pictures collapsed, or not download them, whatever is set here. Its Download Pictures in History gets the pictures of the whole conversation in the background, at the speed set here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SpeechSettings: View {
    private let settings = SettingsStore.shared
    @Bindable private var installer = KokoroInstaller.shared
    @Environment(\.openWindow) private var openWindow

    private var engine: Binding<SpeechEngine> {
        Binding(get: { settings.string(forKey: SpeechEngine.key).flatMap(SpeechEngine.init(rawValue:)) ?? .apple },
                set: { settings.set($0.rawValue, forKey: SpeechEngine.key) })
    }

    var body: some View {
        Form {
            Section {
                Picker("Voices", selection: engine) {
                    ForEach(SpeechEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Each nick is given a voice of its own, a woman's for a nick that looks like a woman's; right-click a nick › Voice… to choose another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Correct the spelling before reading a line (Apple Intelligence)",
                       isOn: settings.binding(LinePreparer.correctKey, default: true))
                    .help("Typos are fixed for the voice only, on this Mac; the conversation shows the line as written. A correction that changes too much is not used.")
                Toggle("Laughs and sighs for lol, rofl, :) and :(",
                       isOn: settings.binding(Reaction.enabledKey, default: true))
                InterjectionChance(title: "A sound before a line", key: Interjection.beforeKey)
                InterjectionChance(title: "A sound after a line", key: Interjection.afterKey)
                Toggle("Apple Intelligence picks the sound to fit the line",
                       isOn: settings.binding(Interjection.intelligenceKey, default: true))
                    .disabled((settings.object(forKey: Interjection.beforeKey) as? Int ?? 0) == 0
                              && (settings.object(forKey: Interjection.afterKey) as? Int ?? 0) == 0)
                Button("Open Sounds Folder") {
                    let folder = IrctellHome.directory.appending(path: "sounds")
                    for reaction in Reaction.allCases {
                        try? FileManager.default.createDirectory(at: folder.appending(path: reaction.rawValue),
                                                                 withIntermediateDirectories: true)
                    }
                    NSWorkspace.shared.open(folder)
                }
                Button("Spoken Abbreviations…") { openWindow(id: AbbreviationEditor.windowID) }
            } footer: {
                Text("Instead of reading out “R O T F L” or “colon parenthesis”, a sound is played, picked at random. Sounds put in \(IrctellHome.displayPath)/sounds/giggle, laugh, bigLaugh or sad are picked too.\n\nA line read aloud can also get a short sound before or after it — hmm, mhm, huh, ooh, wow, aww, ahh, ugh, a sigh, a groan, tsk, pfft, ouch — at random, about as often as set: each line is decided apart, so 50% is about half of them. Apple Intelligence picks the sound that fits the line, on this Mac, and judges how well: a sound that clearly fits is heard more often than set, one that barely fits less often, and a line no sound suits gets none. Never and Always stay as they say. Without Apple Intelligence, simple rules pick. Your own go in \(IrctellHome.displayPath)/sounds/hmm, sigh and so on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if installer.isInstalled {
                    LabeledContent("Model") {
                        HStack {
                            Text("Installed")
                            Button("Remove") { installer.remove() }
                        }
                    }
                } else {
                    switch installer.state {
                    case .downloading(let fraction):
                        ProgressView(value: fraction) {
                            Text("Downloading… \(Int(fraction * 100))%")
                        }
                    case .unpacking:
                        ProgressView { Text("Unpacking…") }
                    case .idle, .failed:
                        Button("Download Natural Voices (\(KokoroEngine.downloadMegabytes) MB)") {
                            Task { await installer.install() }
                        }
                        if case .failed(let reason) = installer.state {
                            Text(reason).foregroundStyle(.red).font(.caption)
                        }
                    }
                }
            } header: {
                Text("Natural voices")
            } footer: {
                Text("Kokoro, an open speech model (Apache License 2.0), runs on this Mac: nothing is sent anywhere. 28 English voices, American and British. Downloaded once into ~/.irctell/voices, for every profile. Until it is there, Apple's voices are used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Open Spoken Content Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } header: {
                Text("Better Apple voices")
            } footer: {
                Text("Apple's Premium and Enhanced voices sound far less robotic, and are free. In Accessibility › Spoken Content, open the System voice menu and choose Manage Voices… at its end; download English voices marked Premium or Enhanced. Irctell then uses only those.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AwaySettings: View {
    private let settings = SettingsStore.shared

    private var awayMessage: Binding<String> {
        Binding(get: { settings.string(forKey: AttentionSettings.awayMessage) ?? "" },
                set: { settings.set($0, forKey: AttentionSettings.awayMessage) })
    }

    private var idleMinutes: Binding<Int> {
        Binding(get: { settings.object(forKey: AttentionSettings.idleMinutes) as? Int ?? AttentionSettings.defaultIdleMinutes },
                set: { settings.set($0, forKey: AttentionSettings.idleMinutes) })
    }

    var body: some View {
        Form {
            Section {
                Picker("Away when the Mac is idle for", selection: idleMinutes) {
                    Text("Never").tag(0)
                    ForEach([2, 5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Collect mentions and private messages while away",
                       isOn: settings.binding(AttentionSettings.awayDigest, default: true))
                Toggle("Mark me away on the networks", isOn: settings.binding(AttentionSettings.setAwayWhenIdle, default: true))
                TextField("Away message", text: awayMessage, prompt: Text(AttentionSettings.defaultAwayMessage))
                    .disabled(!settings.bool(forKey: AttentionSettings.setAwayWhenIdle, default: true))
                Toggle("Mute Irctell", isOn: settings.binding(AttentionSettings.muteWhenIdle, default: true))
            } footer: {
                Text("When the Mac is idle, Irctell sends /away on every connected network and goes quiet; when you are back, it sends /back and speaks again. An /away or a mute of your own is left as it is. You are also away on a network while marked with /away. When you are back, one notification sums up what came; the Mentions window (⇧⌘M) lists it on top.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// How likely a line read aloud gets a short sound -- a "hmm", a sigh, an
/// "ooh" -- from never to always.
private struct InterjectionChance: View {
    let title: String
    let key: String
    private let settings = SettingsStore.shared

    private var chance: Binding<Double> {
        Binding(get: { Double(settings.object(forKey: key) as? Int ?? 0) },
                set: { settings.set(Int($0.rounded()), forKey: key) })
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: chance, in: 0...100, step: 5)
                    .frame(width: 160)
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .help("Each line is decided at random: 50% is about half of the lines, not exactly every other one.")
    }

    private var label: String {
        switch Int(chance.wrappedValue) {
        case 0: "Never"
        case 100: "Always"
        case let value: "\(value)%"
        }
    }
}
