import Foundation
import Observation

/// The lines a transcript shows, read from the log a page at a time: the
/// newest first, older ones as the user scrolls back, until the start of the
/// log. New lines come in as they are written.
@MainActor @Observable
final class TranscriptFeed: LogSubscriber {
    /// About a few screens' worth.
    static let pageSize = 300

    private(set) var lines: [ChatLine] = []
    /// Whether the log has older lines than the first one shown.
    private(set) var hasOlder = false
    /// Whether the log has newer lines than the last one shown: after going
    /// back to a date, until scrolled to the present again. New lines wait
    /// in the log meanwhile.
    private(set) var hasNewer = false
    /// The time gone back to; nil for the newest lines.
    let since: Date?

    let scope: LogStore.Scope
    /// Empty for every line.
    let search: String
    /// Lines up to this row stay hidden: what Clear cleared.
    let floor: Int64?
    /// Lines logged as ignored stay hidden while their sender still is.
    let ignores: [IgnoreRule]
    @ObservationIgnored private weak var store: LogStore?

    init(store: LogStore, scope: LogStore.Scope, search: String = "", floor: Int64? = nil,
         ignores: [IgnoreRule] = [], since: Date? = nil) {
        self.store = store
        self.scope = scope
        self.search = LogStore.ftsQuery(search) == nil ? "" : search
        self.floor = floor
        self.ignores = ignores
        self.since = since
        if let since {
            lines = store.lines(in: scope, matching: self.search, after: floor, since: since, oldestFirst: true,
                                ignoring: ignores, limit: TranscriptFeed.pageSize)
            hasNewer = lines.count == TranscriptFeed.pageSize
            if let first = lines.first?.logID {
                hasOlder = !store.lines(in: scope, matching: self.search, before: first, after: floor,
                                        ignoring: ignores, limit: 1).isEmpty
            } else {
                // Nothing since then: the newest there is, before it.
                lines = store.lines(in: scope, matching: self.search, after: floor, ignoring: ignores,
                                    limit: TranscriptFeed.pageSize)
                hasOlder = lines.count == TranscriptFeed.pageSize
            }
        } else {
            lines = store.lines(in: scope, matching: self.search, after: floor, ignoring: ignores,
                                limit: TranscriptFeed.pageSize)
            hasOlder = lines.count == TranscriptFeed.pageSize
        }
        store.subscribe(self)
    }

    /// The lines around a logged one: half a page before it, half after,
    /// for coming back to it from a search.
    init(store: LogStore, scope: LogStore.Scope, search: String = "", floor: Int64? = nil,
         ignores: [IgnoreRule] = [], around id: Int64) {
        self.store = store
        self.scope = scope
        self.search = LogStore.ftsQuery(search) == nil ? "" : search
        self.floor = floor
        self.ignores = ignores
        since = nil
        let half = TranscriptFeed.pageSize / 2
        let before = store.lines(in: scope, matching: self.search, before: id + 1, after: floor, ignoring: ignores,
                                 limit: half)
        let after = store.lines(in: scope, matching: self.search, after: max(id, floor ?? id), oldestFirst: true,
                                ignoring: ignores, limit: half)
        lines = before + after
        hasOlder = before.count == half
        hasNewer = after.count == half
        store.subscribe(self)
    }

    /// Reads the page after the last line shown.
    func loadNewer() {
        guard hasNewer, let store, let last = lines.last?.logID else { return }
        let newer = store.lines(in: scope, matching: search, after: max(last, floor ?? last), oldestFirst: true,
                                ignoring: ignores, limit: TranscriptFeed.pageSize)
        lines.append(contentsOf: newer)
        hasNewer = newer.count == TranscriptFeed.pageSize
    }

    /// Reads the page before the first line shown.
    func loadOlder() {
        guard hasOlder, let store, let first = lines.first?.logID else { return }
        let older = store.lines(in: scope, matching: search, before: first, after: floor, ignoring: ignores,
                                limit: TranscriptFeed.pageSize)
        lines.insert(contentsOf: older, at: 0)
        hasOlder = older.count == TranscriptFeed.pageSize
    }

    /// A line just written to the log, for whichever conversation.
    func logged(_ line: ChatLine, networkID: UUID, key: String, kind: ChatBuffer.Kind) {
        switch scope {
        case .buffer(let network, let scopeKey):
            guard network == networkID, scopeKey == key else { return }
        case .query(let network, let nicks):
            guard network == networkID, kind == .query, nicks.contains(key) else { return }
        case .nicks(let nicks):
            guard kind == .query, nicks.contains(key) else { return }
        }
        if line.isIgnored, ignores.contains(where: { $0.hides(sender: line.sender, network: networkID, kind: kind) }) {
            return
        }
        if !search.isEmpty {
            guard let id = line.logID, store?.line(id, matches: search) == true else { return }
        }
        // Back in the past: it comes with the pages, scrolling down.
        guard !hasNewer else { return }
        lines.append(line)
        // A transcript left open for weeks: the oldest go, and can be read
        // back by scrolling.
        if lines.count > 20_000 {
            lines.removeFirst(5_000)
            hasOlder = true
        }
    }
}
