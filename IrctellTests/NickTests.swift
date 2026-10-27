import SQLite3
import XCTest
@testable import Irctell

/// The nicks seen on each network, and the user's actions for nicks.
@MainActor
final class NickTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "nicks-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func receive(_ session: NetworkSession, _ lines: String...) {
        for line in lines { session.handle(.received(IRCMessage(parsing: line)!)) }
    }

    func testActionsAreOfferedWhereTheyMatchAndFilledIn() {
        let view = NickAction(name: "View on Data", channels: "#room-one", command: "/msg Data !view {nick}")
        XCTAssertTrue(view.applies(to: "#Room-one", isChannel: true), "ignoring case")
        XCTAssertFalse(view.applies(to: "#other", isChannel: true))
        XCTAssertFalse(view.applies(to: "bob", isChannel: false), "a channel selector: not in private chats")
        XCTAssertEqual(view.expanded(nick: "bob", channel: "#room-one", me: "me", network: "N"),
                       "/msg Data !view bob")

        let wide = NickAction(name: "x", channels: "room*, #echo", command: "{me} greets {nick} in {channel} on {network}")
        XCTAssertTrue(wide.applies(to: "#room-one", isChannel: true), "without the #, and a wildcard")
        XCTAssertTrue(wide.applies(to: "#echo", isChannel: true))
        XCTAssertFalse(wide.applies(to: "#helpers", isChannel: true), "the whole name")
        XCTAssertEqual(wide.expanded(nick: "bob", channel: "#echo", me: "me", network: "Libera"),
                       "me greets bob in #echo on Libera")
        XCTAssertTrue(NickAction(name: "y", command: "/whois {nick}").applies(to: "bob", isChannel: false),
                      "no channels: everywhere")

        let session = NetworkSession(config: NetworkConfig(name: "N", host: "h", nick: "me"))
        session.handle(.registered(nick: "me"))
        session.handle(.stateChanged(.registered))
        var sent: [String] = []
        session.sent = { sent.append("\($0.command) \($0.params.joined(separator: " "))") }
        receive(session, ":me!u@h JOIN #room-one")
        let channel = try! XCTUnwrap(session.buffer(named: "#room-one"))
        session.run(view, nick: "bob", in: channel)
        XCTAssertEqual(sent.last, "PRIVMSG Data !view bob")
    }

    func testAFreshInstallationHasNoActions() throws {
        let actions = NickActions(settings: SettingsStore(fileURL: directory.appending(path: "settings.plist")))
        XCTAssertTrue(actions.list.isEmpty, "none come with Irctell")
        actions.list = [NickAction(name: "Info", command: "/msg Bot !info {nick}")]
        XCTAssertEqual(NickActions(settings: SettingsStore(fileURL: directory.appending(path: "settings.plist")))
            .list.map(\.name), ["Info"], "the user's own are kept")
    }

    func testTheNetworksNicksAreKeptAndUpdated() throws {
        let log = try LogStore(fileURL: directory.appending(path: "logs.sqlite"))
        let network = UUID(), other = UUID()
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        log.noteNicks([.init(nick: "Bob", user: "bob", host: "a.example"), .init(nick: "bella")],
                      network: network, time: then)
        log.noteNicks([.init(nick: "BOB", account: "bobby")], network: network, time: then + 60)
        log.noteNicks([.init(nick: "bob")], network: network, privateChat: true, time: then + 30)
        log.noteNicks([.init(nick: "bert")], network: other, time: then)

        let bob = try XCTUnwrap(log.knownNick("bob", network: network))
        XCTAssertEqual(bob.seen.nick, "bob", "the nick as last written")
        XCTAssertEqual(bob.seen.host, "a.example", "kept when not sent again")
        XCTAssertEqual(bob.seen.account, "bobby")
        XCTAssertEqual(bob.firstSeen, then)
        XCTAssertEqual(bob.lastSeen, then + 60, "the latest time stays")
        let known = log.knownNicks(network: network, startingWith: "b", limit: 10)
        XCTAssertEqual(known.map(\.nick), ["bob", "bella"], "this network's only, the most recent first")
        XCTAssertEqual(known.map(\.hadPrivateChat), [true, false])
        XCTAssertEqual(log.knownNicks(network: network, startingWith: "BE", limit: 10).map(\.nick), ["bella"])
    }

    func testANewLogTakesTheNicksFromItsHistory() async throws {
        let file = directory.appending(path: "logs.sqlite")
        let network = UUID()
        do {
            let log = try LogStore(fileURL: file)
            let line = { (sender: String, text: String) in
                ChatLine(time: Date(timeIntervalSince1970: 1_700_000_000), kind: .message, sender: sender, text: text)
            }
            log.append(line("alice", "hi"), networkID: network, networkName: "N", bufferName: "#a", bufferKind: .channel)
            log.append(line("carol", "psst"), networkID: network, networkName: "N", bufferName: "carol", bufferKind: .query)
            log.append(line("irc.example.org", "motd"), networkID: network, networkName: "N", bufferName: "",
                       bufferKind: .server)
        }
        // As a log from before the table: without it.
        // The first log's own background work may hold the lock a moment.
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        sqlite3_busy_timeout(db, 10_000)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE network_nicks", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let reopened = try LogStore(fileURL: file)
        var known: [LogStore.KnownNick] = []
        for _ in 0..<100 {
            known = reopened.knownNicks(network: network, startingWith: "", limit: 10)
                + reopened.knownNicks(network: network, startingWith: "a", limit: 10)
                + reopened.knownNicks(network: network, startingWith: "c", limit: 10)
            if known.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(Set(known.map(\.nick)), ["alice", "carol"], "people, not the server")
        XCTAssertEqual(known.first { $0.nick == "carol" }?.hadPrivateChat, true)
    }

    func testWhatTheServerSaysFillsTheList() throws {
        let log = try LogStore(fileURL: directory.appending(path: "logs.sqlite"))
        let session = NetworkSession(config: NetworkConfig(name: "N", host: "h", nick: "me"), log: log)
        session.handle(.registered(nick: "me"))
        receive(session, ":me!u@h JOIN #a",
                ":srv 353 me = #a :me @dave!d@dave.example +erin!e@erin.example",
                ":srv 366 me #a :End of /NAMES list.",
                ":frank!f@frank.example JOIN #a frankacct :Frank Real",
                ":gina!g@gina.example PRIVMSG me :hello")
        XCTAssertEqual(log.knownNick("dave", network: session.id)?.seen.host, "dave.example", "from the names list")
        XCTAssertEqual(log.knownNick("frank", network: session.id)?.seen.account, "frankacct", "extended-join")
        XCTAssertEqual(log.knownNick("frank", network: session.id)?.seen.realName, "Frank Real")
        XCTAssertEqual(log.knownNicks(network: session.id, startingWith: "gina", limit: 1).first?.hadPrivateChat, true)
        XCTAssertTrue(session.isOnline("DAVE"))
        XCTAssertFalse(session.isOnline("nobody"))
    }
}
