import Foundation

/// One running copy of a script: its process, a line at a time in, a line
/// at a time out, and its standard error. Lines come to the main actor in
/// the order they were written.
@MainActor
final class ScriptRunner {
    let definition: ScriptDefinition
    let id = UUID()
    let started = Date.now
    private(set) var isRunning = false
    /// Stopped by Irctell, not of its own accord.
    private(set) var wasStopped = false

    var onLine: (String) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    /// The exit status, and whether Irctell stopped it.
    var onExit: (Int32, Bool) -> Void = { _, _ in }

    /// The longest line read; longer ones are dropped.
    static let maxLine = 64 * 1024

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    /// Writes go out in order, off the main thread: a script that does not
    /// read must not hold Irctell up.
    private let writer = DispatchQueue(label: "irctell.script.writer")
    private var inputClosed = false

    init(definition: ScriptDefinition) {
        self.definition = definition
    }

    enum StartError: LocalizedError {
        case noCommand, notFound(String)

        var errorDescription: String? {
            switch self {
            case .noCommand: "The script has no command."
            case .notFound(let program): "\(program) was not found or cannot be run."
            }
        }
    }

    /// The folders a program named without a path is looked for in: an app
    /// started from the Dock has few of them in its PATH.
    nonisolated static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    nonisolated static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
    }

    nonisolated static func resolve(_ program: String, path: String?) -> URL? {
        let program = expand(program)
        if program.contains("/") {
            return FileManager.default.isExecutableFile(atPath: program) ? URL(filePath: program) : nil
        }
        let folders = (path?.split(separator: ":").map(String.init) ?? []) + searchPath
        return folders.lazy.map { URL(filePath: $0).appending(path: program) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func start(arguments extra: [String], environment: [String: String]) throws {
        guard let program = definition.command.first else { throw StartError.noCommand }
        var variables = ProcessInfo.processInfo.environment
        let path = ([variables["PATH"]].compactMap { $0 } + ScriptRunner.searchPath).joined(separator: ":")
        variables["PATH"] = path
        variables.merge(environment) { _, new in new }
        variables.merge(definition.environment) { _, new in new }
        guard let executable = ScriptRunner.resolve(program, path: path) else { throw StartError.notFound(program) }
        process.executableURL = executable
        process.arguments = definition.command.dropFirst().map(ScriptRunner.expand) + extra
        process.environment = variables
        let directory = ScriptRunner.expand(definition.directory)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isFolder), isFolder.boolValue {
            process.currentDirectoryURL = URL(filePath: directory)
        } else {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let lines = LineReader(limit: ScriptRunner.maxLine) { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLine(line) } }
        } tooLong: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onError("a line longer than 64 KB was dropped") }
            }
        }
        let errorLines = LineReader(limit: ScriptRunner.maxLine) { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onError(line) } }
        } tooLong: {}
        output.fileHandleForReading.readabilityHandler = { handle in lines.feed(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { handle in errorLines.feed(handle.availableData) }
        process.terminationHandler = { [weak self, output, errors] process in
            // What is still in the pipes, then the end.
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            lines.feed((try? output.fileHandleForReading.readToEnd()) ?? Data())
            errorLines.feed((try? errors.fileHandleForReading.readToEnd()) ?? Data())
            lines.finish()
            errorLines.finish()
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isRunning = false
                    self.onExit(status, self.wasStopped)
                }
            }
        }
        try process.run()
        isRunning = true
    }

    /// A line to the script's standard input.
    func send(_ line: String) {
        guard isRunning, !inputClosed else { return }
        let data = Data((line.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        let handle = input.fileHandleForWriting
        writer.async { try? handle.write(contentsOf: data) }
    }

    /// No more input: a one-shot script reads to the end and finishes.
    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        let handle = input.fileHandleForWriting
        writer.async { try? handle.close() }
    }

    /// Stops it: its input closed, then terminated after `grace`, then
    /// killed after twice that.
    func stop(grace: Duration = .seconds(5)) {
        guard isRunning else { return }
        wasStopped = true
        closeInput()
        let pid = process.processIdentifier
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.isRunning else { return }
            self.process.terminate()
            try? await Task.sleep(for: grace)
            if self.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    /// Ends it now.
    func kill() {
        guard isRunning else { return }
        wasStopped = true
        process.terminate()
    }
}

/// Cuts bytes into lines; lines longer than the limit are dropped.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var skipping = false
    private let limit: Int
    private let line: (String) -> Void
    private let tooLong: () -> Void

    init(limit: Int, line: @escaping (String) -> Void, tooLong: @escaping () -> Void) {
        self.limit = limit
        self.line = line
        self.tooLong = tooLong
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let piece = pending[pending.startIndex..<newline]
            pending = Data(pending[(newline + 1)...])
            if skipping {
                skipping = false
                continue
            }
            var text = String(decoding: piece, as: UTF8.self)
            if text.hasSuffix("\r") { text.removeLast() }
            line(text)
        }
        if pending.count > limit {
            pending.removeAll()
            if !skipping { tooLong() }
            skipping = true
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty, !skipping { line(String(decoding: pending, as: UTF8.self)) }
        pending.removeAll()
    }
}
