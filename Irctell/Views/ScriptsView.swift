import AppKit
import SwiftUI

/// The user's scripts: defined, changed, run and watched here. See
/// SCRIPTING.md.
struct ScriptsView: View {
    static let windowID = "scripts"

    @State private var scripts: [ScriptDefinition] = []
    @State private var selection: ScriptDefinition.ID?
    private var host: ScriptHost { .shared }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(scripts) { script in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(host.statuses[script.id]?.state ?? .idle, enabled: script.enabled))
                                .frame(width: 8, height: 8)
                            Text(script.name.isEmpty ? "Unnamed" : script.name)
                                .foregroundStyle(script.enabled ? .primary : .secondary)
                            Spacer()
                            Text(script.mode == .service ? "service" : "one-shot")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .tag(script.id)
                    }
                }
                Divider()
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }
                        .help("A new script")
                    Button { remove() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                        .help("Delete the script's definition; its file stays")
                    Spacer()
                    Button("Folder") {
                        let folder = IrctellHome.directory.appending(path: "scripts")
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    }
                    .help("Open \(IrctellHome.displayPath)/scripts, where scripts usually go")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)

            Group {
                if let index = scripts.firstIndex(where: { $0.id == selection }) {
                    ScriptEditor(script: $scripts[index], status: host.statuses[scripts[index].id] ?? .init())
                        .id(scripts[index].id)
                } else {
                    ContentUnavailableView("No Script Selected", systemImage: "terminal",
                                           description: Text("Scripts are programs of yours — bash, Python, anything — that Irctell starts when something happens, and that answer through their standard output. SCRIPTING.md describes it all."))
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            scripts = ScriptStore.shared.list
            if selection == nil { selection = scripts.first?.id }
        }
        .onChange(of: scripts) {
            ScriptStore.shared.list = scripts
            host.reload()
        }
    }

    private func color(_ state: ScriptHost.Status.State, enabled: Bool) -> Color {
        guard enabled else { return .gray.opacity(0.4) }
        switch state {
        case .running: return .green
        case .failed: return .red
        case .idle, .disabled: return .gray.opacity(0.4)
        }
    }

    private func add() {
        var script = ScriptDefinition(name: "New script", command: [ScriptDefinition.defaultDirectory + "/script.sh"])
        script.triggers = [ScriptTrigger(on: "run")]
        scripts.append(script)
        selection = script.id
    }

    private func remove() {
        guard let selection else { return }
        host.stop(selection)
        scripts.removeAll { $0.id == selection }
        self.selection = scripts.first?.id
    }
}

private struct ScriptEditor: View {
    @Binding var script: ScriptDefinition
    let status: ScriptHost.Status
    @State private var commandLine = ""
    @State private var environment = ""
    private var host: ScriptHost { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                state
                Form {
                    Section("Program") {
                        TextField("Name", text: $script.name, prompt: Text("Used by /run and in menus"))
                        Toggle("Enabled", isOn: $script.enabled)
                        TextField("Command", text: $commandLine, prompt: Text("/usr/bin/python3 \(ScriptDefinition.defaultDirectory)/bot.py"))
                            .font(.body.monospaced())
                            .onSubmit { script.command = ScriptDefinition.words(commandLine) }
                            .onChange(of: commandLine) { script.command = ScriptDefinition.words(commandLine) }
                            .help("The program and its arguments, as in Terminal: quotes keep spaces together. Not run through a shell.")
                        TextField("Folder", text: $script.directory, prompt: Text(ScriptDefinition.defaultDirectory))
                        Picker("Mode", selection: $script.mode) {
                            Text("One-shot: started for each event").tag(ScriptDefinition.Mode.oneShot)
                            Text("Service: keeps running").tag(ScriptDefinition.Mode.service)
                        }
                        Picker("Protocol", selection: $script.protocol) {
                            Text("Text: plain lines").tag(ScriptDefinition.Format.text)
                            Text("JSON Lines").tag(ScriptDefinition.Format.json)
                        }
                        if script.mode == .oneShot {
                            Stepper("Time limit: \(script.timeout) s", value: $script.timeout, in: 1...600)
                            Stepper("At most \(script.maxInstances) running at once", value: $script.maxInstances, in: 1...20)
                        } else {
                            Picker("Restart", selection: $script.restart) {
                                Text("When it fails").tag(ScriptDefinition.Restart.onFailure)
                                Text("Always").tag(ScriptDefinition.Restart.always)
                                Text("Never").tag(ScriptDefinition.Restart.never)
                            }
                        }
                        Stepper("At most \(script.linesPerMinute) lines a minute to IRC", value: $script.linesPerMinute, in: 1...300)
                        LabeledContent("Environment") {
                            TextEditor(text: $environment)
                                .font(.callout.monospaced())
                                .frame(height: 44)
                                .onChange(of: environment) { script.environment = ScriptEditor.variables(environment) }
                        }
                        .help("NAME=value, one per line, added to the IRCTELL_ variables")
                    }
                    Section {
                        ForEach($script.triggers) { $trigger in
                            TriggerRow(trigger: $trigger) { script.triggers.removeAll { $0.id == trigger.id } }
                        }
                        Button {
                            script.triggers.append(ScriptTrigger(on: "message"))
                        } label: {
                            Label("Add Trigger", systemImage: "plus")
                        }
                    } header: {
                        Text("Triggers")
                    } footer: {
                        Text("Any one matching is enough. Patterns take * and ?, several separated by commas; the text is a regular expression, its groups passed on as arguments and IRCTELL_GROUP_1….")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    PermissionsSection(permissions: $script.permissions)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
            .padding()
        }
        .onAppear {
            commandLine = script.commandLine
            environment = script.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
    }

    private var state: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stateText).font(.headline)
                Spacer()
                Button("Run") { host.runFromMenu(script.id) }
                    .help("Start it now, as from the Scripts menu (a menu event)")
                    .disabled(!script.enabled)
                Button("Stop") { host.stop(script.id) }
                    .disabled(status.running == 0)
                if script.mode == .service {
                    Button("Restart") { host.restart(script.id) }
                        .disabled(!script.enabled)
                }
            }
            if !status.output.isEmpty || !status.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(status.output.suffix(20).enumerated()), id: \.offset) { _, line in
                            Text(line).foregroundStyle(.primary)
                        }
                        ForEach(Array(status.errors.suffix(20).enumerated()), id: \.offset) { _, line in
                            Text(line).foregroundStyle(.red)
                        }
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                .help("The last lines of its output, and of its standard error in red; all of it is in the Irctell Log (⌥⌘L), category scripts")
            }
        }
    }

    private var stateText: String {
        guard script.enabled else { return "Disabled" }
        var parts: [String] = []
        switch status.state {
        case .running: parts.append(status.running > 1 ? "Running (\(status.running))" : "Running")
        case .failed: parts.append("Failed")
        default: parts.append("Not running")
        }
        if let started = status.lastStarted { parts.append("started \(started.formatted(date: .omitted, time: .standard))") }
        if let exit = status.lastExit { parts.append("last exit status \(exit)") }
        return parts.joined(separator: " · ")
    }

    static func variables(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { values[parts[0]] = parts[1] }
        }
        return values
    }
}

private struct TriggerRow: View {
    @Binding var trigger: ScriptTrigger
    let delete: () -> Void

    private var networks: Binding<String> {
        Binding(get: { trigger.networks.joined(separator: ", ") },
                set: { trigger.networks = $0.split { $0 == "," }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }

    private var own: Binding<String> {
        Binding(get: {
                    switch trigger.lines {
                    case "all", "mine", "others": trigger.lines
                    default: trigger.isSelf == true ? "mine" : (trigger.isSelf == false ? "others" : "")
                    }
                },
                set: { trigger.lines = $0; trigger.isSelf = nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("On", selection: $trigger.on) {
                    ForEach(ScriptTrigger.events, id: \.name) { Text("\($0.title) (\($0.name))").tag($0.name) }
                }
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove the trigger")
            }
            if trigger.on == "timer" {
                HStack {
                    TextField("Every", text: $trigger.every, prompt: Text("10m"))
                    TextField("Or daily at", text: $trigger.at, prompt: Text("08:30"))
                }
            }
            if !["startup", "shutdown", "menu", "run"].contains(trigger.on) {
                HStack {
                    TextField("Networks", text: networks, prompt: Text("All networks"))
                    if !["timer", "connect", "disconnect", "away", "back", "quit", "nick", "ctcp", "memo"].contains(trigger.on) {
                        TextField("Channels", text: $trigger.channels, prompt: Text("All channels, or #delta*"))
                    }
                }
            }
            if ScriptEvent.textual.contains(trigger.on) || ["join", "part", "kick", "topic", "mode", "invite"].contains(trigger.on) {
                HStack {
                    TextField("Nicks", text: $trigger.nicks, prompt: Text("Anyone"))
                    TextField("Not nicks", text: $trigger.notNicks, prompt: Text("e.g. *bot"))
                }
                TextField("Text matches", text: $trigger.text, prompt: Text("A regular expression, e.g. ^!roll\\s+(\\d+)"))
                    .font(.callout.monospaced())
                HStack {
                    Picker("Whose lines", selection: own) {
                        Text("Others' (default)").tag("")
                        Text("Mine and others'").tag("all")
                        Text("Mine only").tag("mine")
                    }
                    .help("Lines a script sends never trigger scripts, so a script cannot answer itself")
                    Toggle("Also from ignored nicks", isOn: $trigger.ignored)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 4)
    }
}

private struct PermissionsSection: View {
    @Binding var permissions: ScriptPermissions

    private var networks: Binding<String> {
        Binding(get: { permissions.networks.joined(separator: ", ") },
                set: { permissions.networks = $0.split { $0 == "," }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }

    private var commands: Binding<String> {
        Binding(get: { permissions.commands.joined(separator: ", ") },
                set: { permissions.commands = $0.split { $0 == "," || $0 == " " }.map(String.init).filter { !$0.isEmpty } })
    }

    var body: some View {
        Section {
            TextField("Networks", text: networks, prompt: Text("All"))
            TextField("May send to", text: $permissions.sendTo, prompt: Text("Anywhere — or origin, channels, private, none, #delta*"))
            TextField("Commands", text: commands, prompt: Text("All — or msg, me, notice; none for none"))
            Toggle("Raw IRC lines", isOn: $permissions.raw)
            Toggle("Join, leave and close channels", isOn: $permissions.channelsJoined)
            Toggle("Read the log: history, mentions, memos", isOn: $permissions.readLog)
            Toggle("Hear lines from ignored nicks", isOn: $permissions.ignored)
            Toggle("Dry run: show what it would send, send nothing", isOn: $permissions.dryRun)
        } header: {
            Text("Permissions")
        } footer: {
            Text("A script may do everything you can, unless restricted here. Scripts run as you, with your access to your files: run only what you wrote or trust. Passwords are never given to scripts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
