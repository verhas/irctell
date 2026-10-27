import SwiftUI

/// At the bottom of the sidebar: type a nick, pick one the log has seen,
/// and Return opens a private chat with it on this network.
struct NickOpener: View {
    let session: NetworkSession
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let suggestions = self.suggestions
        VStack(alignment: .leading, spacing: 2) {
            if focused, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.nick) { index, suggestion in
                        let nick = suggestion.nick
                        Text(nick)
                            .font(.callout)
                            .foregroundStyle(suggestion.standing.color)
                            .help(suggestion.standing.title)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == highlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                                        in: .rect(cornerRadius: 4))
                            .contentShape(.rect)
                            .onTapGesture { open(nick) }
                    }
                }
                .padding(3)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            HStack(spacing: 4) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(.secondary)
                TextField("Private chat with…", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { open(suggestions.indices.contains(highlighted) ? suggestions[highlighted].nick : text) }
                    .onKeyPress(keys: [.downArrow]) { _ in
                        highlighted = min(highlighted + 1, max(suggestions.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(keys: [.upArrow]) { _ in
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onExitCommand { text = "" }
                    .onChange(of: text) { highlighted = 0 }
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .padding(8)
    }

    /// Who a nick is to the user: around now, someone they had a private
    /// chat with, or anyone else seen on the network.
    enum Standing: Int, Comparable {
        case online, privateChat, seen

        static func < (lhs: Standing, rhs: Standing) -> Bool { lhs.rawValue < rhs.rawValue }

        var color: Color {
            switch self {
            case .online: .green
            case .privateChat: .accentColor
            case .seen: .secondary
            }
        }

        var title: String {
            switch self {
            case .online: "Here now: in a channel you are in, or online"
            case .privateChat: "You had a private chat with them"
            case .seen: "Seen on this network before"
            }
        }
    }

    struct Suggestion {
        var nick: String
        var standing: Standing
    }

    /// Every nick ever seen on this network starting so: those here now
    /// first, then those talked to in private, then the rest, each the most
    /// recently seen first. Without a log, the members of the channels.
    private var suggestions: [Suggestion] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        var found: [(suggestion: Suggestion, order: Int)] = []
        var seen = Set<String>()
        func add(_ nick: String, privateChat: Bool) {
            guard seen.insert(nick.lowercased()).inserted, !session.isMe(nick) else { return }
            let standing: Standing = session.isOnline(nick) ? .online : privateChat ? .privateChat : .seen
            found.append((Suggestion(nick: nick, standing: standing), found.count))
        }
        if let log = session.log {
            for known in log.knownNicks(network: session.id, startingWith: typed, limit: 40) {
                add(known.nick, privateChat: known.hadPrivateChat)
            }
        }
        // Members just joined may not be written yet.
        for member in session.channels.flatMap({ $0.members.values })
        where member.nick.lowercased().hasPrefix(typed.lowercased()) {
            add(member.nick, privateChat: false)
        }
        return found.sorted { ($0.suggestion.standing, $0.order) < ($1.suggestion.standing, $1.order) }
            .prefix(10).map(\.suggestion)
    }

    private func open(_ nick: String) {
        let nick = nick.trimmingCharacters(in: .whitespaces)
        guard !nick.isEmpty, !nick.contains(" "), !session.isupport.isChannel(nick) else { return }
        session.openBuffer(named: nick, kind: .query, select: true)
        text = ""
        focused = false
    }
}
