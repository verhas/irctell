import Foundation

/// Everything needed to connect to and register on one network.
struct IRCServerConfig: Sendable, Hashable {
    var host: String
    var port: UInt16 = 6697
    var useTLS = true
    /// For servers with self-signed certificates. Off by default, and it should
    /// stay off for any network reached over the internet.
    var allowInvalidCertificates = false
    /// A SOCKS5 proxy the connection goes through: Tor, or `ssh -D`.
    var proxy: SOCKSProxy?

    var nick: String
    /// Tried in order when the nick is taken; after them, `_` is appended.
    var alternateNicks: [String] = []
    var username: String
    var realName: String

    /// The PASS sent before registration; bouncers use it to log in.
    var serverPassword: String?
    var sasl: SASLCredentials?

    var timeouts = IRCTimeouts()
    /// Whether the client answers CTCP queries itself; off when the app
    /// answers them, knowing whom it ignores and what it may tell.
    var answersCTCP = true

    init(host: String, port: UInt16 = 6697, useTLS: Bool = true, nick: String,
         username: String? = nil, realName: String? = nil) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.nick = nick
        self.username = username ?? nick
        self.realName = realName ?? nick
    }
}

/// A SOCKS5 proxy. The server's name is handed to it, not looked up here:
/// a .onion address can only be resolved by Tor, and a lookup here would
/// tell the local DNS server where the connection goes.
struct SOCKSProxy: Sendable, Hashable {
    var host: String
    var port: UInt16
    /// Tor keeps the connections of each username apart, on their own
    /// circuits; other proxies may need a login.
    var username: String?
    var password: String?
    /// Tor: every connection attempt on a circuit of its own, so a retry
    /// leaves from another exit relay -- servers often refuse some of them.
    var freshCircuitEachConnection = false
}

struct SASLCredentials: Sendable, Hashable {
    var account: String
    var password: String
}

struct IRCTimeouts: Sendable, Hashable {
    /// Silence from the server before the client sends a PING of its own.
    var idleBeforePing: Duration = .seconds(120)
    /// How long that PING may go unanswered before the connection is
    /// considered dead and dropped -- TCP alone can take many minutes to
    /// notice a vanished peer.
    var pingReply: Duration = .seconds(60)
    /// First wait before reconnecting; it doubles per failed attempt.
    var reconnectInitial: Duration = .seconds(2)
    var reconnectMaximum: Duration = .seconds(300)
    /// Outgoing flood control: servers disconnect a client that sends too
    /// fast. A burst of five lines, then one every two seconds.
    var floodLineInterval: Duration = .seconds(2)
    var floodBurst: Duration = .seconds(10)
}
