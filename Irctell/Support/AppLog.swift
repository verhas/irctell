import Foundation
import Observation
import os

/// How much a log entry matters.
enum LogLevel: Int, Comparable, CaseIterable, Codable, Sendable {
    case debug, info, notice, warning, error

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Notice"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var symbol: String {
        switch self {
        case .debug: "ant"
        case .info: "info.circle"
        case .notice: "bell"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    var osType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .error
        case .error: .fault
        }
    }
}

struct AppLogEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    var time: Date
    var level: LogLevel
    /// What part of Irctell: "suggestions", "log", "settings", …
    var category: String
    var message: String

    /// As a line of the log file.
    var line: String {
        "\(time.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))) "
            + "\(level.title.uppercased()) [\(category)] \(message)"
    }
}

/// Irctell's own log, for when something does not work as it should: what
/// it did and why, kept in memory for the Irctell Log window, and in
/// ~/.irctell/irctell.log. Never the text of messages: they stay in the
/// message log only.
@MainActor @Observable
final class AppLog {
    static let shared = AppLog(fileURL: IrctellHome.isRunningTests ? nil : IrctellHome.directory.appending(path: "irctell.log"))

    /// The most kept in memory; the oldest go.
    static let keep = 5_000
    /// The file is started over, the old one kept as irctell.log.1, at this size.
    static let maxFileSize = 2 << 20

    private(set) var entries: [AppLogEntry] = []
    @ObservationIgnored let fileURL: URL?
    @ObservationIgnored private var file: FileHandle?
    @ObservationIgnored private var fileSize = 0

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Logs from anywhere: the entry is added on the main actor.
    nonisolated static func log(_ level: LogLevel, _ category: String, _ message: String) {
        Logger(subsystem: "dev.verhas.Irctell", category: category)
            .log(level: level.osType, "\(message, privacy: .public)")
        let entry = AppLogEntry(time: .now, level: level, category: category, message: message)
        Task { @MainActor in shared.add(entry) }
    }

    nonisolated static func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    nonisolated static func info(_ category: String, _ message: String) { log(.info, category, message) }
    nonisolated static func notice(_ category: String, _ message: String) { log(.notice, category, message) }
    nonisolated static func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    nonisolated static func error(_ category: String, _ message: String) { log(.error, category, message) }

    func add(_ entry: AppLogEntry) {
        entries.append(entry)
        if entries.count > AppLog.keep { entries.removeFirst(entries.count - AppLog.keep) }
        write(entry)
    }

    func clear() {
        entries.removeAll()
    }

    /// The categories that have entries, sorted.
    var categories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    private func write(_ entry: AppLogEntry) {
        guard let fileURL else { return }
        if file == nil {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            file = try? FileHandle(forWritingTo: fileURL)
            fileSize = Int((try? file?.seekToEnd()) ?? 0)
        }
        let data = Data((entry.line + "\n").utf8)
        try? file?.write(contentsOf: data)
        fileSize += data.count
        if fileSize > AppLog.maxFileSize {
            try? file?.close()
            file = nil
            let old = URL(filePath: fileURL.path + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: fileURL, to: old)
        }
    }
}
