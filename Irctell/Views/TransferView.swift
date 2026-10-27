import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which side of the Backup and Transfer window is shown.
enum TransferTab: String, Hashable {
    case export, `import`, backup
}

/// Export and import of the log and the settings as a zip of JSON Lines,
/// and a backup copy of the log database.
struct TransferView: View {
    static let windowID = "transfer"

    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.transferTab) {
            ExportPane()
                .tabItem { Text("Export") }
                .tag(TransferTab.export)
            ImportPane()
                .tabItem { Text("Import") }
                .tag(TransferTab.import)
            BackupPane()
                .tabItem { Text("Database Backup") }
                .tag(TransferTab.backup)
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 560)
    }

    static func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static var today: String {
        Date.now.formatted(.iso8601.year().month().day())
    }
}

/// A list of parts to tick, with how many of each.
private struct PartChecklist: View {
    let parts: [ArchivePart]
    let counts: [ArchivePart: Int]
    @Binding var chosen: Set<ArchivePart>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parts) { part in
                Toggle(isOn: Binding(get: { chosen.contains(part) },
                                     set: { if $0 { chosen.insert(part) } else { chosen.remove(part) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(part.title)
                            if let count = counts[part] {
                                Text(count.formatted())
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(part.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Running, then done or failed.
private enum WorkState {
    case idle, working(String), done(String), failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

private struct StateLine: View {
    let state: WorkState
    var reveal: URL?

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            }
        case .done(let text):
            HStack {
                Label(text, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                if let reveal {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                }
            }
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ExportPane: View {
    @Environment(AppModel.self) private var app
    @State private var chosen = Set(ArchivePart.allCases)
    @State private var counts: [ArchivePart: Int] = [:]
    @State private var state = WorkState.idle
    @State private var written: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A zip of JSON Lines: one file per conversation, readable with any text editor, and taken back by Import on this Mac or another. Passwords are never in it: they stay in the keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                PartChecklist(parts: ArchivePart.allCases, counts: counts, chosen: $chosen)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            StateLine(state: state, reveal: written)
            HStack {
                Spacer()
                Button("Export…", action: export)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || state.isWorking)
            }
        }
        .padding(8)
        .task { await loadCounts() }
    }

    private func loadCounts() async {
        var counts: [ArchivePart: Int] = [.networks: app.networks.count, .sounds: AppModel.soundFileCount()]
        for (part, values) in app.settingsByPart() { counts[part] = values.count }
        self.counts = counts
        guard let path = app.log?.fileURL.path else { return }
        let logged = await Task.detached { () -> (Int, Int)? in
            guard let db = try? SQLiteDatabase(path: path, readOnly: true) else { return nil }
            func count(_ sql: String) -> Int {
                Int((try? db.query(sql) { SQLiteDatabase.int64($0, 0) })?.first ?? 0)
            }
            return (count("SELECT count(*) FROM lines"), count("SELECT count(*) FROM media WHERE data IS NOT NULL"))
        }.value
        if let logged {
            self.counts[.messages] = logged.0
            self.counts[.pictures] = logged.1
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Irctell Export \(TransferView.today).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let input = app.exportInput(parts: chosen)
        state = .working("Starting…")
        written = nil
        Task {
            do {
                let manifest = try await Task.detached(priority: .userInitiated) {
                    try LogArchive.export(input, to: url) { text in
                        Task { @MainActor in state = .working(text) }
                    }
                }.value
                let lines = manifest.contents[ArchivePart.messages.rawValue]
                state = .done("Exported\(lines.map { " \($0.formatted()) messages" } ?? ""): \(url.lastPathComponent), \(TransferView.fileSize(url))")
                written = url
            } catch {
                state = .failed("Not exported: \(error.localizedDescription)")
            }
        }
    }
}

private struct ImportPane: View {
    @Environment(AppModel.self) private var app
    @State private var archive: LogArchive.Unpacked?
    @State private var archiveName = ""
    @State private var chosen = Set<ArchivePart>()
    @State private var state = WorkState.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adds an export to what is here. Messages already in the log are skipped, so importing the same file twice changes nothing. Networks you have are kept as they are; missing ones are added, without passwords. The settings of a part you tick replace yours.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose Export…", action: choose)
                    .disabled(state.isWorking)
                if let archive {
                    Text("\(archiveName) — \(archive.manifest.app), \(archive.manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let archive {
                ScrollView {
                    PartChecklist(parts: ArchivePart.allCases.filter { archive.available[$0] != nil },
                                  counts: archive.available, chosen: $chosen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
            }
            StateLine(state: state)
            HStack {
                Spacer()
                Button("Import", action: runImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(archive == nil || chosen.isEmpty || state.isWorking)
            }
        }
        .padding(8)
        .onDisappear {
            if !state.isWorking { archive?.cleanUp() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archive?.cleanUp()
        archive = nil
        state = .working("Opening \(url.lastPathComponent)…")
        Task {
            do {
                let unpacked = try await Task.detached(priority: .userInitiated) { try LogArchive.unpack(url) }.value
                archive = unpacked
                archiveName = url.lastPathComponent
                chosen = Set(unpacked.available.keys)
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func runImport() {
        guard let archive else { return }
        let parts = chosen
        state = .working("Importing…")
        Task {
            do {
                let result = try await app.importArchive(archive, parts: parts) { text in
                    Task { @MainActor in state = .working(text) }
                }
                state = .done(summary(result, parts: parts))
            } catch {
                state = .failed("Not imported: \(error.localizedDescription)")
            }
        }
    }

    private func summary(_ result: ArchiveImportResult, parts: Set<ArchivePart>) -> String {
        var said: [String] = []
        if parts.contains(.messages) {
            said.append("\(result.linesAdded.formatted()) messages added, \(result.linesAlreadyThere.formatted()) already there")
        }
        if parts.contains(.pictures) { said.append("\(result.picturesAdded.formatted()) pictures") }
        if !result.networksAdded.isEmpty {
            said.append("networks added: \(result.networksAdded.joined(separator: ", ")) — set their passwords in Edit Network")
        }
        if result.settingsImported > 0 {
            said.append("\(result.settingsImported) settings; some take effect when Irctell starts again")
        }
        if parts.contains(.sounds) { said.append("\(result.soundsAdded) sounds") }
        return "Imported: " + said.joined(separator: "; ") + "."
    }
}

private struct BackupPane: View {
    @Environment(AppModel.self) private var app
    @State private var state = WorkState.idle
    @State private var written: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("An exact copy of the log database, pictures included, for when the disk fails or the log is damaged. Taken while Irctell runs, as of one moment. Restoring it replaces the whole log; for adding to a log, use Export and Import.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back Up Log Database…", action: backUp)
                    .disabled(app.log == nil || state.isWorking)
                Button("Restore from Backup…", action: restore)
                    .disabled(state.isWorking)
            }
            Text("Restoring quits Irctell; the backup takes the log's place when it starts again. The log it replaces is kept beside it in \(IrctellHome.displayPath), renamed “before-restore”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            StateLine(state: state, reveal: written)
        }
        .padding(8)
    }

    private func backUp() {
        guard let source = app.log?.fileURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.nameFieldStringValue = "Irctell Log \(TransferView.today).sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state = .working("Copying the log…")
        written = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try LogStore.backUp(source, to: url) }.value
                state = .done("Backed up: \(url.lastPathComponent), \(TransferView.fileSize(url))")
                written = url
            } catch {
                state = .failed("Not backed up: \(error.localizedDescription)")
            }
        }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state = .working("Checking \(url.lastPathComponent)…")
        Task {
            if let problem = await Task.detached(operation: { LogStore.checkBackup(url) }).value {
                state = .failed(problem)
                return
            }
            state = .idle
            let alert = NSAlert()
            alert.messageText = "Restore the log from \(url.lastPathComponent)?"
            alert.informativeText = "Irctell quits now. When it starts again, the backup replaces the log; the current log is kept beside it, renamed."
            alert.addButton(withTitle: "Quit and Restore")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try LogStore.restoreAtNextLaunch(url)
                NSApplication.shared.terminate(nil)
            } catch {
                state = .failed("Cannot restore: \(error.localizedDescription)")
            }
        }
    }
}
