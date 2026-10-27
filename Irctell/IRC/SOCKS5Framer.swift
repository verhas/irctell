import Foundation
import Network

/// SOCKS5 (RFC 1928, with the login of RFC 1929) as a layer between TCP and
/// TLS: the connection goes to the proxy, this asks it for the server, and
/// then steps aside, so TLS runs end to end with the server.
///
/// macOS's own SOCKS support refuses .onion names, so Tor's onion services
/// need this. The server's name always goes to the proxy as a name, never
/// looked up here: no DNS query tells the local network where it goes.
final class SOCKS5Framer: NWProtocolFramerImplementation, @unchecked Sendable {
    static let definition = NWProtocolFramer.Definition(implementation: SOCKS5Framer.self)
    static var label: String { "SOCKS5" }

    /// The options for one connection: where the proxy should connect to.
    static func options(host: String, port: UInt16, username: String?, password: String?) -> NWProtocolFramer.Options {
        let options = NWProtocolFramer.Options(definition: definition)
        options["host"] = host
        options["port"] = port
        options["username"] = username
        options["password"] = password
        return options
    }

    private enum Stage { case method, login, connect, done }
    private var stage = Stage.method
    private let host: String
    private let port: UInt16
    private let username: String?
    private let password: String?

    required init(framer: NWProtocolFramer.Instance) {
        let options = framer.options
        host = options["host"] as? String ?? ""
        port = options["port"] as? UInt16 ?? 0
        let user = options["username"] as? String
        username = user?.isEmpty == false ? user : nil
        password = options["password"] as? String
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        // Version 5; no login, or a username and password.
        framer.writeOutput(data: Data(username == nil ? [5, 1, 0] : [5, 2, 0, 2]))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while stage != .done {
            var needed = 0
            var reply: [UInt8]?
            let minimum = stage == .connect ? 5 : 2
            _ = framer.parseInput(minimumIncompleteLength: minimum, maximumLength: 512) { buffer, _ in
                guard let buffer, buffer.count >= minimum else { return 0 }
                let bytes = [UInt8](buffer)
                var length = 2
                if stage == .connect {
                    // VER REP RSV ATYP, the bound address, the port.
                    let address = switch bytes[3] {
                    case 1: 4
                    case 4: 16
                    default: 1 + Int(bytes[4])
                    }
                    length = 4 + address + 2
                }
                guard bytes.count >= length else {
                    needed = length
                    return 0
                }
                reply = Array(bytes.prefix(length))
                return length
            }
            guard let reply else { return max(needed, minimum) }
            switch stage {
            case .method:
                switch reply[1] {
                case 0: sendConnect(framer)
                case 2 where username != nil: sendLogin(framer)
                default: return fail(framer, .EACCES) // it wants a login we do not have
                }
            case .login:
                guard reply[1] == 0 else { return fail(framer, .EACCES) }
                sendConnect(framer)
            case .connect:
                guard reply[1] == 0 else { return fail(framer, SOCKS5Framer.error(forReply: reply[1])) }
                stage = .done
                framer.markReady()
                framer.passThroughInput()
                framer.passThroughOutput()
            case .done:
                break
            }
        }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int,
                      isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    private func sendLogin(_ framer: NWProtocolFramer.Instance) {
        let user = Array((username ?? "").utf8.prefix(255))
        let pass = Array((password ?? "").utf8.prefix(255))
        framer.writeOutput(data: Data([1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass))
        stage = .login
    }

    /// CONNECT, by name: ATYP 3.
    private func sendConnect(_ framer: NWProtocolFramer.Instance) {
        let name = Array(host.utf8.prefix(255))
        framer.writeOutput(data: Data([5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)]))
        stage = .connect
    }

    private func fail(_ framer: NWProtocolFramer.Instance, _ code: POSIXErrorCode) -> Int {
        stage = .done
        framer.markFailed(error: .posix(code))
        return 0
    }

    /// The proxy's refusal, as the closest system error, so the user reads
    /// "Connection refused" or "Host is unreachable".
    static func error(forReply reply: UInt8) -> POSIXErrorCode {
        switch reply {
        case 2: .EACCES // not allowed by the proxy's rules
        case 3: .ENETUNREACH
        case 4: .EHOSTUNREACH
        case 5: .ECONNREFUSED
        case 6: .ETIMEDOUT
        default: .ECONNABORTED
        }
    }
}
