import AppKit
import SwiftUI

/// Irctell's own log: what it did and why, for when something does not work.
/// Filtered by the least level shown, a category and text.
struct AppLogView: View {
    static let windowID = "appLog"

    @State private var minimum = LogLevel.info
    @State private var category = ""
    @State private var filter = ""
    @State private var selection = Set<AppLogEntry.ID>()
    @State private var followsNewest = true
    private var log: AppLog { .shared }

    private var shown: [AppLogEntry] {
        log.entries.filter { entry in
            entry.level >= minimum
                && (category.isEmpty || entry.category == category)
                && (filter.isEmpty || entry.message.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Level", selection: $minimum) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level == .error ? level.title : "\(level.title) and up").tag(level)
                    }
                }
                .fixedSize()
                .help("The least important entries shown")
                Picker("Category", selection: $category) {
                    Text("All").tag("")
                    ForEach(log.categories, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Spacer()
                SearchField(prompt: "Filter", text: $filter)
                    .frame(width: 200)
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                Table(shown, selection: $selection) {
                    TableColumn("Time") { entry in
                        Text(entry.time.formatted(.dateTime.hour().minute().second()))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 70, max: 90)
                    TableColumn("Level") { entry in
                        Label(entry.level.title, systemImage: entry.level.symbol)
                            .foregroundStyle(color(entry.level))
                    }
                    .width(min: 70, ideal: 85, max: 110)
                    TableColumn("Category") { entry in
                        Text(entry.category).foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 95, max: 140)
                    TableColumn("Message") { entry in
                        Text(entry.message)
                            .lineLimit(3)
                            .help(entry.message)
                    }
                }
                .contextMenu(forSelectionType: AppLogEntry.ID.self) { ids in
                    Button("Copy") { copy(ids) }
                        .disabled(ids.isEmpty)
                }
                .onChange(of: log.entries.count) {
                    if followsNewest, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text("\(shown.count) of \(log.entries.count) entries")
                    .foregroundStyle(.secondary)
                Toggle("Follow new entries", isOn: $followsNewest)
                    .toggleStyle(.checkbox)
                Spacer()
                if let file = log.fileURL {
                    Button("Show Log File") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .help(file.path)
                }
                Button("Copy") { copy(selection.isEmpty ? Set(shown.map(\.id)) : selection) }
                    .help("The selected entries, or all those shown")
                Button("Clear") { log.clear() }
                    .help("Empties this window; the log file keeps them")
            }
            .font(.callout)
            .padding(10)
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .notice: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    private func copy(_ ids: Set<AppLogEntry.ID>) {
        let text = shown.filter { ids.contains($0.id) }.map(\.line).joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
