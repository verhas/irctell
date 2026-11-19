import SwiftUI

/// A channel, private chat or the server window: search and history
/// options, topic, lines, input.
struct ConversationView: View {
    let session: NetworkSession
    @Bindable var buffer: ChatBuffer
    @Environment(\.openWindow) private var openWindow
    /// A new value sends the keyboard focus to the input field.
    @State private var inputFocusRequest = 0
    @Environment(\.ignoreRules) private var ignoreRules
    @State private var aliasChoice: AliasChoice?
    /// The lines from the log; nil without a log, when the lines since
    /// launch are shown.
    @State private var feed: TranscriptFeed?
    /// Where the transcript is being brought back to: the place it was left
    /// at, or the line selected when a filter is taken off.
    @State private var focus: TranscriptFocus?

    var body: some View {
        VStack(spacing: 0) {
            ConversationBar(session: session, buffer: buffer, scope: scope)
            Divider()
            if buffer.kind == .channel {
                TopicBar(buffer: buffer)
                Divider()
            }
            TranscriptView(lines: lines,
                           showsNetwork: buffer.aggregatesHistory && buffer.showsNetworkNames,
                           media: session.media,
                           historyMenuItems: historyMenuItems,
                           highlightedNicks: Set(buffer.selectedMembers.map { $0.lowercased() }),
                           hasOlder: feed?.hasOlder ?? false,
                           loadOlder: { feed?.loadOlder() },
                           hasNewer: feed?.hasNewer ?? false,
                           loadNewer: { feed?.loadNewer() },
                           startsAtTop: feed?.since != nil,
                           focus: focus,
                           focusShown: { focus = nil },
                           selectionChanged: { buffer.selection = $0 },
                           positionChanged: { buffer.anchorLine = $0 },
                           nickNamed: { word in
                               // A member, or someone who spoke here lately
                               // and is gone.
                               session.memberNick(word, in: buffer) ?? lines.last {
                                   $0.isActivity && $0.sender?.caseInsensitiveCompare(word) == .orderedSame
                               }?.sender
                           },
                           nickWhois: { nick in
                               buffer.selectedMembers = [nick]
                               session.submit("/whois \(nick)", in: buffer)
                           },
                           canChatPrivately: { nick in
                               !session.isMe(nick)
                                   && !(buffer.kind == .query && buffer.name.caseInsensitiveCompare(nick) == .orderedSame)
                           },
                           nickAliases: { nick in
                               if !session.isMe(nick) { aliasChoice = AliasChoice(nick: nick) }
                           },
                           nickActions: { nick in
                               NickActions.shared.offered(in: buffer.name, isChannel: buffer.kind == .channel)
                                   .map { action in (name: action.name, run: { session.run(action, nick: nick, in: buffer) }) }
                               + ScriptHost.shared.nickActionScripts(in: buffer).map { script in
                                   (name: script.name, run: {
                                       ScriptHost.shared.runNickAction(script, nick: nick, session: session, buffer: buffer)
                                   })
                               }
                           },
                           editNickActions: { openWindow(id: NickActionEditor.windowID) },
                           nickClicked: { nick, clicks in
                               if clicks >= 2 {
                                   if !session.isMe(nick) { session.openBuffer(named: nick, kind: .query, select: true) }
                               } else {
                                   buffer.selectedMembers = [nick]
                               }
                           }) {
                inputFocusRequest += 1
            }
            .overlay {
                if !buffer.search.isEmpty && lines.isEmpty {
                    Text("No messages match “\(buffer.search)”")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            InputBar(session: session, buffer: buffer, focusRequest: $inputFocusRequest)
        }
        .task(id: FeedKey(scope: scope, search: buffer.search, floor: buffer.clearedUpTo, ignores: ignoreRules,
                          since: buffer.historyDate, revision: session.log?.revision.value ?? 0)) {
            await loadFeed()
        }
        .sheet(item: $aliasChoice) { AliasPicker(nick: $0.nick, log: session.log) }
        // Where it was scrolled to and what was selected, kept.
        .onDisappear { session.layoutChanged() }
        .onChange(of: buffer.search) { session.layoutChanged() }
        .onChange(of: buffer.aggregatesHistory) { session.layoutChanged() }
        .onChange(of: buffer.showsNetworkNames) { session.layoutChanged() }
        .onChange(of: buffer.messagesOnly) {
            // All the lines again: the one selected stays in sight.
            if !buffer.messagesOnly, let selection = buffer.selection {
                focus = TranscriptFocus(logID: selection.logID, selection: selection)
            }
            session.layoutChanged()
        }
        .onChange(of: buffer.speaks) {
            if !buffer.speaks { Speaker.shared.stop(buffer: buffer.id) }
            session.layoutChanged()
        }
    }

    /// Downloading the pictures linked in the conversation's whole history,
    /// or stopping it.
    private func historyMenuItems() -> [NSMenuItem] {
        guard let media = session.media else { return [] }
        let scope = scope
        if let progress = media.historyProgress(scope) {
            return [ClosureMenuItem(title: "Stop Downloading Pictures (\(progress.checked) of \(progress.links) Links)") {
                media.stopHistory(scope)
            }]
        }
        let collapsed = media.mode(session.id, LogStore.key(for: buffer.name, kind: buffer.kind), buffer.kind) == .collapsed
        let start = { [session, buffer] (pages: Bool) in
            let speed = SettingsStore.shared.object(forKey: MediaSettings.historySpeed) as? Int
                ?? MediaSettings.defaultHistorySpeed
            session.addInfo("Downloading the pictures linked in this conversation's history, in the background, "
                            + "at most \(speed) KB a second\(pages ? ", and the pictures of the web pages linked" : "").",
                            to: buffer)
            media.downloadHistory(scope, pages: pages, collapsed: collapsed) { progress in
                guard progress.finished else { return }
                var parts = ["\(progress.downloaded) new"]
                if progress.alreadyThere > 0 { parts.append("\(progress.alreadyThere) already downloaded") }
                if progress.notPictures > 0 { parts.append("\(progress.notPictures) not pictures") }
                if progress.failed > 0 { parts.append("\(progress.failed) could not be reached") }
                let megabytes = Double(progress.bytes) / 1_048_576
                session.addInfo((progress.stopped ? "Picture download stopped: " : "Pictures of the history downloaded: ")
                                + parts.joined(separator: ", ") + String(format: " (%.1f MB).", megabytes), to: buffer)
            }
        }
        let item = NSMenuItem(title: "Download Pictures in History", action: nil, keyEquivalent: "")
        let choices = NSMenu(title: item.title)
        choices.addItem(ClosureMenuItem(title: "Picture Links") { start(false) })
        choices.addItem(ClosureMenuItem(title: "Picture Links and Pictures on Linked Pages") { start(true) })
        item.submenu = choices
        return [item]
    }

    private struct FeedKey: Hashable {
        var scope: LogStore.Scope
        var search: String
        var floor: Int64?
        var ignores: [IgnoreRule]
        var since: Date?
        /// Read again after an import changed the log.
        var revision: Int
    }

    /// One conversation. A private chat: with every nick of that person,
    /// on this network or on every one.
    private var scope: LogStore.Scope {
        guard buffer.kind == .query else {
            return .buffer(network: session.id, key: LogStore.key(for: buffer.name, kind: buffer.kind))
        }
        let nicks = People.aliases(of: buffer.name)
        return buffer.aggregatesHistory ? .nicks(nicks) : .query(network: session.id, nicks: nicks)
    }

    private var lines: [ChatLine] {
        let all = allLines
        return buffer.messagesOnly ? all.filter(\.isConversation) : all
    }

    private var allLines: [ChatLine] {
        if let feed { return feed.lines }
        if session.log != nil { return [] } // the feed is on its way
        guard !buffer.search.isEmpty else { return buffer.lines }
        return buffer.lines.filter {
            $0.text.localizedCaseInsensitiveContains(buffer.search)
                || ($0.sender?.localizedCaseInsensitiveContains(buffer.search) ?? false)
        }
    }

    private func loadFeed() async {
        guard let log = session.log else { return }
        // Not a query per keystroke while the search is being typed, nor
        // per step while the timeline is dragged.
        if feed != nil, (feed?.search != buffer.search && !buffer.search.isEmpty) || feed?.since != buffer.historyDate {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
        // The search taken off with a line's text selected: the lines around
        // it, with it in the middle.
        if let feed, !feed.search.isEmpty, buffer.search.isEmpty, let selection = buffer.selection {
            self.feed = TranscriptFeed(store: log, scope: scope, floor: buffer.clearedUpTo, ignores: ignoreRules,
                                       around: selection.logID)
            focus = TranscriptFocus(logID: selection.logID, selection: selection)
            return
        }
        // Coming back to the conversation: where it was left, with what was
        // selected.
        if feed == nil, buffer.historyDate == nil {
            if let anchor = buffer.anchorLine {
                feed = TranscriptFeed(store: log, scope: scope, search: buffer.search, floor: buffer.clearedUpTo,
                                      ignores: ignoreRules, around: anchor)
                focus = TranscriptFocus(logID: anchor, selection: buffer.selection)
                return
            }
            if let selection = buffer.selection { focus = TranscriptFocus(selection: selection) }
        }
        feed = TranscriptFeed(store: log, scope: scope, search: buffer.search, floor: buffer.clearedUpTo,
                              ignores: ignoreRules, since: buffer.historyDate)
    }
}

/// Above the transcript: the search, and in a private chat the history
/// across networks.
private struct ConversationBar: View {
    let session: NetworkSession
    @Bindable var buffer: ChatBuffer
    let scope: LogStore.Scope

    var body: some View {
        HStack(spacing: 14) {
            if buffer.kind == .query {
                Toggle("Aggregated history", isOn: $buffer.aggregatesHistory)
                    .help("Show the private chats with \(buffer.name) on every network, from the log. The same nick on another network is not necessarily the same person.")
                    .disabled(session.log == nil)
                Toggle("Show network", isOn: $buffer.showsNetworkNames)
                    .help("Start each line with the network it came on.")
                    .disabled(!buffer.aggregatesHistory)
                let others = People.aliases(of: buffer.name).filter { $0 != buffer.name.lowercased() }
                if !others.isEmpty {
                    Text("Also \(others.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("The same person's other nicks: their chats are shown here too")
                }
            }
            Spacer(minLength: 0)
            if session.log != nil {
                HistoryButton(session: session, buffer: buffer, scope: scope)
            }
            if buffer.kind != .server {
                Toggle("Messages only", isOn: $buffer.messagesOnly)
                    .help("Hide joins, parts, quits, mode and nick changes, other notices from the server, and lines of fewer than three characters")
                Button {
                    buffer.speaks.toggle()
                } label: {
                    Image(systemName: buffer.speaks ? "speaker.wave.2.fill" : "speaker.slash")
                        .foregroundStyle(buffer.speaks ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(buffer.speaks ? "Reading new messages aloud: click to stop"
                                    : "Read new messages aloud, with who wrote them")
            }
            SearchField(prompt: "Search messages", text: $buffer.search)
                .frame(maxWidth: 260)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

private struct TopicBar: View {
    let buffer: ChatBuffer

    var body: some View {
        HStack {
            if let topic = buffer.topic, !topic.isEmpty {
                Text(IRCFormatting.attributed(topic))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(IRCFormatting.strip(topic))
            } else {
                Text(buffer.isJoined ? "No topic" : "Not in this channel")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct InputBar: View {
    let session: NetworkSession
    @Bindable var buffer: ChatBuffer

    @Binding var focusRequest: Int
    /// Position in the session's input history while browsing it with the
    /// arrow keys; nil when editing a fresh line.
    @State private var historyIndex: Int?
    /// What was being typed when browsing the history began.
    @State private var typedDraft = ""
    @State private var completion: Completion?
    @State private var showsFormats = false
    /// The height the text wants, within the limit of lines.
    @State private var editorHeight: CGFloat = 17

    /// A tab completion in progress, so pressing Tab again cycles through
    /// the other matching nicks.
    private struct Completion {
        var stem: String
        var candidates: [String]
        var index: Int
        var result: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The codes are invisible in the field: what the message will
            // look like.
            if FormatCode.isFormatted(buffer.draft) {
                Text(IRCFormatting.attributed(buffer.draft))
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .help("How the message will look")
            }
            field
        }
    }

    private var field: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(session.nick)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            MessageEditor(text: $buffer.draft,
                          messageStarts: { session.messageStarts(in: $0, for: buffer) },
                          maxLines: maxLines,
                          focusRequest: focusRequest,
                          heightChanged: { editorHeight = $0 },
                          submit: submit,
                          enterSends: enterSends,
                          pastedAsSeveral: { buffer.draftPastedAsSeveral = true },
                          complete: complete,
                          browse: browseHistory,
                          formatKey: formatKey)
                .onChange(of: buffer.draft) {
                    if buffer.draft != completion?.result { completion = nil }
                    if session.messageStarts(in: buffer.draft, for: buffer).isEmpty {
                        buffer.draftPastedAsSeveral = false
                    }
                }
                .frame(height: editorHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    if buffer.draft.isEmpty {
                        Text(shownSuggestion ?? placeholder)
                            .foregroundStyle(.placeholder)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .allowsHitTesting(false)
                    }
                }
            Button {
                showsFormats.toggle()
            } label: {
                Image(systemName: "paintpalette")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .layoutPriority(1)
            .help("Colours, bold, italics (⌃K)")
            .popover(isPresented: $showsFormats, arrowEdge: .top) {
                FormatPalette { code in
                    buffer.draft += code
                    focusRequest += 1
                }
            }
            EmojiButton { focusRequest += 1 }
                .fixedSize()
            Button(action: submit) {
                Image(systemName: "paperplane")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .layoutPriority(1)
            .disabled(!buffer.draft.contains { !$0.isWhitespace })
            .help("Send")
        }
        .overlay(alignment: .trailing) {
            if shownSuggestion != nil {
                Label("Tab", systemImage: "apple.intelligence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .padding(.trailing, 90)
                    .help("A reply suggested by Apple Intelligence, on this Mac: Tab puts it in the field, to edit or send")
                    .allowsHitTesting(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .task(id: SuggestionKey(last: lastHeard.map(ReplySuggester.key), isEmpty: buffer.draft.isEmpty,
                                enabled: ReplySuggester.shared.isEnabled)) {
            await suggestReply()
        }
    }

    // MARK: - Suggested replies

    private struct SuggestionKey: Hashable {
        var last: String?
        var isEmpty: Bool
        var enabled: Bool
    }

    /// The suggestion, while the field is empty.
    private var shownSuggestion: String? {
        buffer.draft.isEmpty ? buffer.suggestion : nil
    }

    /// The newest message or action in the conversation, from anyone.
    private var lastHeard: ChatLine? {
        ReplySuggester.lastHeard(in: buffer, session: session)
    }

    /// Asks for a reply to the newest message, first in the queue: this is
    /// the conversation in front.
    private func suggestReply() async {
        guard buffer.kind != .server, ReplySuggester.shared.isEnabled else {
            buffer.suggestion = nil
            return
        }
        ReplySuggester.shared.request(for: buffer, in: session, foreground: true)
    }

    private var placeholder: String {
        if session.isMemos(buffer) { return "MemoServ command: LIST, READ 1, SEND nick text, DEL 1, HELP" }
        return switch buffer.kind {
        case .server: "Command, e.g. /join #channel"
        case .channel where !buffer.isJoined: "You left \(buffer.name). /join to go back in"
        case .channel, .query: "Message \(buffer.name)"
        }
    }

    private var maxLines: Int {
        let lines = SettingsStore.shared.object(forKey: InputSettings.maxLines) as? Int ?? InputSettings.defaultMaxLines
        return min(max(lines, InputSettings.lineRange.lowerBound), InputSettings.lineRange.upperBound)
    }

    private func submit() {
        let text = buffer.draft
        buffer.draft = ""
        buffer.draftPastedAsSeveral = false
        historyIndex = nil
        typedDraft = ""
        completion = nil
        session.submit(text, in: buffer)
        focusRequest += 1
    }

    private func enterSends() -> Bool {
        let mode = SettingsStore.shared.string(forKey: InputSettings.enterKey).flatMap(EnterKeyMode.init) ?? .sends
        return mode.sends(draft: buffer.draft, pastedAsSeveral: buffer.draftPastedAsSeveral)
    }

    /// mIRC's keys: ⌃B bold, ⌃I italics, ⌃U underline, ⌃O plain, ⌃K the
    /// colours. The codes go at the end, where typing goes on.
    private func formatKey(_ pressed: String) -> Bool {
        // With ⌃ the character may come as the control code itself.
        let key = pressed.lowercased()
        let code: FormatCode? = switch key {
        case "b", "\u{02}": .bold
        case "i", "\u{09}": .italic
        case "u", "\u{15}": .underline
        case "o", "\u{0f}": .plain
        default: nil
        }
        if let code {
            buffer.draft += code.rawValue
            return true
        }
        if key == "k" || key == "\u{0b}" {
            showsFormats = true
            return true
        }
        return false
    }

    /// ↑ and ↓ move through the history at the first and last line of the
    /// text, and all the time while a line from the history is shown as it
    /// was; otherwise they move the caret. What was being typed comes back
    /// after the newest line.
    private func browseHistory(_ step: Int, atEdge: Bool) -> Bool {
        let history = session.inputHistory
        guard !history.isEmpty, step < 0 || historyIndex != nil else { return false }
        let unchanged = historyIndex.map { history.indices.contains($0) && history[$0] == buffer.draft } ?? false
        guard atEdge || unchanged else { return false }
        if historyIndex == nil { typedDraft = buffer.draft }
        let next = (historyIndex ?? history.count) + step
        if next >= history.count {
            historyIndex = nil
            buffer.draft = typedDraft
            typedDraft = ""
        } else if next >= 0 {
            historyIndex = next
            buffer.draft = history[next]
        }
        return true
    }

    /// Completes the word at the end of the text to a member's nick.
    private func complete() {
        // An empty field: Tab takes the suggested reply.
        if buffer.draft.isEmpty, let suggestion = buffer.suggestion {
            buffer.draft = suggestion
            buffer.suggestion = nil
            return
        }
        if var current = completion, buffer.draft == current.result {
            current.index = (current.index + 1) % current.candidates.count
            current.result = completed(stem: current.stem, with: current.candidates[current.index])
            completion = current
            buffer.draft = current.result
            return
        }
        let word = String(buffer.draft.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !word.isEmpty else { return }
        let stem = String(buffer.draft.dropLast(word.count))
        let candidates = session.completions(for: word, in: buffer)
        guard let first = candidates.first else { return }
        let result = completed(stem: stem, with: first)
        completion = Completion(stem: stem, candidates: candidates, index: 0, result: result)
        buffer.draft = result
    }

    /// A nick at the start of the line is addressed: `nick: `.
    private func completed(stem: String, with nick: String) -> String {
        stem.isEmpty ? nick + ": " : stem + nick + " "
    }
}

/// Going back in the history: to a day and time from the calendar, or
/// anywhere on the timeline of the whole log, dragged for speed. Never
/// before the first line logged: "Earliest" goes there, "Latest" comes back
/// to the newest lines.
private struct HistoryButton: View {
    let session: NetworkSession
    @Bindable var buffer: ChatBuffer
    let scope: LogStore.Scope
    @State private var showsPicker = false
    @State private var picked = Date.now
    @State private var span: ClosedRange<Date>?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                span = loadSpan()
                picked = clamped(buffer.historyDate ?? .now, to: span)
                showsPicker = true
            } label: {
                Image(systemName: "calendar")
                    .foregroundStyle(buffer.historyDate == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.borderless)
            .help(buffer.historyDate.map { "Showing from \($0.formatted(date: .abbreviated, time: .shortened))" }
                  ?? "Go back to a date")
            .popover(isPresented: $showsPicker, arrowEdge: .bottom) { picker }
            if let date = buffer.historyDate {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Earliest") { goToEarliest() }
                    .help("To the first line in the log")
                    .disabled(span.map { date <= $0.lowerBound } ?? false)
                Button("Latest") { buffer.historyDate = nil }
                    .help("Back to the newest lines")
            }
        }
    }

    /// The first line in the log, and now.
    private func loadSpan() -> ClosedRange<Date>? {
        guard let logged = session.log?.timeSpan(of: scope) else { return nil }
        return logged.lowerBound...max(logged.lowerBound, Date.now)
    }

    /// The date, moved into the log's span: a day before the first line
    /// goes to the first line.
    private func clamped(_ date: Date, to span: ClosedRange<Date>?) -> Date {
        guard let span else { return date }
        return min(max(date, span.lowerBound), span.upperBound)
    }

    private func goToEarliest() {
        span = loadSpan()
        guard let first = span?.lowerBound else { return }
        picked = first
        buffer.historyDate = first
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The calendar greys out the days before the first line, but
            // can still be set to one: moved to the first line, then.
            DatePicker("Go to", selection: Binding(get: { picked }, set: { picked = clamped($0, to: span) }),
                       in: (span?.lowerBound ?? .now)...max(span?.upperBound ?? .now, .now),
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            if let span, span.upperBound > span.lowerBound {
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: Binding(
                        get: { picked.timeIntervalSince1970 },
                        set: { picked = Date(timeIntervalSince1970: $0); buffer.historyDate = picked }),
                           in: span.lowerBound.timeIntervalSince1970...span.upperBound.timeIntervalSince1970)
                    HStack {
                        Text(span.lowerBound.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Text(picked.formatted(date: .abbreviated, time: .shortened))
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(span.upperBound.formatted(date: .abbreviated, time: .omitted))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .help("The whole log: drag to move through it quickly")
            } else {
                Text("Nothing in the log yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Earliest") {
                    goToEarliest()
                    showsPicker = false
                }
                .help("To the first line in the log")
                .disabled(span == nil)
                Button("Latest") {
                    buffer.historyDate = nil
                    showsPicker = false
                }
                .help("Back to the newest lines")
                Spacer()
                Button("Go") {
                    buffer.historyDate = clamped(picked, to: span)
                    showsPicker = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(span == nil)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
