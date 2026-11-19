import AppKit
import Darwin

/// Only one Irctell at a time on an Irctell home, whichever copy of the app
/// it is: two would log in to the same networks with the same nicks, take
/// the nick back from each other in a loop, and write the same log. The
/// installed app and a development build share `~/.irctell`, so this is a
/// lock on a file there rather than anything macOS keeps per app.
///
/// The lock goes with the process, so a crash or a kill releases it too.
/// It covers every profile of the home: profiles share the keychain and
/// the voices. A trial home (IRCTELL_HOME) has a lock of its own.
@MainActor
enum SingleInstance {
    /// Who holds the lock, as it wrote itself into the file.
    struct Holder: Equatable, Sendable {
        var pid: pid_t
        var path: String
    }

    enum Outcome: Equatable, Sendable {
        /// The lock is ours while the descriptor stays open.
        case acquired(descriptor: Int32)
        /// Another process has it; nil when it has not written who it is yet.
        case held(by: Holder?)
        /// No lock file could be opened; better to run than to refuse.
        case unavailable(errno: Int32)
    }

    nonisolated static let fileName = "irctell.lock"

    /// Kept open for the life of the process: closing it gives the lock up.
    private static var descriptor: Int32 = -1

    /// Takes the lock at launch, before the log or the settings are opened.
    /// When another Irctell has it, says so, brings that one to the front and
    /// ends this process.
    static func claimOrQuit() {
        guard !IrctellHome.isRunningTests else { return }
        let url = IrctellHome.root.appending(path: fileName)
        switch lock(at: url) {
        case .acquired(let fd):
            descriptor = fd
        case .unavailable(let code):
            // AppLog is not open yet; the system log still gets it.
            AppLog.warning("app", "No single-instance lock at \(url.path): \(String(cString: strerror(code)))")
        case .held(let holder):
            refuse(holder: holder)
        }
    }

    /// Opens or creates the lock file and takes the lock without waiting.
    /// On success the file names this process, for the one turned away.
    nonisolated static func lock(at url: URL,
                                 pid: pid_t = getpid(),
                                 path: String = Bundle.main.bundlePath) -> Outcome {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .unavailable(errno: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return .held(by: holder(at: url)) }
            return .unavailable(errno: code)
        }
        let text = "\(pid)\n\(path)\n"
        ftruncate(fd, 0)
        _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
        return .acquired(descriptor: fd)
    }

    nonisolated static func holder(at url: URL) -> Holder? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, let pid = pid_t(lines[0]), pid > 0 else { return nil }
        return Holder(pid: pid, path: String(lines[1]))
    }

    private static func refuse(holder: Holder?) {
        let home = IrctellHome.root.path
        let user = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = home.hasPrefix(user + "/") ? "~" + home.dropFirst(user.count) : home
        let running = holder.map { "\n\nRunning: \($0.path) (process \($0.pid))" } ?? ""
        AppLog.warning("app", "Not starting: another Irctell uses \(shown)\(holder.map { ", process \($0.pid), \($0.path)" } ?? "")")

        NSApplication.shared.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Irctell is already running"
        alert.informativeText = "Only one Irctell can use \(shown) at a time: two would log in to the same networks with the same nicks and push each other off. This one quits; the one running comes to the front.\(running)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
        if let holder {
            NSRunningApplication(processIdentifier: holder.pid)?.activate()
        }
        exit(0)
    }
}
