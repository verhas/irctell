import AppKit
import Foundation
import Observation

/// The Profile menu: choosing another profile quits every network and
/// starts Irctell again with that profile's settings, networks and log;
/// creating and deleting them.
@MainActor @Observable
final class ProfileSwitcher {
    static let shared = ProfileSwitcher()

    /// The other profiles, by name, as last read from disk.
    private(set) var names: [String] = []
    /// The profile Irctell runs with; nil for the main one.
    let current = IrctellHome.profile
    /// Set when quitting to start again: the quit is not asked about again,
    /// and the app is started once this one has gone.
    @ObservationIgnored private(set) var relaunches = false
    @ObservationIgnored private var profiles = Profiles(root: IrctellHome.root)
    @ObservationIgnored private var observer: Any?

    private init() {
        refresh()
        // Profiles added or put back from the Trash in Finder.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { ProfileSwitcher.shared.refresh() } }
    }

    func refresh() {
        let found = profiles.names()
        if found != names { names = found }
    }

    // MARK: - Menu actions

    /// Nil for the main profile.
    func switchTo(_ name: String?, app: AppModel) {
        guard name != current else { return }
        guard confirmSwitch(to: name ?? Profiles.mainName, app: app) else { return }
        do {
            try profiles.choose(name)
        } catch {
            fail("Irctell cannot switch to the profile.", error)
            return
        }
        AppLog.info("profile", "Switching to the profile \(name ?? Profiles.mainName)")
        relaunches = true
        NSApplication.shared.terminate(nil)
    }

    func create(app: AppModel) {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "A profile has its own settings, networks, nicks, log and scripts. It starts empty."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create and Switch")
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        do {
            try profiles.create(name)
        } catch {
            fail("Irctell cannot create the profile.", error)
            return
        }
        refresh()
        if answer == .alertFirstButtonReturn { switchTo(name, app: app) }
    }

    func delete(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Move the profile “\(name)” to the Trash?"
        alert.informativeText = "Its settings, networks, log and scripts go with it. Finder's Put Back restores it, until the Trash is emptied."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try profiles.delete(name, inUse: current)
            AppLog.info("profile", "Moved the profile \(name) to the Trash")
        } catch {
            fail("Irctell cannot delete the profile.", error)
        }
        refresh()
    }

    func showInFinder() {
        let folder = current == nil ? profiles.folder : profiles.directory(of: current!)
        try? FileManager.default.createDirectory(at: profiles.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: - Starting again

    /// Starts this app once the process has gone: a shell waits for it, at
    /// most half a minute, then opens the app's bundle.
    func relaunchAfterExit() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", """
            for _ in $(seq 150); do /bin/kill -0 "$1" 2>/dev/null || break; sleep 0.2; done
            exec /usr/bin/open "$2"
            """, "irctell-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            AppLog.error("profile", "Irctell cannot start again: \(error.localizedDescription)")
        }
    }

    // MARK: - Asking

    private func confirmSwitch(to name: String, app: AppModel) -> Bool {
        let connected = app.sessions.filter { !$0.isOffline }.count
        let alert = NSAlert()
        alert.messageText = "Switch to the profile “\(name)”?"
        alert.informativeText = (connected == 0 ? "No network is connected."
            : connected == 1 ? "You will be disconnected from 1 network."
            : "You will be disconnected from \(connected) networks.")
            + " Irctell starts again with that profile's settings, networks and log."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func fail(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
