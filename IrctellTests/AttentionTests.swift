import SQLite3
import XCTest
@testable import Irctell

@MainActor
final class RecordingNotifier: Notifier {
    struct Posted: Equatable {
        var title: String, subtitle: String, body: String, threadID: String
    }
    var posted: [Posted] = []
    var removed: [String] = []
    var onOpen: (([String: String]) -> Void)?

    func post(title: String, subtitle: String, body: String, sound: Bool, threadID: String,
              userInfo: [String: String]) {
        posted.append(Posted(title: title, subtitle: subtitle, body: body, threadID: threadID))
    }

    func removeDelivered(threadID: String) {
        removed.append(threadID)
    }
}

final class HighlightRulesTests: XCTestCase {
    func testWordsPatternsAndIgnoredNicks() {
        let rules = HighlightRules(words: ["irctell"], patterns: [#"\bbuild (failed|broke)\b"#], ignores: [IgnoreEntry(nick: "Bot")])
        XCTAssertTrue(rules.matches("hey peter!", nick: "Peter"))
        XCTAssertFalse(rules.matches("peterson", nick: "peter"))
        XCTAssertTrue(rules.matches("Irctell is nice", nick: "peter"))
        XCTAssertFalse(rules.matches("irctelling", nick: "peter"))
        XCTAssertTrue(rules.matches("the BUILD FAILED again", nick: "peter"))
        XCTAssertFalse(rules.matches("the build passed", nick: "peter"))
        XCTAssertTrue(rules.isIgnored("bot"))
        XCTAssertFalse(rules.isIgnored("robot"))
        XCTAssertNotNil(HighlightRules.error(in: "(unclosed"))
        XCTAssertNil(HighlightRules.error(in: "fine"))
    }
}

@MainActor
final class AttentionTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var notifier: RecordingNotifier!
    private var session: NetworkSession!
    private var active = false
    private var idle: TimeInterval = 0

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        notifier = RecordingNotifier()
        model = AppModel(store: NetworkStore(fileURL: directory.appending(path: "networks.plist"), usesKeychain: false),
                         settings: SettingsStore(fileURL: directory.appending(path: "settings.plist")),
                         log: try LogStore(fileURL: directory.appending(path: "logs.sqlite")),
                         notifier: notifier)
        model.isAppActive = { [unowned self] in active }
        model.idleSeconds = { [unowned self] in idle }
        let libera = try XCTUnwrap(model.networks.first { $0.host == "irc.libera.chat" })
        model.open(libera.id, connect: false)
        session = try XCTUnwrap(model.session(for: libera.id))
        session.highlightRules = { HighlightRules(ignores: [IgnoreEntry(nick: "annoying")]) }
        session.handle(.registered(nick: "me"))
        receive(":me!u@h JOIN #alpha", ":me!u@h JOIN #hotel")
        session.selectedBufferID = session.serverBuffer.id
    }

    override func tearDown() async throws {
        model.awayTask?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    private func receive(_ lines: String...) {
        for line in lines { session.handle(.received(IRCMessage(parsing: line)!)) }
    }

    func testMentionsAndPrivateMessagesNotifyChannelChatterDoesNot() {
        receive(":alice!a@h PRIVMSG #alpha :just talking",
                ":alice!a@h PRIVMSG #alpha :me: have a look",
                ":bob!b@h PRIVMSG me :psst")
        XCTAssertEqual(notifier.posted.map(\.title), ["alice in #alpha", "bob"])
        XCTAssertEqual(notifier.posted.first?.body, "me: have a look")
        XCTAssertEqual(notifier.posted.first?.subtitle, "Libera.Chat")
        XCTAssertEqual(model.dockBadge, "2")

        session.selectedBufferID = session.buffer(named: "bob")?.id
        XCTAssertEqual(model.dockBadge, "1", "looking at it clears its count")
        XCTAssertTrue(notifier.removed.contains { $0.hasSuffix("/bob") }, "and its notifications")
    }

    func testLevelsPerConversation() {
        model.setNotificationLevel(.all, network: session.id, buffer: "#alpha", kind: .channel)
        model.setNotificationLevel(.none, network: session.id, buffer: "#hotel", kind: .channel)
        receive(":alice!a@h PRIVMSG #alpha :anything", ":alice!a@h PRIVMSG #hotel :me: even this")
        XCTAssertEqual(notifier.posted.map(\.body), ["anything"])
        XCTAssertEqual(model.notificationLevel(network: session.id, buffer: "#HOTEL", kind: .channel), .none)
        XCTAssertEqual(model.notificationLevel(network: session.id, buffer: "carol", kind: .query), .all)
    }

    func testNothingAboutTheConversationBeingRead() {
        active = true
        model.selectedSessionID = session.id
        session.selectedBufferID = session.buffer(named: "#alpha")?.id
        receive(":alice!a@h PRIVMSG #alpha :me: you see this anyway",
                ":annoying!a@h PRIVMSG me :me me me")
        XCTAssertTrue(notifier.posted.isEmpty, "read already; ignored nick")
        XCTAssertNil(model.dockBadge)
    }

    func testWhatCameWhileAwayIsSummedUpOnReturn() {
        model.checkAway()
        idle = 3600
        model.checkAway()
        receive(":alice!a@h PRIVMSG #alpha :me: are you there?", ":bob!b@h PRIVMSG me :hello?",
                ":carol!c@h PRIVMSG me :anyone home")
        XCTAssertEqual(model.awayDigest.count, 3)
        notifier.posted = []

        idle = 1
        model.checkAway()
        XCTAssertEqual(notifier.posted.map(\.body), ["1 mention and 2 private messages"])
        model.checkAway()
        XCTAssertEqual(notifier.posted.count, 1, "summed up once")
    }

    func testIdleMarksAwayAndMutesUntilBack() {
        var muted = false
        var sent: [String] = []
        model.isMuted = { muted }
        model.setMuted = { muted = $0 }
        session.handle(.stateChanged(.registered))
        session.sent = { sent.append($0.params.isEmpty ? $0.command : "\($0.command) \($0.params.joined(separator: " "))") }
        model.checkAway()
        XCTAssertEqual(sent, [])

        idle = 3600
        model.checkAway()
        model.checkAway()
        XCTAssertEqual(sent, ["AWAY Away from the keyboard"], "once, with the default message")
        XCTAssertTrue(muted)
        receive(":srv 306 me :You have been marked as being away")

        idle = 1
        model.checkAway()
        XCTAssertEqual(sent.last, "AWAY", "back")
        XCTAssertFalse(muted)

        // What the user set themselves stays.
        receive(":srv 306 me :You have been marked as being away")
        muted = true
        sent = []
        idle = 3600
        model.checkAway()
        idle = 1
        model.checkAway()
        XCTAssertEqual(sent, [], "already away by their own /away")
        XCTAssertTrue(muted, "muted by them, stays muted")
    }

    func testTheAwayButtonCoversEveryNetworkAndReconnects() {
        var sent: [String] = []
        session.handle(.stateChanged(.registered))
        session.sent = { sent.append($0.params.isEmpty ? $0.command : "\($0.command) \($0.params.joined(separator: " "))") }
        XCTAssertFalse(model.isAwaySomewhere)

        model.goAwayEverywhere("lunch")
        XCTAssertEqual(sent, ["AWAY lunch"])
        XCTAssertTrue(model.isAwaySomewhere, "at once, before the server confirms")
        model.checkAway()
        XCTAssertEqual(sent.count, 1, "not again while the server confirms")
        receive(":srv 306 me :You have been marked as being away")

        // A reconnect: the server forgot it.
        session.handle(.stateChanged(.disconnected))
        session.handle(.stateChanged(.registered))
        model.keepAwayByUser(now: .now + 60)
        XCTAssertEqual(sent.last, "AWAY lunch", "sent again after the reconnect")
        receive(":srv 306 me :You have been marked as being away")

        // Idling and coming back does not undo it.
        idle = 3600
        model.checkAway()
        idle = 1
        model.checkAway()
        XCTAssertEqual(sent.filter { $0 == "AWAY" }, [], "still away")

        model.comeBackEverywhere()
        XCTAssertEqual(sent.last, "AWAY", "back")
        receive(":srv 305 me :You are no longer marked as being away")
        XCTAssertFalse(model.isAwaySomewhere)
        model.goAwayEverywhere("")
        XCTAssertEqual(sent.last, "AWAY Away from the keyboard", "no message: the one from Settings")
    }

    func testAwayOnTheNetworkCountsToo() {
        receive(":srv 306 me :You have been marked as being away")
        XCTAssertTrue(session.isAway)
        model.checkAway()
        receive(":bob!b@h PRIVMSG me :still there?")
        receive(":srv 305 me :You are no longer marked as being away")
        notifier.posted = []
        model.checkAway()
        XCTAssertEqual(notifier.posted.map(\.title), ["While you were away"])
    }

    func testMentionsFeedCollectsAcrossConversations() throws {
        let log = try XCTUnwrap(model.log)
        receive(":alice!a@h PRIVMSG #alpha :me: first", ":alice!a@h PRIVMSG #alpha :no mention",
                ":bob!b@h PRIVMSG me :private one")
        let mentions = MentionsFeed(store: log, includesPrivateMessages: false)
        XCTAssertEqual(mentions.mentions.map(\.line.text), ["me: first"])
        let all = MentionsFeed(store: log, includesPrivateMessages: true)
        XCTAssertEqual(all.mentions.map(\.line.text), ["me: first", "private one"], "oldest first, like a chat")
        XCTAssertEqual(all.mentions.first?.bufferKey, "#alpha")

        receive(":carol!c@h PRIVMSG #hotel :ping me")
        XCTAssertEqual(mentions.mentions.last?.line.text, "ping me", "new ones at the end")
        XCTAssertEqual(MentionsFeed(store: log, includesPrivateMessages: true, search: "private").mentions.count, 1)
    }

    func testOpeningANotificationShowsItsConversation() {
        model.openNotification(["network": session.id.uuidString, "buffer": "bob", "kind": "query"])
        XCTAssertEqual(session.selectedBuffer?.name, "bob")
        XCTAssertEqual(session.selectedBuffer?.kind, .query)
        XCTAssertEqual(model.selectedSessionID, session.id)
    }
}

@MainActor
final class IgnoreTests: XCTestCase {
    private var directory: URL!
    private var log: LogStore!
    private var session: NetworkSession!
    private var rules = HighlightRules()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        log = try LogStore(fileURL: directory.appending(path: "logs.sqlite"))
        session = NetworkSession(config: NetworkConfig(name: "Net", host: "h", nick: "me"), log: log)
        session.highlightRules = { [unowned self] in rules }
        session.handle(.registered(nick: "me"))
        session.handle(.stateChanged(.registered))
        receive(":me!u@h JOIN #a")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func receive(_ lines: String...) {
        for line in lines { session.handle(.received(IRCMessage(parsing: line)!)) }
    }

    private func ruleList() -> [IgnoreRule] {
        rules.ignores.map { IgnoreRule(network: nil, nick: $0.nick.lowercased(), privateOnly: $0.scope == .privateMessages) }
    }

    private func shown(_ scope: LogStore.Scope) -> [String] {
        TranscriptFeed(store: log, scope: scope, ignores: ruleList()).lines.filter(\.isActivity).map(\.text)
    }

    func testIgnoringEverythingHidesChannelMessagesButKeepsThemInTheLog() throws {
        receive(":troll!t@h PRIVMSG #a :before the ignore")
        rules.ignores = [IgnoreEntry(nick: "Troll", scope: .everything)]
        receive(":troll!t@h PRIVMSG #a :noise", ":troll!t@h PRIVMSG me :psst", ":alice!a@h PRIVMSG #a :hello")
        let channel = try XCTUnwrap(session.buffer(named: "#a"))
        XCTAssertEqual(channel.lines.filter(\.isActivity).map(\.text), ["before the ignore", "hello"])
        XCTAssertNil(session.buffer(named: "troll"), "no private chat")
        let scope = LogStore.Scope.buffer(network: session.id, key: "#a")
        XCTAssertEqual(shown(scope), ["before the ignore", "hello"], "what came before stays")

        rules.ignores = []
        XCTAssertEqual(shown(scope), ["before the ignore", "noise", "hello"], "back once no longer ignored")
        XCTAssertEqual(shown(.buffer(network: session.id, key: "troll")), ["psst"], "private messages logged too")
    }

    func testIgnoringPrivateMessagesKeepsTheChannel() throws {
        rules.ignores = [IgnoreEntry(nick: "bot", scope: .privateMessages)]
        receive(":bot!b@h PRIVMSG #a :in the channel", ":bot!b@h PRIVMSG me :spam", ":bot!b@h NOTICE me :more spam")
        XCTAssertEqual(session.buffer(named: "#a")?.lines.last?.text, "in the channel")
        XCTAssertNil(session.buffer(named: "bot"), "no private chat opened")
        XCTAssertEqual(shown(.buffer(network: session.id, key: "bot")), [])
        rules.ignores = []
        XCTAssertEqual(shown(.buffer(network: session.id, key: "bot")), ["spam", "more spam"])
    }

    func testNetworkRulesAddToTheSettings() {
        var config = NetworkConfig(name: "N", host: "h")
        config.highlightWords = ["release"]
        config.ignores = [IgnoreEntry(nick: "x", scope: .privateMessages)]
        let rules = HighlightRules.current(for: config)
        XCTAssertTrue(rules.matches("new release out", nick: "me"))
        XCTAssertEqual(rules.ignore(of: "X"), .privateMessages)
        XCTAssertFalse(HighlightRules.current().matches("new release out", nick: "me"))
    }

    func testLeftChannelsStayAndRefuseMessages() throws {
        receive(":me!u@h PART #a :bye")
        let channel = try XCTUnwrap(session.buffer(named: "#a"))
        XCTAssertFalse(channel.isJoined)
        session.submit("hello?", in: channel)
        XCTAssertEqual(channel.lines.last?.kind, .error)
        XCTAssertTrue(channel.lines.last?.text.contains("/join") ?? false)
    }

    func testChannelListIsKeptBetweenLaunches() {
        session.requestChannelList()
        receive(":srv 322 me #alpha 10 :Swift", ":srv 322 me #gamma 5 :Mac", ":srv 323 me :End of /LIST")
        let next = NetworkSession(config: session.config, log: log)
        next.loadSavedChannelList()
        XCTAssertEqual(Set(next.channelList.map(\.name)), ["#alpha", "#gamma"])
        XCTAssertNotNil(next.channelListDate)
    }

    func testLogsFromBeforeIgnoresExistedStillOpen() async throws {
        let file = directory.appending(path: "old.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE lines (id INTEGER PRIMARY KEY, network_id TEXT NOT NULL, network TEXT NOT NULL,
              buffer TEXT NOT NULL, buffer_kind TEXT NOT NULL, time REAL NOT NULL, kind TEXT NOT NULL,
              sender TEXT, text TEXT NOT NULL, is_self INTEGER NOT NULL DEFAULT 0, is_highlight INTEGER NOT NULL DEFAULT 0);
            INSERT INTO lines VALUES (1, 'n', 'N', '#a', 'channel', 0, 'message', 'x', 'old line', 0, 0);
            """, nil, nil, nil)
        sqlite3_close(db)
        let old = try LogStore(fileURL: file)
        XCTAssertEqual(old.lines(in: .nick("nobody"), limit: 10).count, 0)
        // Its nicks are gathered in the background.
        for _ in 0..<100 where old.nicks(startingWith: "x", limit: 5).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(old.nicks(startingWith: "x", limit: 5), ["x"])
        old.append(ChatLine(time: .now, kind: .message, sender: "y", text: "new", isIgnored: true),
                   networkID: UUID(), networkName: "N", bufferName: "#b", bufferKind: .channel)
    }
}
