import Foundation
import Observation

/// The mentions on every network, oldest first like a conversation, read
/// from the log a page at a time from the newest back; new ones come in at
/// the end as they are written.
@MainActor @Observable
final class MentionsFeed: LogSubscriber {
    static let pageSize = 200

    private(set) var mentions: [Mention] = []
    private(set) var hasOlder = false

    let includesPrivateMessages: Bool
    let search: String
    let ignores: [IgnoreRule]
    @ObservationIgnored private weak var store: LogStore?

    init(store: LogStore, includesPrivateMessages: Bool, search: String = "", ignores: [IgnoreRule] = []) {
        self.store = store
        self.includesPrivateMessages = includesPrivateMessages
        self.search = LogStore.ftsQuery(search) == nil ? "" : search
        self.ignores = ignores
        mentions = store.mentions(includingPrivateMessages: includesPrivateMessages, matching: self.search,
                                  ignoring: ignores, limit: MentionsFeed.pageSize).reversed()
        hasOlder = mentions.count == MentionsFeed.pageSize
        store.subscribe(self)
    }

    func loadOlder() {
        guard hasOlder, let store, let first = mentions.first?.line.logID else { return }
        let older = store.mentions(includingPrivateMessages: includesPrivateMessages, matching: search,
                                   before: first, ignoring: ignores, limit: MentionsFeed.pageSize)
        mentions.insert(contentsOf: older.reversed(), at: 0)
        hasOlder = older.count == MentionsFeed.pageSize
    }

    func logged(_ line: ChatLine, networkID: UUID, key: String, kind: ChatBuffer.Kind) {
        let isPrivate = kind == .query && !line.isSelf && line.isActivity
        guard line.isHighlight || (includesPrivateMessages && isPrivate) else { return }
        if line.isIgnored, ignores.contains(where: { $0.hides(sender: line.sender, network: networkID, kind: kind) }) {
            return
        }
        if !search.isEmpty {
            guard let id = line.logID, store?.line(id, matches: search) == true else { return }
        }
        mentions.append(Mention(line: line, networkID: networkID, bufferKey: key, bufferKind: kind))
    }
}
