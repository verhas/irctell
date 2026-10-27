import SwiftUI

@main
struct IrctellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        // One window: networks are tabs inside it, not windows of their own.
        Window(IrctellApp.title, id: IrctellApp.mainWindowID) {
            RootView()
                .environment(app)
                .onAppear {
                    delegate.app = app
                    app.start()
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands { IrctellCommands(app: app) }

        Window("Networks", id: NetworkListView.windowID) {
            NetworkListView()
                .environment(app)
        }
        .defaultSize(width: 720, height: 520)

        Window("Mentions", id: MentionsView.windowID) {
            MentionsView()
                .environment(app)
        }
        .defaultSize(width: 680, height: 520)

        Window("Channel List", id: ChannelListWindow.windowID) {
            ChannelListWindow()
                .environment(app)
        }
        .defaultSize(width: 760, height: 560)

        Window("Auto Replies", id: AutoReplyEditor.windowID) {
            AutoReplyEditor()
        }
        .defaultSize(width: 620, height: 680)

        Window("Backup and Transfer", id: TransferView.windowID) {
            TransferView()
                .environment(app)
        }
        .defaultSize(width: 600, height: 560)

        Window("Irctell Log", id: AppLogView.windowID) {
            AppLogView()
        }
        .defaultSize(width: 820, height: 460)

        Window("Scripts", id: ScriptsView.windowID) {
            ScriptsView()
        }
        .defaultSize(width: 900, height: 680)

        Window("Nick Actions", id: NickActionEditor.windowID) {
            NickActionEditor()
        }
        .defaultSize(width: 640, height: 560)

        Window("Spoken Abbreviations", id: AbbreviationEditor.windowID) {
            AbbreviationEditor()
        }
        .defaultSize(width: 540, height: 640)

        Settings {
            SettingsView()
        }
    }

    static let mainWindowID = "main"
    /// The profile is named, so it is clear whose identity is in use.
    static var title: String { IrctellHome.profile.map { "Irctell — \($0)" } ?? "Irctell" }
}

/// Sends QUIT on every network before the app goes, so others see a proper
/// "quit" rather than a connection timing out minutes later.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var app: AppModel?
    private var keyMonitor: Any?

    /// ⌥Tab and ⌥↑/⌥↓ in the main window, wherever the focus is, and ⌘←/⌘→
    /// for the network tab in front. As menu shortcuts they do not arrive:
    /// the text field and the window's key view loop take Tab and the arrows
    /// first. ⌘← and ⌘→ no longer go to the start and end of the input line
    /// then; ⌃A and ⌃E still do.
    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Arrows also carry the function-key flag: only these four count.
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let switchesNetwork = modifiers == .command && [123, 124].contains(event.keyCode)
            guard switchesNetwork || (modifiers == .option && [48, 125, 126].contains(event.keyCode)),
                  event.window?.identifier?.rawValue == IrctellApp.mainWindowID else { return event }
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                if switchesNetwork {
                    guard let app = self?.app, app.sessions.count > 1 else { return false }
                    app.selectSession(offset: keyCode == 123 ? -1 : 1) // ← or →
                    return true
                }
                if keyCode == 48 { // Tab
                    self?.app?.unseenOrBack()
                    return self?.app != nil
                }
                guard let session = self?.app?.selectedSession else { return false }
                switch keyCode {
                case 126: session.selectUnreadBuffer(offset: -1) // ↑
                default: session.selectUnreadBuffer(offset: 1) // ↓
                }
                return true
            }
            return handled ? nil : event
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let relaunches = ProfileSwitcher.shared.relaunches
        guard let app else {
            if relaunches { ProfileSwitcher.shared.relaunchAfterExit() }
            return .terminateNow
        }
        // Switching profiles asked already.
        if !relaunches, !isSystemQuit, app.settings.bool(forKey: GeneralSettingsKeys.confirmQuit, default: true),
           !confirmQuit(app) {
            return .terminateCancel
        }
        Task { @MainActor in
            // Not waiting for ever on a server that does not answer.
            let quit = Task { await app.shutDown() }
            let deadline = Task { try? await Task.sleep(for: .seconds(2)) }
            _ = await (quit.value, deadline.value)
            if relaunches { ProfileSwitcher.shared.relaunchAfterExit() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Logging out, restarting or shutting down: the system asks, not us.
    private var isSystemQuit: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    @MainActor private func confirmQuit(_ app: AppModel) -> Bool {
        let connected = app.sessions.filter { !$0.isOffline }.count
        let alert = NSAlert()
        alert.messageText = "Quit Irctell?"
        alert.informativeText = connected == 0 ? "No network is connected."
            : connected == 1 ? "You will be disconnected from 1 network."
            : "You will be disconnected from \(connected) networks."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on {
            app.settings.set(false, forKey: GeneralSettingsKeys.confirmQuit)
        }
        return quit
    }
}

struct IrctellCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    private func openTransfer(_ tab: TransferTab) {
        app.transferTab = tab
        openWindow(id: TransferView.windowID)
    }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            ProfileMenu(app: app)
        }
        CommandGroup(after: .newItem) {
            Button("Networks…") { openWindow(id: NetworkListView.windowID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(before: .windowList) {
            Button("Irctell Log") { openWindow(id: AppLogView.windowID) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(after: .importExport) {
            Button("Export Logs and Settings…") { openTransfer(.export) }
            Button("Import Logs and Settings…") { openTransfer(.import) }
            Button("Back Up Log Database…") { openTransfer(.backup) }
        }
        CommandMenu("Network") {
            Button("Connect") { app.selectedSession?.connect() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(app.selectedSession == nil)
            Button("Disconnect") { app.selectedSession?.disconnect() }
                .disabled(app.selectedSession?.isOffline ?? true)
            Button("Close Tab") {
                if let session = app.selectedSession { app.closeTab(session) }
            }
            .disabled(app.selectedSession == nil)
            Button(app.isAwaySomewhere ? "Back on Every Network" : "Away on Every Network") {
                if app.isAwaySomewhere { app.comeBackEverywhere() } else { app.goAwayEverywhere() }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            Button(Speaker.shared.isMuted ? "Unmute" : "Mute") { Speaker.shared.isMuted.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .control])
            Button("Skip Message Being Read") { Speaker.shared.skip() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(!Speaker.shared.isSpeaking)
            Button("Unread Private Chat") { app.showOldestUnseenPrivateChat() }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(app.unseenPrivateChats.isEmpty)
            Button("Mentions") { openWindow(id: MentionsView.windowID) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Auto Replies…") { openWindow(id: AutoReplyEditor.windowID) }
            Button("Nick Actions…") { openWindow(id: NickActionEditor.windowID) }
            Button("Scripts…") { openWindow(id: ScriptsView.windowID) }
            let menuScripts = ScriptHost.shared.scripts.filter { $0.enabled && $0.triggers.contains { $0.on == "menu" } }
            if !menuScripts.isEmpty {
                Menu("Run Script") {
                    ForEach(menuScripts) { script in
                        Button(script.name) { ScriptHost.shared.runFromMenu(script.id) }
                    }
                }
            }
            Button("Spoken Abbreviations…") { openWindow(id: AbbreviationEditor.windowID) }
            Button("Channel List…") { app.selectedSession?.showsChannelList = true }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(app.selectedSession == nil)
            Button("Edit Network…") {
                if let session = app.selectedSession { app.beginEditing(session) }
            }
            .keyboardShortcut(",", modifiers: [.command, .option])
            .disabled(app.selectedSession == nil)
            Divider()
            Button("Next Network") { app.selectSession(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Network") { app.selectSession(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Next Conversation") { app.selectedSession?.selectBuffer(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Previous Conversation") { app.selectedSession?.selectBuffer(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Next Unread Conversation") { app.selectedSession?.selectUnreadBuffer(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Previous Unread Conversation") { app.selectedSession?.selectUnreadBuffer(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button(app.unseenPrivateChats.isEmpty ? "Back to Last Conversation" : "Unread Private Chat") {
                app.unseenOrBack()
            }
            .keyboardShortcut(.tab, modifiers: .option)
            Divider()
            ForEach(Array(app.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
                Button(session.displayName) { app.selectSession(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}

/// Irctell › Profile: the profiles to switch to, and making and deleting them.
struct ProfileMenu: View {
    let app: AppModel
    private var switcher: ProfileSwitcher { .shared }

    var body: some View {
        Menu("Profile") {
            profile(nil)
            ForEach(switcher.names, id: \.self) { profile($0) }
            Divider()
            Button("New Profile…") { switcher.create(app: app) }
            let deletable = switcher.names.filter { $0 != switcher.current }
            Menu("Delete Profile") {
                ForEach(deletable, id: \.self) { name in
                    Button("\(name)…") { switcher.delete(name) }
                }
            }
            .disabled(deletable.isEmpty)
            Button("Show Profiles in Finder") { switcher.showInFinder() }
        }
    }

    /// Ticked when in use; nil for the main profile.
    private func profile(_ name: String?) -> some View {
        Toggle(name ?? Profiles.mainName, isOn: Binding(
            get: { switcher.current == name },
            set: { if $0 { switcher.switchTo(name, app: app) } }))
    }
}
