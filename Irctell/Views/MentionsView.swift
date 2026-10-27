import SwiftUI

/// Every mention on every network, from the log, newest first; what came
/// while the user was away on top. Double-click one to go to it.
struct MentionsView: View {
    static let windowID = "mentions"

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var feed: MentionsFeed?
    @State private var search = ""

    private var includesPrivate: Binding<Bool> {
        app.settings.binding(AttentionSettings.mentionsIncludePrivate, default: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Include private messages", isOn: includesPrivate)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 0)
                SearchField(prompt: "Search mentions", text: $search)
                    .frame(maxWidth: 260)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            if app.log == nil {
                ContentUnavailableView("No Message Log", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text("The log database could not be opened, so mentions are not kept."))
            } else {
                list
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { if app.openWindow == nil { app.openWindow = { openWindow(id: $0) } } }
        .task(id: FeedKey(includesPrivate: includesPrivate.wrappedValue, search: search, ignores: app.ignoreRules,
                          revision: app.log?.revision.value ?? 0)) {
            guard let log = app.log else { return }
            if feed != nil, !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            feed = MentionsFeed(store: log, includesPrivateMessages: includesPrivate.wrappedValue, search: search,
                                ignores: app.ignoreRules)
        }
    }

    private struct FeedKey: Hashable {
        var includesPrivate: Bool
        var search: String
        var ignores: [IgnoreRule]
        var revision: Int
    }

    private var list: some View {
        VStack(spacing: 0) {
            if !app.awayDigest.isEmpty {
                awayDigest
                Divider()
            }
            TranscriptView(lines: (feed?.mentions ?? []).map(transcriptLine),
                           showsNetwork: true,
                           hasOlder: feed?.hasOlder ?? false,
                           loadOlder: { feed?.loadOlder() },
                           lineActivated: { line in
                               if let mention = feed?.mentions.first(where: { $0.line.logID == line.logID }) {
                                   reveal(mention)
                               }
                           })
                .overlay {
                    if let feed, feed.mentions.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "No Mentions" : "No Matches", systemImage: "bell",
                                               description: Text(search.isEmpty
                                                                 ? "Messages that mention you, or a highlight word, are collected here."
                                                                 : "No mention matches “\(search)”."))
                    }
                }
        }
    }

    /// What came while the user was away, above the rest until dismissed.
    private var awayDigest: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("While you were away").font(.headline)
                Spacer()
                Button("Dismiss") { app.awayDigest = [] }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            List(app.awayDigest) { mention in
                MentionRow(mention: mention, networkName: networkName(of: mention))
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { reveal(mention) }
            }
            .listStyle(.plain)
            .frame(maxHeight: 160)
        }
    }

    /// A mention as a transcript line, saying where it was.
    private func transcriptLine(_ mention: Mention) -> ChatLine {
        var line = mention.line
        let network = networkName(of: mention)
        line.network = switch mention.bufferKind {
        case .channel: "\(network) \(mention.bufferKey)"
        case .query: "\(network) private"
        case .server: network
        }
        return line
    }

    /// The name the network has now; the log's for one since removed.
    private func networkName(of mention: Mention) -> String {
        app.network(mention.networkID)?.name ?? mention.line.network ?? "?"
    }

    private func reveal(_ mention: Mention) {
        app.reveal(network: mention.networkID, bufferKey: mention.bufferKey, kind: mention.bufferKind)
    }
}

private struct MentionRow: View {
    let mention: Mention
    let networkName: String

    var body: some View {
        let line = mention.line
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.time.formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
                Text("·")
                Text(place)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(message)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var place: String {
        switch mention.bufferKind {
        case .channel: "\(mention.bufferKey) on \(networkName)"
        case .query: "private, on \(networkName)"
        case .server: networkName
        }
    }

    private var message: AttributedString {
        let line = mention.line
        let nick = line.sender ?? ""
        var prefix = AttributedString(line.kind == .action ? "• \(nick) " : "<\(nick)> ")
        prefix.foregroundColor = IRCFormatting.color(forNick: nick)
        prefix.font = .body.bold()
        return prefix + IRCFormatting.attributed(line.text)
    }
}
