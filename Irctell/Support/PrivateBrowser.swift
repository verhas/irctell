import AppKit

/// Opens a link in a private window: no history, no cookies of the user's.
/// Browsers that take a private window on the command line are told so;
/// Safari takes none, so it is the last choice, through a ⇧⌘N.
enum PrivateBrowser {
    struct Browser {
        var name: String
        var bundleID: String
        /// The command-line option for a private window; nil for Safari.
        var option: String?
    }

    private static let capable = [
        Browser(name: "Firefox", bundleID: "org.mozilla.firefox", option: "--private-window"),
        Browser(name: "Chrome", bundleID: "com.google.Chrome", option: "--incognito"),
        Browser(name: "Brave", bundleID: "com.brave.Browser", option: "--incognito"),
        Browser(name: "Edge", bundleID: "com.microsoft.edgemac", option: "--inprivate"),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", option: "--incognito"),
        Browser(name: "Opera", bundleID: "com.operasoftware.Opera", option: "--private"),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", option: "--incognito"),
    ]
    private static let safari = Browser(name: "Safari", bundleID: "com.apple.Safari", option: nil)

    /// The default browser when it can open a private window, or else the
    /// first installed one that can, or Safari.
    static var browser: Browser? {
        let workspace = NSWorkspace.shared
        let defaultID = workspace.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        if let defaultID, let match = capable.first(where: { $0.bundleID == defaultID }) { return match }
        if let installed = capable.first(where: { workspace.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }) {
            return installed
        }
        return workspace.urlForApplication(withBundleIdentifier: safari.bundleID) == nil ? nil : safari
    }

    /// Nil when it went; otherwise why not.
    @discardableResult
    static func open(_ url: URL) -> String? {
        guard let browser else { return "No browser found." }
        guard let option = browser.option else { return openInSafari(url) }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            return "\(browser.name) is not installed."
        }
        // Through `open -n`: arguments given to a browser already running get
        // to it this way, which NSWorkspace does not do.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-na", app.path, "--args", option, url.absoluteString]
        do {
            try process.run()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Safari's private window is ⇧⌘N, and nothing else; macOS asks the user
    /// once to let Irctell control Safari and System Events.
    private static func openInSafari(_ url: URL) -> String? {
        let link = url.absoluteString.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application "Safari" to activate
            tell application "System Events" to keystroke "n" using {command down, shift down}
            delay 0.5
            tell application "Safari" to set URL of front document to "\(link)"
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error.map { "Safari: \($0[NSAppleScript.errorMessage] ?? "could not open a private window")" }
    }
}
