import SwiftUI

/// The memos of a network as a mailbox: the inbox MemoServ keeps, to read
/// and delete, the outbox Irctell keeps of what was sent, and a new memo.
/// The conversation with MemoServ itself is a click away, for its other
/// commands and its errors.
struct MemoView: View {
    let session: NetworkSession
    @State private var box = Box.inbox
    @State private var selected: Memo.ID?
    @State private var selectedSent: SentMemo.ID?
    @State private var composing: Draft?
    @State private var confirmsDelete = false
    @State private var showsConversation = false

    private enum Box: Hashable { case inbox, outbox }

    /// A memo being written: to whom, and what was there to start with.
    struct Draft: Identifiable {
        let id = UUID()
        var to = ""
        var text = ""
    }

    private var memos: MemoBox { session.memos }
    private var selectedMemo: Memo? { memos.inbox.first { $0.id == selected } }
    private var selectedSentMemo: SentMemo? { memos.outbox.first { $0.id == selectedSent } }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if showsConversation {
                ConversationView(session: session, buffer: session.memoBuffer)
            } else {
                VSplitView {
                    Group {
                        switch box {
                        case .inbox: inbox
                        case .outbox: outbox
                        }
                    }
                    .frame(minHeight: 120, idealHeight: 260)
                    detail
                        .frame(minHeight: 100, idealHeight: 200)
                }
            }
            Divider()
            footer
        }
        .task {
            // Opened after logging in: what is there now.
            guard session.isConnected, !session.memosChecked else { return }
            session.memosChecked = true
            memos.check()
        }
        .sheet(item: $composing) { draft in
            ComposeMemo(draft: draft, isConnected: session.isConnected) { to, text in
                memos.send(to: to, text: text)
                box = .outbox
            }
        }
        .confirmationDialog("Delete the memo from \(selectedMemo?.from ?? "")?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                if let memo = selectedMemo { memos.delete(memo) }
                selected = nil
            }
        } message: {
            Text("It is deleted on the server, for good.")
        }
    }

    // MARK: - Parts

    private var bar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $box) {
                Text(memos.unreadCount > 0 ? "Inbox (\(memos.unreadCount))" : "Inbox").tag(Box.inbox)
                Text("Outbox").tag(Box.outbox)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(showsConversation)
            Button("Check", systemImage: "arrow.clockwise") { memos.check() }
                .disabled(!session.isConnected || memos.isChecking)
                .help("Ask MemoServ for the memos waiting for you")
            Button("New Memo", systemImage: "square.and.pencil") { composing = Draft() }
                .help("Leave a memo for a registered nick, delivered when they log in")
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                if let memo = selectedMemo { composing = Draft(to: memo.from) }
            }
            .disabled(box != .inbox || selectedMemo == nil)
            Button("Delete", systemImage: "trash") { deleteSelected() }
                .disabled(box == .inbox ? selectedMemo == nil || !session.isConnected : selectedSentMemo == nil)
                .help(box == .inbox ? "Delete the memo on the server" : "Remove it from the outbox")
            Spacer()
            Toggle("MemoServ", systemImage: "text.bubble", isOn: $showsConversation)
                .toggleStyle(.button)
                .help("The conversation with MemoServ: its answers, errors, and commands of your own")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var inbox: some View {
        Table(memos.inbox, selection: $selected) {
            TableColumn("") { memo in
                Circle()
                    .fill(memo.isUnread ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                    .frame(width: 7, height: 7)
                    .help(memo.isUnread ? "Not read" : "")
            }
            .width(12)
            TableColumn("From") { memo in
                Text(memo.from).fontWeight(memo.isUnread ? .semibold : .regular)
            }
            .width(min: 80, ideal: 120, max: 200)
            TableColumn("Sent") { memo in
                Text(memo.date).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 240)
            TableColumn("Memo") { memo in
                Text(memo.text ?? "—").lineLimit(1).foregroundStyle(memo.text == nil ? .tertiary : .primary)
            }
        }
        .contextMenu(forSelectionType: Memo.ID.self) { ids in
            if let memo = memos.inbox.first(where: { ids.contains($0.id) }) {
                Button("Reply") { composing = Draft(to: memo.from) }
                Button("Delete…") {
                    selected = memo.id
                    confirmsDelete = true
                }
                .disabled(!session.isConnected)
            }
        }
        .onDeleteCommand { deleteSelected() }
        .onChange(of: selected) {
            if let memo = selectedMemo, session.isConnected { memos.open(memo) }
        }
        .overlay {
            if memos.inbox.isEmpty {
                ContentUnavailableView(memos.lastChecked == nil ? "Not Checked Yet" : "No Memos",
                                       systemImage: "tray",
                                       description: Text(memos.lastChecked == nil
                                                         ? "Check asks MemoServ for the memos waiting for you."
                                                         : "Nobody left you a memo."))
            }
        }
    }

    private var outbox: some View {
        Table(memos.outbox, selection: $selectedSent) {
            TableColumn("To") { memo in Text(memo.to) }
                .width(min: 80, ideal: 120, max: 200)
            TableColumn("Sent") { memo in
                Text(memo.time.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150, max: 220)
            TableColumn("Status") { memo in status(of: memo) }
                .width(min: 80, ideal: 110, max: 260)
            TableColumn("Memo") { memo in Text(memo.text).lineLimit(1) }
        }
        .contextMenu(forSelectionType: SentMemo.ID.self) { ids in
            if let memo = memos.outbox.first(where: { ids.contains($0.id) }) {
                Button("Send Again…") { composing = Draft(to: memo.to, text: memo.text) }
                Button("Remove from Outbox") { memos.removeFromOutbox(ids) }
            }
        }
        .onDeleteCommand { deleteSelected() }
        .overlay {
            if memos.outbox.isEmpty {
                ContentUnavailableView("Nothing Sent", systemImage: "paperplane",
                                       description: Text("The memos you send are kept here: MemoServ keeps no copy."))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                switch box {
                case .inbox:
                    if let memo = selectedMemo {
                        heading("From", memo.from, memo.date)
                        Divider()
                        if let text = memo.text {
                            Text(IRCFormatting.attributed(text)).textSelection(.enabled)
                        } else {
                            Text(session.isConnected ? "Reading…" : "Not read yet: connect to read it.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        placeholder("Select a memo to read it.")
                    }
                case .outbox:
                    if let memo = selectedSentMemo {
                        heading("To", memo.to, memo.time.formatted(date: .long, time: .shortened))
                        status(of: memo)
                        Divider()
                        Text(memo.text).textSelection(.enabled)
                    } else {
                        placeholder("Select a memo you sent.")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private var footer: some View {
        HStack {
            if !session.isConnected {
                Text("Not connected: the memos as last seen.")
            } else if memos.isChecking {
                ProgressView().controlSize(.small)
                Text("Checking…")
            } else if let status = memos.status {
                Label(status, systemImage: "info.circle").lineLimit(1).help(status)
            } else if let checked = memos.lastChecked {
                Text("Checked \(checked.formatted(.relative(presentation: .named)))")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func heading(_ label: String, _ nick: String, _ date: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text("\(label) ").foregroundStyle(.secondary) + Text(nick).fontWeight(.semibold))
            Text(date).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 20)
    }

    @ViewBuilder
    private func status(of memo: SentMemo) -> some View {
        switch memo.status {
        case .sending: Label("Sending…", systemImage: "clock").foregroundStyle(.secondary)
        case .delivered: Label("Delivered", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let reason):
            Label("Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red).help(reason)
            if selectedSent == memo.id { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func deleteSelected() {
        switch box {
        case .inbox: if selectedMemo != nil, session.isConnected { confirmsDelete = true }
        case .outbox:
            if let id = selectedSent { memos.removeFromOutbox([id]) }
            selectedSent = nil
        }
    }
}

/// A new memo: to whom, and what.
private struct ComposeMemo: View {
    let draft: MemoView.Draft
    let isConnected: Bool
    let send: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var text = ""

    /// Services cut memos longer than this; most allow 300 characters.
    private static let usualLimit = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Memo").font(.headline)
            TextField("To", text: $to, prompt: Text("A registered nick"))
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
            HStack {
                Text("Delivered when they log in with their account, even if they are not online now.")
                Spacer()
                Text("\(text.count)/\(ComposeMemo.usualLimit)")
                    .monospacedDigit()
                    .foregroundStyle(text.count > ComposeMemo.usualLimit ? .orange : .secondary)
                    .help("Most networks cut memos at \(ComposeMemo.usualLimit) characters")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                if !isConnected {
                    Text("Not connected").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") {
                    send(to.trimmingCharacters(in: .whitespaces), text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear {
            to = draft.to
            text = draft.text
        }
    }

    private var canSend: Bool {
        let nick = to.trimmingCharacters(in: .whitespaces)
        return isConnected && !nick.isEmpty && !nick.contains(" ")
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
