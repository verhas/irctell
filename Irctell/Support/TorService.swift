import Foundation
import Network

/// Tor, for the networks set to go through it: started with Homebrew when
/// the first of them connects, unless it is running already, and stopped
/// when Irctell quits -- only if Irctell started it.
@MainActor
final class TorService {
    static let shared = TorService()

    nonisolated static let host = "127.0.0.1"
    nonisolated static let port: UInt16 = 9050

    /// Whether Irctell started it, so it stops it at the end.
    private(set) var startedHere = false
    private var starting: Task<Void, Error>?

    enum TorError: LocalizedError {
        case noHomebrew, notInstalled, failedToStart(String), noAnswer

        var errorDescription: String? {
            switch self {
            case .noHomebrew: "Homebrew is not installed, and Tor is not running on 127.0.0.1:9050."
            case .notInstalled: "Tor is not installed: in Terminal, brew install tor"
            case .failedToStart(let output): "brew services could not start Tor: \(output)"
            case .noAnswer: "Tor was started but does not answer on 127.0.0.1:9050."
            }
        }
    }

    /// Returns once Tor takes connections; starts it first when it does not.
    /// Several networks connecting at once share one start.
    func ensureRunning() async throws {
        if let starting { return try await starting.value }
        let task = Task { try await start() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func start() async throws {
        if await TorService.isListening() { return }
        guard let brew = TorService.brew else { throw TorError.noHomebrew }
        let prefix = brew.deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.isExecutableFile(atPath: prefix.appending(path: "bin/tor").path) else {
            throw TorError.notInstalled
        }
        // "run", not "start": now, and not again at every login.
        let (status, output) = await TorService.run(brew, ["services", "run", "tor"])
        guard status == 0 else { throw TorError.failedToStart(output) }
        startedHere = true
        for _ in 0..<60 {
            if await TorService.isListening() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TorError.noAnswer
    }

    /// At quit: stops Tor if Irctell started it. Waits for brew, briefly.
    func stopIfStartedHere() {
        guard startedHere, let brew = TorService.brew else { return }
        startedHere = false
        let process = Process()
        process.executableURL = brew
        process.arguments = ["services", "stop", "tor"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Homebrew, where it installs itself on Apple silicon or Intel.
    nonisolated static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map { URL(filePath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated private static func run(_ tool: URL, _ arguments: [String]) async -> (Int32, String) {
        await Task.detached {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    /// Whether something takes connections on Tor's port, or another.
    nonisolated static func isListening(host: String = host, port: UInt16 = port) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let answered = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if answered.claim() { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .waiting, .cancelled:
                    if answered.claim() { continuation.resume(returning: false) }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if answered.claim() { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }
}

/// True the first time it is claimed, false after.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
