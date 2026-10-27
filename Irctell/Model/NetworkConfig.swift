import Foundation

/// A network as the user set it up. Saved to networks.json, except the two
/// passwords, which go to the keychain.
struct NetworkConfig: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16 = 6697
    var useTLS = true
    var allowInvalidCertificates = false
    /// Empty fields of the identity take the defaults from Settings.
    var nick: String
    var alternateNicks: [String] = []
    var username = ""
    var realName = ""
    var saslAccount = ""
    /// Channels joined on every connect, besides those still open from before.
    var autoJoin: [String] = []
    /// Starred networks are listed first.
    var isFavorite = false
    /// Whether its tab, if open when Irctell quit, connects on the next
    /// launch, or comes back offline.
    var connectAtLaunch = true
    /// Highlight words, patterns and ignores for this network, besides the
    /// ones in the settings.
    var highlightWords: [String] = []
    var highlightPatterns: [String] = []
    var ignores: [IgnoreEntry] = []
    /// Run in order once logged in, before the channels are joined: IRC
    /// commands like `/msg NickServ IDENTIFY …`, raw protocol lines, and
    /// `/wait <seconds>`.
    var performCommands: [String] = []

    /// Connects directly, through Tor -- started with Homebrew when needed --
    /// through an SSH tunnel Irctell opens, or through another SOCKS5 proxy.
    var proxyKind = ProxyKind.none
    /// The other proxy; its password goes to the keychain.
    var proxyHost = "127.0.0.1"
    var proxyPort: UInt16 = 9050
    var proxyUsername = ""
    /// The SSH tunnel: `user@host`, or a Host from ~/.ssh/config, and the
    /// local port its SOCKS5 proxy listens on.
    var sshDestination = ""
    var sshTunnelPort: UInt16 = 1080

    var serverPassword = ""
    var saslPassword = ""
    var proxyPassword = ""

    init(name: String, host: String, port: UInt16 = 6697, useTLS: Bool = true, nick: String = "") {
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.nick = nick
    }

    /// What the IRC client needs to connect, with the defaults filled in.
    func serverConfig(defaults: Identity) -> IRCServerConfig {
        let nick = effectiveNick(defaults: defaults)
        var config = IRCServerConfig(host: host, port: port, useTLS: useTLS, nick: nick,
                                     username: [username, defaults.username].first { !$0.isEmpty },
                                     realName: [realName, defaults.realName].first { !$0.isEmpty })
        config.allowInvalidCertificates = allowInvalidCertificates
        config.answersCTCP = false // the session does, knowing the ignores and settings
        config.alternateNicks = self.nick.isEmpty && alternateNicks.isEmpty ? defaults.alternateNicks : alternateNicks
        config.serverPassword = serverPassword.isEmpty ? nil : serverPassword
        if !saslPassword.isEmpty {
            config.sasl = SASLCredentials(account: saslAccount.isEmpty ? nick : saslAccount,
                                          password: saslPassword)
        }
        config.proxy = proxy
        return config
    }

    var usesProxy: Bool { proxyKind != .none }

    /// Where the connection goes through; nil for straight to the server.
    var proxy: SOCKSProxy? {
        switch proxyKind {
        case .none:
            return nil
        case .tor:
            // A username of its own: Tor keeps each network on circuits of
            // its own, so the networks cannot be linked by exit address.
            return SOCKSProxy(host: TorService.host, port: TorService.port,
                              username: "irctell-\(id.uuidString.prefix(8))", password: "irctell",
                              freshCircuitEachConnection: true)
        case .socks:
            return SOCKSProxy(host: proxyHost.trimmingCharacters(in: .whitespaces), port: proxyPort,
                              username: proxyUsername.isEmpty ? nil : proxyUsername,
                              password: proxyPassword.isEmpty ? nil : proxyPassword)
        case .ssh:
            return SOCKSProxy(host: SSHTunnelService.host, port: sshTunnelPort)
        }
    }

    func effectiveNick(defaults: Identity) -> String {
        nick.isEmpty ? defaults.nick : nick
    }

    /// Changes that only take effect on a new connection.
    func needsReconnect(comparedTo other: NetworkConfig) -> Bool {
        var a = self, b = other
        a.name = ""; b.name = ""
        a.autoJoin = []; b.autoJoin = []
        a.isFavorite = false; b.isFavorite = false
        a.connectAtLaunch = true; b.connectAtLaunch = true
        a.highlightWords = []; b.highlightWords = []
        a.highlightPatterns = []; b.highlightPatterns = []
        a.ignores = []; b.ignores = []
        a.performCommands = []; b.performCommands = []
        return a != b
    }

    // MARK: - Codable, passwords excluded

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, useTLS, allowInvalidCertificates, nick, alternateNicks
        case username, realName, saslAccount, autoJoin, isFavorite, connectAtLaunch
        case highlightWords, highlightPatterns, ignores, performCommands
        case usesProxy, proxyKind, proxyHost, proxyPort, proxyUsername
        case sshDestination, sshTunnelPort
    }

    /// Every field but the identity is optional on reading, so a file written
    /// by an older version, before a field existed, still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        nick = try c.decode(String.self, forKey: .nick)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 6697
        useTLS = try c.decodeIfPresent(Bool.self, forKey: .useTLS) ?? true
        allowInvalidCertificates = try c.decodeIfPresent(Bool.self, forKey: .allowInvalidCertificates) ?? false
        alternateNicks = try c.decodeIfPresent([String].self, forKey: .alternateNicks) ?? []
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        realName = try c.decodeIfPresent(String.self, forKey: .realName) ?? ""
        saslAccount = try c.decodeIfPresent(String.self, forKey: .saslAccount) ?? ""
        autoJoin = try c.decodeIfPresent([String].self, forKey: .autoJoin) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        connectAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .connectAtLaunch) ?? true
        highlightWords = try c.decodeIfPresent([String].self, forKey: .highlightWords) ?? []
        highlightPatterns = try c.decodeIfPresent([String].self, forKey: .highlightPatterns) ?? []
        ignores = try c.decodeIfPresent([IgnoreEntry].self, forKey: .ignores) ?? []
        performCommands = try c.decodeIfPresent([String].self, forKey: .performCommands) ?? []
        proxyKind = try c.decodeIfPresent(ProxyKind.self, forKey: .proxyKind)
            ?? (try c.decodeIfPresent(Bool.self, forKey: .usesProxy) == true ? .socks : .none)
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? "127.0.0.1"
        proxyPort = try c.decodeIfPresent(UInt16.self, forKey: .proxyPort) ?? 9050
        proxyUsername = try c.decodeIfPresent(String.self, forKey: .proxyUsername) ?? ""
        sshDestination = try c.decodeIfPresent(String.self, forKey: .sshDestination) ?? ""
        sshTunnelPort = try c.decodeIfPresent(UInt16.self, forKey: .sshTunnelPort) ?? 1080
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(useTLS, forKey: .useTLS)
        try c.encode(allowInvalidCertificates, forKey: .allowInvalidCertificates)
        try c.encode(nick, forKey: .nick)
        try c.encode(alternateNicks, forKey: .alternateNicks)
        try c.encode(username, forKey: .username)
        try c.encode(realName, forKey: .realName)
        try c.encode(saslAccount, forKey: .saslAccount)
        try c.encode(autoJoin, forKey: .autoJoin)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(connectAtLaunch, forKey: .connectAtLaunch)
        try c.encode(highlightWords, forKey: .highlightWords)
        try c.encode(highlightPatterns, forKey: .highlightPatterns)
        try c.encode(ignores, forKey: .ignores)
        try c.encode(performCommands, forKey: .performCommands)
        try c.encode(proxyKind, forKey: .proxyKind)
        try c.encode(proxyHost, forKey: .proxyHost)
        try c.encode(proxyPort, forKey: .proxyPort)
        try c.encode(proxyUsername, forKey: .proxyUsername)
        try c.encode(sshDestination, forKey: .sshDestination)
        try c.encode(sshTunnelPort, forKey: .sshTunnelPort)
    }
}

extension NetworkConfig {
    /// The well-known networks bundled with the app, to start the list with.
    /// Checked for working ports when the list was made; networks move, so
    /// entries can go stale.
    static func knownNetworks() -> [NetworkConfig] {
        struct Entry: Decodable { var name: String; var host: String; var port: UInt16; var tls: Bool }
        guard let url = Bundle.main.url(forResource: "KnownNetworks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.map { NetworkConfig(name: $0.name, host: $0.host, port: $0.port, useTLS: $0.tls) }
    }
}

/// The nick and names used on every network that does not set its own.
struct Identity: Equatable {
    static let nickKey = "identity.nick"
    static let alternateNicksKey = "identity.alternateNicks"
    static let usernameKey = "identity.username"
    static let realNameKey = "identity.realName"

    var nick: String
    var alternateNicks: [String]
    /// Empty unless the user typed one: never taken from the Mac's account.
    /// The server must get something, so an empty one sends the nick.
    var username: String
    var realName: String

    @MainActor static var current: Identity {
        let defaults = SettingsStore.shared
        func value(_ key: String, _ fallback: String) -> String {
            let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
            return stored.isEmpty ? fallback : stored
        }
        let nick = value(nickKey, NSUserName())
        return Identity(
            nick: nick,
            alternateNicks: (defaults.string(forKey: alternateNicksKey) ?? "")
                .split { $0 == "," || $0 == " " }.map(String.init),
            username: value(usernameKey, ""),
            realName: value(realNameKey, ""))
    }
}

/// Loads and saves the network list, a binary property list.
struct NetworkStore {
    let fileURL: URL
    var usesKeychain = true
    /// The JSON list of earlier versions, read when there is no property
    /// list yet.
    var legacyFiles: [URL] = []

    /// In the profile's folder. Passwords are in the keychain, except in a
    /// trial or test home, which keeps away from the real keychain entries.
    static let standard: NetworkStore = {
        var legacy = [IrctellHome.directory.appending(path: "networks.json")]
        if IrctellHome.isDefault {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            legacy.append(support.appending(path: "Irctell/networks.json"))
        }
        return NetworkStore(fileURL: IrctellHome.networksFile, usesKeychain: IrctellHome.usesKeychain,
                            legacyFiles: legacy)
    }()

    func load() -> [NetworkConfig] {
        var networks: [NetworkConfig]
        if let data = try? Data(contentsOf: fileURL) {
            guard let stored = try? PropertyListDecoder().decode([NetworkConfig].self, from: data) else { return [] }
            networks = stored
        } else if let legacy = legacyFiles.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
                  let stored = try? JSONDecoder().decode([NetworkConfig].self, from: legacy) {
            networks = stored
            save(networks)
        } else {
            return []
        }
        if usesKeychain {
            for index in networks.indices {
                let id = networks[index].id.uuidString
                networks[index].serverPassword = Keychain.password(for: "\(id)/server") ?? ""
                networks[index].saslPassword = Keychain.password(for: "\(id)/sasl") ?? ""
                networks[index].proxyPassword = Keychain.password(for: "\(id)/proxy") ?? ""
            }
        }
        return networks
    }

    func save(_ networks: [NetworkConfig]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(networks).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.error("networks", "could not save networks: \(error)")
        }
    }

    func savePasswords(of network: NetworkConfig) {
        guard usesKeychain else { return }
        let id = network.id.uuidString
        Keychain.setPassword(network.serverPassword, for: "\(id)/server")
        Keychain.setPassword(network.saslPassword, for: "\(id)/sasl")
        Keychain.setPassword(network.proxyPassword, for: "\(id)/proxy")
    }

    func deletePasswords(of network: NetworkConfig) {
        guard usesKeychain else { return }
        let id = network.id.uuidString
        Keychain.setPassword(nil, for: "\(id)/server")
        Keychain.setPassword(nil, for: "\(id)/sasl")
        Keychain.setPassword(nil, for: "\(id)/proxy")
    }
}

/// How a network is reached.
enum ProxyKind: String, Codable, CaseIterable, Sendable {
    case none, tor, ssh, socks

    var title: String {
        switch self {
        case .none: "None"
        case .tor: "Tor"
        case .ssh: "SSH tunnel"
        case .socks: "SOCKS5 proxy"
        }
    }
}
