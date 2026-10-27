import SwiftUI

/// Adds or edits a network.
struct NetworkEditor: View {
    let request: NetworkEditorRequest
    let onSave: (NetworkConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var config: NetworkConfig
    @State private var port: String
    @State private var proxyPort: String
    @State private var sshTunnelPort: String
    @State private var alternateNicks: String
    @State private var autoJoin: String
    @State private var highlightWords: String
    @State private var highlightPatterns: String
    @State private var performCommands: String
    private let identity = Identity.current

    init(request: NetworkEditorRequest, onSave: @escaping (NetworkConfig) -> Void) {
        self.request = request
        self.onSave = onSave
        _config = State(initialValue: request.config)
        _port = State(initialValue: String(request.config.port))
        _proxyPort = State(initialValue: String(request.config.proxyPort))
        _sshTunnelPort = State(initialValue: String(request.config.sshTunnelPort))
        _alternateNicks = State(initialValue: request.config.alternateNicks.joined(separator: ", "))
        _autoJoin = State(initialValue: request.config.autoJoin.joined(separator: ", "))
        _highlightWords = State(initialValue: request.config.highlightWords.joined(separator: ", "))
        _highlightPatterns = State(initialValue: request.config.highlightPatterns.joined(separator: "\n"))
        _performCommands = State(initialValue: request.config.performCommands.joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Server") {
                    TextField("Name", text: $config.name, prompt: Text("e.g. Libera.Chat"))
                    TextField("Host", text: $config.host, prompt: Text("irc.example.org"))
                    TextField("Port", text: $port)
                    Toggle("Use TLS", isOn: $config.useTLS)
                        .onChange(of: config.useTLS) { _, tls in
                            if port == "6697" && !tls { port = "6667" }
                            if port == "6667" && tls { port = "6697" }
                        }
                    if config.useTLS {
                        Toggle("Accept invalid certificates", isOn: $config.allowInvalidCertificates)
                    }
                    SecureField("Server password", text: $config.serverPassword, prompt: Text("Usually empty"))
                }

                Section {
                    Picker("Connect through", selection: $config.proxyKind) {
                        ForEach(ProxyKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if config.proxyKind == .ssh {
                        TextField("SSH server", text: $config.sshDestination,
                                  prompt: Text("user@host, or a Host from ~/.ssh/config"))
                        TextField("Local port", text: $sshTunnelPort, prompt: Text("1080"))
                    }
                    if config.proxyKind == .socks {
                        TextField("Proxy host", text: $config.proxyHost, prompt: Text("127.0.0.1"))
                        TextField("Proxy port", text: $proxyPort, prompt: Text("9050"))
                        TextField("Username", text: $config.proxyUsername, prompt: Text("Usually empty"))
                        SecureField("Password", text: $config.proxyPassword, prompt: Text("Usually empty"))
                    }
                } header: {
                    Text("Proxy")
                } footer: {
                    Text(proxyFooter)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Section {
                    TextField("Nick", text: $config.nick, prompt: Text(identity.nick))
                    TextField("Alternative nicks", text: $alternateNicks,
                              prompt: Text(identity.alternateNicks.joined(separator: ", ")))
                    TextField("Username", text: $config.username, prompt: Text(""))
                    TextField("Real name", text: $config.realName, prompt: Text(""))
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Empty fields use the defaults from Settings; an empty username or real name there sends your nick.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Section {
                    TextField("Account", text: $config.saslAccount, prompt: Text(config.effectiveNick(defaults: identity)))
                    SecureField("Password", text: $config.saslPassword)
                } header: {
                    Text("SASL Login")
                } footer: {
                    Text("Logs in to the network's services (NickServ) while connecting. Leave the password empty to skip. Passwords are kept in the keychain.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Section {
                    Toggle("Connect at launch", isOn: $config.connectAtLaunch)
                    TextField("Rejoin at login", text: $autoJoin, prompt: Text("#channel, #other"))
                } header: {
                    Text("Behaviour")
                } footer: {
                    Text("Connect at launch: when this network's tab was open at quit, it connects again on the next start; otherwise the tab comes back offline. Rejoin at login: the channels joined every time the network connects; also set with a channel's right-click menu.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Section {
                    TextEditor(text: $performCommands)
                        .font(.body.monospaced())
                        .frame(height: 70)
                } header: {
                    Text("Startup commands")
                } footer: {
                    Text("Run in order once logged in, before joining channels: /msg NickServ IDENTIFY …, /mode, a raw protocol line, or /wait 3 to pause. Messages sent from here are not shown or logged. Kept as plain text in \(IrctellHome.displayPath)/networks.plist: prefer SASL for passwords.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Section {
                    TextField("Words", text: $highlightWords, prompt: Text("e.g. a project name"))
                    VStack(alignment: .leading) {
                        Text("Patterns, one regular expression per line")
                        TextEditor(text: $highlightPatterns)
                            .font(.body.monospaced())
                            .frame(height: 44)
                        ForEach(lines(highlightPatterns).compactMap(HighlightRules.error(in:)), id: \.self) { error in
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Highlight on this network")
                } footer: {
                    Text("In addition to the ones in Settings.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Section("Ignore on this network") {
                    IgnoreListEditor(entries: $config.ignores)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 720)
    }

    private var isValid: Bool {
        !config.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !config.nick.trimmingCharacters(in: .whitespaces).contains(" ")
            && UInt16(port).map { $0 > 0 } == true
            && (config.proxyKind != .socks || (UInt16(proxyPort).map { $0 > 0 } == true
                                      && !config.proxyHost.trimmingCharacters(in: .whitespaces).isEmpty))
            && (config.proxyKind != .ssh || (UInt16(sshTunnelPort).map { $0 > 0 } == true
                                      && !config.sshDestination.trimmingCharacters(in: .whitespaces).isEmpty
                                      && !config.sshDestination.hasPrefix("-")))
    }

    private func save() {
        var result = config
        result.host = result.host.trimmingCharacters(in: .whitespaces)
        result.nick = result.nick.trimmingCharacters(in: .whitespaces)
        result.port = UInt16(port) ?? 6697
        result.proxyPort = UInt16(proxyPort) ?? 9050
        result.proxyHost = result.proxyHost.trimmingCharacters(in: .whitespaces)
        result.sshTunnelPort = UInt16(sshTunnelPort) ?? 1080
        result.sshDestination = result.sshDestination.trimmingCharacters(in: .whitespaces)
        if result.name.trimmingCharacters(in: .whitespaces).isEmpty { result.name = result.host }
        result.alternateNicks = list(alternateNicks)
        result.autoJoin = list(autoJoin)
        result.highlightWords = list(highlightWords)
        result.highlightPatterns = lines(highlightPatterns)
        result.performCommands = lines(performCommands)
        onSave(result)
        dismiss()
    }

    private var proxyFooter: String {
        let common = "The server's name is handed to the proxy, never looked up on this Mac, so a .onion host works. With the proxy down there is no connection: never one around it. Pictures are not downloaded by themselves; right-click a link › Download Picture fetches one through the proxy."
        switch config.proxyKind {
        case .none:
            return "Straight to the server. Tor hides your address from the network; it needs Homebrew's tor (brew install tor)."
        case .tor:
            return "127.0.0.1:9050. If Tor is not running, Irctell starts it with brew services when connecting, and stops it when quitting. Each network gets circuits of its own. " + common
        case .ssh:
            return "Irctell runs ssh -D on the local port when connecting, again whenever the tunnel has dropped, and closes it when quitting; IRC sees the SSH server's address. Logging in needs a key without a passphrase prompt: in ssh-agent or the keychain. A server is trusted the first time it is seen, and checked against that after. Networks through the same SSH server share the port; another server needs a port of its own. " + common
        case .socks:
            return "For example an ssh -D 1080 tunnel: 127.0.0.1, port 1080; or the Tor Browser's Tor: port 9150. " + common
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func list(_ text: String) -> [String] {
        text.split { $0 == "," || $0 == " " }.map(String.init)
    }
}
