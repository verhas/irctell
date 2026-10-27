import Foundation

/// SSH tunnels, for the networks set to go through one: `ssh -D`, a SOCKS5
/// proxy on this Mac that leaves from the SSH server. Opened when the first
/// network using it connects, again whenever it has died -- sleep or a
/// changed network ends it -- and closed when Irctell quits.
@MainActor
final class SSHTunnelService {
    static let shared = SSHTunnelService()

    nonisolated static let host = "127.0.0.1"

    /// The tunnels Irctell opened, by local port.
    private var tunnels: [UInt16: (destination: String, process: Process)] = [:]
    private var opening: [UInt16: Task<Void, Error>] = [:]

    enum TunnelError: LocalizedError {
        case noDestination, portTaken(UInt16, String), failed(String), noAnswer(UInt16)

        var errorDescription: String? {
            switch self {
            case .noDestination: "No SSH server is set for the tunnel."
            case .portTaken(let port, let destination):
                "Port \(port) is taken by Irctell's tunnel to \(destination); give each SSH server a port of its own."
            case .failed(let output): "ssh: \(output)"
            case .noAnswer(let port): "ssh started, but nothing answers on 127.0.0.1:\(port)."
            }
        }
    }

    /// Whether Irctell's tunnel to the destination is up on the port.
    func isOpen(to destination: String, port: UInt16) -> Bool {
        guard let tunnel = tunnels[port] else { return false }
        return tunnel.destination == destination && tunnel.process.isRunning
    }

    /// Returns once the tunnel takes connections; opens it first when it is
    /// not open. Several networks connecting at once share one opening.
    func ensureOpen(to destination: String, port: UInt16) async throws {
        if let opening = opening[port] { return try await opening.value }
        let task = Task { try await open(to: destination, port: port) }
        opening[port] = task
        defer { opening[port] = nil }
        try await task.value
    }

    private func open(to destination: String, port: UInt16) async throws {
        let destination = destination.trimmingCharacters(in: .whitespaces)
        guard !destination.isEmpty, !destination.hasPrefix("-") else { throw TunnelError.noDestination }
        if let tunnel = tunnels[port], tunnel.process.isRunning {
            guard tunnel.destination == destination else { throw TunnelError.portTaken(port, tunnel.destination) }
            if await TorService.isListening(host: SSHTunnelService.host, port: port) { return }
            tunnel.process.terminate() // up, but not forwarding: start over
        }
        tunnels[port] = nil

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = SSHTunnelService.arguments(destination: destination, port: port)
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let output = OutputCollector()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { output.append(data) }
        }
        do {
            try process.run()
        } catch {
            throw TunnelError.failed(error.localizedDescription)
        }
        tunnels[port] = (destination, process)

        // Long enough to log in to a slow server; ConnectTimeout gives up sooner
        // on one that does not answer.
        for _ in 0..<80 {
            if !process.isRunning {
                tunnels[port] = nil
                try? await Task.sleep(for: .milliseconds(100)) // the last of what it said
                throw TunnelError.failed(output.lastLine ?? "exited with status \(process.terminationStatus)")
            }
            if await TorService.isListening(host: SSHTunnelService.host, port: port) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        process.terminate()
        tunnels[port] = nil
        throw TunnelError.noAnswer(port)
    }

    /// At quit: closes every tunnel Irctell opened.
    func closeAll() {
        for tunnel in tunnels.values where tunnel.process.isRunning {
            tunnel.process.terminate()
        }
        tunnels = [:]
    }

    /// No prompts: a key, from the agent or the keychain, logs in, and a
    /// server not seen before is trusted the first time and checked after.
    /// The user's ~/.ssh/config applies, so a Host alias works.
    nonisolated static func arguments(destination: String, port: UInt16) -> [String] {
        ["-N", "-D", "\(host):\(port)",
         "-o", "BatchMode=yes",
         "-o", "ExitOnForwardFailure=yes",
         "-o", "StrictHostKeyChecking=accept-new",
         "-o", "ConnectTimeout=20",
         "-o", "ServerAliveInterval=30",
         "-o", "ServerAliveCountMax=3",
         "--", destination]
    }
}

/// What ssh writes to its standard error, collected as it comes.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ more: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(more)
    }

    /// The last line that says something; ssh puts the reason it gave up there.
    var lastLine: String? {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
    }
}
