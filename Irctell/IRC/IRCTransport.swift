import Foundation
import Network
import os

/// A byte pipe to a server. The client only ever talks to this protocol, so
/// the tests can drive it with a scripted fake instead of a network.
protocol IRCTransport: Sendable {
    /// Connects, and returns the bytes the server sends. The stream finishes
    /// when the connection closes, throwing if it closed because of an error.
    func open() async throws -> AsyncThrowingStream<Data, Error>
    func send(_ data: Data) async throws
    /// Drops the connection; the stream from `open` then finishes.
    func close()
}

enum IRCTransportError: LocalizedError {
    case invalidPort(UInt16)
    case invalidProxyPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "\(port) is not a usable port"
        case .invalidProxyPort(let port): "\(port) is not a usable port for the proxy"
        }
    }
}

/// TCP, with or without TLS, over Network.framework.
final class NetworkTransport: IRCTransport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.verhas.Irctell.transport")

    init(host: String, port: UInt16, useTLS: Bool, allowInvalidCertificates: Bool, proxy: SOCKSProxy? = nil) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw IRCTransportError.invalidPort(port)
        }

        let tcp = NWProtocolTCP.Options()
        // Keepalives notice a dead peer on an otherwise idle connection, on
        // top of the client's own PING checks.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60

        var tls: NWProtocolTLS.Options?
        if useTLS {
            let options = NWProtocolTLS.Options()
            if allowInvalidCertificates {
                sec_protocol_options_set_verify_block(options.securityProtocolOptions,
                                                      { _, _, complete in complete(true) }, queue)
            }
            tls = options
        }

        if let proxy {
            guard let proxyPort = NWEndpoint.Port(rawValue: proxy.port), proxy.port != 0 else {
                throw IRCTransportError.invalidProxyPort(proxy.port)
            }
            // The certificate is checked against the server, not the proxy.
            if let tls {
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            }
            let parameters = NWParameters(tls: tls, tcp: tcp)
            // Below TLS: the proxy is asked for the server before TLS starts.
            // Tor puts each username on circuits of its own.
            let username = proxy.freshCircuitEachConnection
                ? "\(proxy.username ?? "irctell")-\(UInt32.random(in: .min ... .max))" : proxy.username
            parameters.defaultProtocolStack.applicationProtocols.append(
                SOCKS5Framer.options(host: host, port: port, username: username, password: proxy.password))
            connection = NWConnection(host: NWEndpoint.Host(proxy.host), port: proxyPort, using: parameters)
        } else {
            connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: NWParameters(tls: tls, tcp: tcp))
        }
    }

    convenience init(config: IRCServerConfig) throws {
        try self.init(host: config.host, port: config.port, useTLS: config.useTLS,
                      allowInvalidCertificates: config.allowInvalidCertificates, proxy: config.proxy)
    }

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        let (stream, incoming) = AsyncThrowingStream<Data, Error>.makeStream()
        // Set once the connect attempt has an outcome; every later state change
        // only concerns the stream.
        let settled = OSAllocatedUnfairLock(initialState: false)
        let settle: @Sendable () -> Bool = { settled.withLock { done in defer { done = true }; return !done } }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        if settle() { ready.resume() }
                    case .waiting(let error), .failed(let error):
                        // NWConnection waits and retries on its own when it
                        // cannot connect; the client has its own reconnect
                        // schedule, and the user should hear about the
                        // failure now rather than see it hang.
                        connection.cancel()
                        if settle() { ready.resume(throwing: error) }
                        incoming.finish(throwing: error)
                    case .cancelled:
                        if settle() { ready.resume(throwing: CancellationError()) }
                        incoming.finish()
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: { [connection] in
            connection.cancel()
        }

        receive(into: incoming)
        return stream
    }

    private func receive(into incoming: AsyncThrowingStream<Data, Error>.Continuation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { incoming.yield(data) }
            if let error {
                incoming.finish(throwing: error)
            } else if isComplete {
                incoming.finish()
            } else {
                self?.receive(into: incoming)
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { sent.resume(throwing: error) } else { sent.resume() }
            })
        }
    }

    func close() {
        connection.cancel()
    }
}
