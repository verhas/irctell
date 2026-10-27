import XCTest
@testable import Irctell

@MainActor
final class NetworkSessionTests: XCTestCase {

    private func makeSession(nick: String = "me") -> NetworkSession {
        let session = NetworkSession(config: NetworkConfig(name: "Test", host: "irc.example.org", nick: nick))
        session.handle(.registered(nick: nick))
        return session
    }

    private func receive(_ session: NetworkSession, _ lines: String...) {
        for line in lines {
            session.handle(.received(IRCMessage(parsing: line)!))
        }
    }

    func testJoinNamesModeAndPart() throws {
        let session = makeSession()
        receive(session,
                ":srv 005 me PREFIX=(ov)@+ CHANTYPES=# :are supported",
                ":me!u@h JOIN #alpha",
                ":srv 353 me = #alpha :@alice +bob me",
                ":srv 366 me #alpha :End of /NAMES list.",
                ":srv 332 me #alpha :Welcome to #alpha")
        let channel = try XCTUnwrap(session.buffer(named: "#ALPHA"))
        XCTAssertTrue(channel.isJoined)
        XCTAssertEqual(channel.topic, "Welcome to #alpha")
        XCTAssertEqual(session.sortedMembers(of: channel).map(\.nick), ["alice", "bob", "me"])

        receive(session, ":alice!a@h MODE #alpha +v-o me alice")
        XCTAssertEqual(channel.members["me"]?.prefixes, "+")
        XCTAssertEqual(channel.members["alice"]?.prefixes, "")
        XCTAssertEqual(session.sortedMembers(of: channel).map(\.nick), ["bob", "me", "alice"])

        receive(session, ":carol!c@h JOIN #alpha", ":bob!b@h PART #alpha :bye")
        XCTAssertNotNil(channel.members["carol"])
        XCTAssertNil(channel.members["bob"])

        receive(session, ":me!u@h PART #alpha")
        XCTAssertFalse(channel.isJoined)
        XCTAssertTrue(channel.members.isEmpty)
    }

    func testMessagesGoToTheRightBuffers() throws {
        let session = makeSession()
        receive(session,
                ":me!u@h JOIN #a",
                ":alice!a@h PRIVMSG #a :hello me, how are you",
                ":alice!a@h PRIVMSG me :psst",
                ":alice!a@h PRIVMSG #a :\u{01}ACTION waves\u{01}",
                ":NickServ!s@services NOTICE me :You are now identified",
                ":irc.example.org NOTICE * :*** Looking up your hostname")

        let channel = try XCTUnwrap(session.buffer(named: "#a"))
        XCTAssertEqual(session.selectedBufferID, channel.id, "the first channel joined is shown")
        let messages = channel.lines.filter(\.isActivity)
        XCTAssertEqual(messages.map(\.text), ["hello me, how are you", "waves", "You are now identified"])
        XCTAssertEqual(messages.map(\.kind), [.message, .action, .notice], "notices go where the user is")
        XCTAssertTrue(messages[0].isHighlight)

        let query = try XCTUnwrap(session.buffer(named: "alice"))
        XCTAssertEqual(query.kind, .query)
        XCTAssertEqual(query.lines.last?.text, "psst")
        XCTAssertEqual(query.unreadCount, 1, "the network's tab is not in front")

        XCTAssertTrue(session.serverBuffer.lines.contains { $0.text == "*** Looking up your hostname" })
    }

    func testUnreadCountsWhenNotShowing() throws {
        let session = makeSession()
        session.isFrontmost = true
        receive(session, ":me!u@h JOIN #a", ":me!u@h JOIN #b")
        let a = try XCTUnwrap(session.buffer(named: "#a"))
        let b = try XCTUnwrap(session.buffer(named: "#b"))
        session.selectedBufferID = a.id

        receive(session, ":x!x@h PRIVMSG #a :seen", ":x!x@h PRIVMSG #b :unseen", ":x!x@h PRIVMSG #b :me: ping")
        XCTAssertEqual(a.unreadCount, 0)
        XCTAssertEqual(b.unreadCount, 2)
        XCTAssertTrue(b.hasHighlight)

        session.selectedBufferID = b.id
        XCTAssertEqual(b.unreadCount, 0)
        XCTAssertFalse(b.hasHighlight)
    }

    func testNickChangesRenameMembersAndQueries() throws {
        let session = makeSession()
        receive(session, ":me!u@h JOIN #a", ":srv 353 me = #a :me bob", ":bob!b@h PRIVMSG me :hi")
        receive(session, ":bob!b@h NICK robert")
        let channel = try XCTUnwrap(session.buffer(named: "#a"))
        XCTAssertNotNil(channel.members["robert"])
        XCTAssertNil(channel.members["bob"])
        XCTAssertNotNil(session.buffer(named: "robert"))

        receive(session, ":me!u@h NICK myself")
        session.handle(.nickChanged(old: "me", new: "myself"))
        XCTAssertEqual(session.nick, "myself")
        XCTAssertNotNil(channel.members["myself"])
        XCTAssertTrue(session.serverBuffer.lines.contains { $0.text == "You are now known as myself" })
    }

    func testQuitRemovesFromEveryChannel() throws {
        let session = makeSession()
        receive(session, ":me!u@h JOIN #a", ":me!u@h JOIN #b",
                ":srv 353 me = #a :me bob", ":srv 366 me #a :end",
                ":srv 353 me = #b :me bob", ":srv 366 me #b :end",
                ":bob!b@h QUIT :Ping timeout")
        for name in ["#a", "#b"] {
            let channel = try XCTUnwrap(session.buffer(named: name))
            XCTAssertNil(channel.members["bob"])
            XCTAssertEqual(channel.lines.last?.kind, .quit)
        }
    }

    func testConnectionLossMarksChannelsParted() throws {
        let session = makeSession()
        receive(session, ":me!u@h JOIN #a")
        session.handle(.connectionLost(reason: "Ping timeout"))
        let channel = try XCTUnwrap(session.buffer(named: "#a"))
        XCTAssertFalse(channel.isJoined)
        XCTAssertTrue(channel.wantsJoin, "rejoined on reconnect")
    }

    func testMentions() {
        let session = makeSession(nick: "Bob")
        XCTAssertTrue(session.mentionsMe("hey bob!"))
        XCTAssertTrue(session.mentionsMe("Bob: ping"))
        XCTAssertFalse(session.mentionsMe("bobby tables"))
        XCTAssertFalse(session.mentionsMe("kebob"))
    }

    func testWhoisIsKeptPerUser() throws {
        let session = makeSession()
        receive(session,
                ":srv 311 me Alice ~alice host.example * :Alice Smith",
                ":srv 312 me Alice tungsten.example :The server",
                ":srv 319 me Alice :@#a #b",
                ":srv 319 me Alice :#c",
                ":srv 330 me Alice alice_acct :is logged in as",
                ":srv 317 me Alice 300 1700000000 :seconds idle, signon time",
                ":srv 671 me Alice :is using a secure connection",
                ":srv 301 me Alice :lunch",
                ":srv 318 me Alice :End of /WHOIS list.")
        let info = try XCTUnwrap(session.userInfo(for: "alice"))
        XCTAssertEqual(info.username, "~alice")
        XCTAssertEqual(info.host, "host.example")
        XCTAssertEqual(info.realName, "Alice Smith")
        XCTAssertEqual(info.server, "tungsten.example")
        XCTAssertEqual(info.channels, ["@#a", "#b", "#c"])
        XCTAssertEqual(info.account, "alice_acct")
        XCTAssertEqual(info.idleSeconds, 300)
        XCTAssertEqual(info.awayMessage, "lunch")
        XCTAssertTrue(info.isSecure)
        XCTAssertTrue(info.summary.hasPrefix("Alice (~alice@host.example)\nReal name: Alice Smith"))

        receive(session, ":Alice!a@h NICK Alicia")
        XCTAssertNil(session.userInfo(for: "Alice"))
        XCTAssertEqual(session.userInfo(for: "alicia")?.realName, "Alice Smith", "follows a nick change")

        receive(session, ":srv 311 me Alicia ~a other.host * :New Name")
        XCTAssertEqual(session.userInfo(for: "Alicia")?.channels, [], "a new WHOIS starts over")
    }

    func testMemberFilterStaysWithTheChannelUntilClosed() throws {
        let session = makeSession()
        receive(session, ":me!u@h JOIN #a", ":me!u@h JOIN #b")
        let a = try XCTUnwrap(session.buffer(named: "#a"))
        a.memberFilter = "ali"
        session.selectedBufferID = try XCTUnwrap(session.buffer(named: "#b")).id
        session.selectedBufferID = a.id
        XCTAssertEqual(session.buffer(named: "#a")?.memberFilter, "ali", "kept while switching")

        session.close(a)
        receive(session, ":me!u@h JOIN #a")
        XCTAssertEqual(session.buffer(named: "#a")?.memberFilter, "", "closing the channel forgets it")
    }

    func testChannelListIsCollectedNotPrinted() {
        let session = makeSession()
        session.handle(.stateChanged(.registered))
        session.requestChannelList()
        XCTAssertTrue(session.isListingChannels)
        let before = session.serverBuffer.lines.count
        receive(session,
                ":srv 321 me Channel :Users  Name",
                ":srv 322 me #alpha 120 :\u{02}Swift\u{02} talk",
                ":srv 322 me #india 2 :",
                ":srv 323 me :End of /LIST")
        XCTAssertFalse(session.isListingChannels)
        XCTAssertEqual(session.channelList.map(\.name), ["#alpha", "#india"])
        XCTAssertEqual(session.channelList.first?.users, 120)
        XCTAssertEqual(session.channelList.first?.topic, "Swift talk")
        XCTAssertNotNil(session.channelListDate)
        XCTAssertEqual(session.serverBuffer.lines.count, before, "thousands of channels stay out of the window")
    }

    func testChannelListShowsWhileItComes() async throws {
        let session = makeSession()
        session.handle(.stateChanged(.registered))
        session.requestChannelList()
        receive(session, ":srv 322 me #first 5 :one")
        try await Task.sleep(for: .milliseconds(450))
        receive(session, ":srv 322 me #second 3 :two")
        XCTAssertTrue(session.isListingChannels)
        XCTAssertEqual(session.channelList.map(\.name), ["#first", "#second"], "shown before the end")
        receive(session, ":srv 322 me #third 1 :three", ":srv 323 me :End of /LIST")
        XCTAssertEqual(session.channelList.count, 3)

        session.requestChannelList()
        XCTAssertTrue(session.channelList.isEmpty, "a refresh fills the list anew")
    }

    func testGoingBackAndToUnreadConversations() throws {
        let session = makeSession()
        receive(session, ":me!u@h JOIN #a", ":me!u@h JOIN #b", ":me!u@h JOIN #c")
        let a = try XCTUnwrap(session.buffer(named: "#a")), b = try XCTUnwrap(session.buffer(named: "#b"))
        let c = try XCTUnwrap(session.buffer(named: "#c"))
        session.selectedBufferID = c.id
        session.selectedBufferID = a.id
        session.selectPreviousBuffer()
        XCTAssertEqual(session.selectedBufferID, c.id)
        session.selectPreviousBuffer()
        XCTAssertEqual(session.selectedBufferID, a.id, "back and forth")

        session.serverBuffer.markRead()
        receive(session, ":x!x@h PRIVMSG #b :new", ":x!x@h PRIVMSG me :private")
        XCTAssertTrue(session.selectUnreadBuffer(offset: 1))
        XCTAssertEqual(session.selectedBufferID, b.id)
        XCTAssertTrue(session.selectUnreadBuffer(offset: 1))
        XCTAssertEqual(session.selectedBuffer?.name, "x")
        XCTAssertFalse(session.selectUnreadBuffer(offset: -1), "all read now")
    }

    func testIdlenessFromMessagesAndWhois() {
        let session = makeSession()
        receive(session, ":me!u@h JOIN #a", "@time=2026-01-01T10:00:00.000Z :alice!a@h PRIVMSG #a :hi")
        XCTAssertEqual(session.lastActive("ALICE"), ISO8601DateFormatter().date(from: "2026-01-01T10:00:00Z"))
        receive(session, ":srv 311 me bob ~b h * :Bob", ":srv 317 me bob 120 1700000000 :seconds idle")
        let bob = session.lastActive("bob")
        XCTAssertEqual(bob.map { Date.now.timeIntervalSince($0) } ?? 0, 120, accuracy: 5)
        XCTAssertNil(session.lastActive("carol"))

        let now = Date.now
        XCTAssertEqual(Activity(since: now.addingTimeInterval(-30), now: now), .active)
        XCTAssertEqual(Activity(since: now.addingTimeInterval(-120), now: now), .recent)
        XCTAssertEqual(Activity(since: now.addingTimeInterval(-600), now: now), .idle)
        XCTAssertEqual(Activity(since: now.addingTimeInterval(-3600), now: now), .gone)
    }

    func testKnowsWhetherPrivateChatPartnersAreOnline() throws {
        let session = makeSession()
        session.handle(.stateChanged(.registered))
        receive(session, ":bob!b@h PRIVMSG me :hi")
        let bob = try XCTUnwrap(session.buffer(named: "bob"))
        XCTAssertEqual(bob.partnerOnline, true, "just wrote")
        receive(session, ":bob!b@h QUIT :bye")
        XCTAssertEqual(bob.partnerOnline, false)
        receive(session, ":me!u@h JOIN #a", ":srv 353 me = #a :me @Bob")
        XCTAssertEqual(bob.partnerOnline, true, "seen in a channel")

        let carol = session.openBuffer(named: "carol", kind: .query)
        let dave = session.openBuffer(named: "dave", kind: .query)
        receive(session, ":srv 303 me :", ":srv 303 me :")  // the two ISONs sent on opening
        XCTAssertEqual(carol.partnerOnline, false)
        session.checkPresence()
        receive(session, ":srv 303 me :Dave bob")
        XCTAssertEqual(dave.partnerOnline, true)
        XCTAssertEqual(carol.partnerOnline, false)
        receive(session, ":srv 401 me bob :No such nick/channel")
        XCTAssertEqual(bob.partnerOnline, false)
        XCTAssertFalse(session.serverBuffer.lines.contains { $0.text.hasPrefix("Online:") }, "own checks are quiet")

        session.handle(.stateChanged(.disconnected))
        XCTAssertNil(dave.partnerOnline, "not known while offline")
    }

    func testMissingSpaceAfterACommandIsInserted() {
        XCTAssertEqual(NetworkSession.insertingMissingSpace("/melooks around"), "/me looks around")
        XCTAssertEqual(NetworkSession.insertingMissingSpace("/MEwaves"), "/ME waves")
        XCTAssertEqual(NetworkSession.insertingMissingSpace("/join#alpha"), "/join #alpha")
        XCTAssertEqual(NetworkSession.insertingMissingSpace("/msgbob hi there"), "/msg bob hi there")
        XCTAssertEqual(NetworkSession.insertingMissingSpace("/nickpeter_"), "/nick peter_")
        XCTAssertNil(NetworkSession.insertingMissingSpace("/me looks"), "already spaced")
        XCTAssertNil(NetworkSession.insertingMissingSpace("/nickserv identify x"), "a command of its own")
        XCTAssertNil(NetworkSession.insertingMissingSpace("/memoserv list"))
        XCTAssertNil(NetworkSession.insertingMissingSpace("/whowas bob"))
        XCTAssertNil(NetworkSession.insertingMissingSpace("/motd"))
        XCTAssertNil(NetworkSession.insertingMissingSpace("/jfoo"), "one-letter aliases are not split")

        let session = makeSession()
        session.handle(.stateChanged(.registered))
        receive(session, ":me!u@h JOIN #a")
        let channel = session.buffer(named: "#a")!
        session.submit("/melooksaround", in: channel)
        XCTAssertEqual(channel.lines.last?.kind, .action)
        XCTAssertEqual(channel.lines.last?.text, "looksaround")
    }

    func testConversationsWithTheLoudspeakerOnAreReadAloud() throws {
        let session = makeSession()
        var spoken: [(String, String?)] = []
        var announced: [Bool] = []
        session.speak = { line, place, announcing, _ in
            spoken.append((line.text, place))
            announced.append(announcing)
        }
        receive(session, ":me!u@h JOIN #a", ":me!u@h JOIN #b", ":x!x@h PRIVMSG #a :not yet")
        let a = try XCTUnwrap(session.buffer(named: "#a"))
        a.speaks = true
        session.selectedBufferID = session.buffer(named: "#b")?.id
        receive(session, ":x!x@h PRIVMSG #a :hello", ":x!x@h PRIVMSG #b :quiet here", ":y!y@h JOIN #a")
        session.submit("my own", in: a)
        XCTAssertEqual(spoken.map(\.0), ["hello"], "others' messages, where the loudspeaker is on")
        XCTAssertEqual(spoken.first?.1, "#a", "says where, when it is not the one shown")
        XCTAssertEqual(announced.first, true, "and who")
        XCTAssertEqual(session.layout.buffers.first { $0.name == "#a" }?.speaks, true, "kept for the next launch")
        session.isFrontmost = true
        session.selectedBufferID = a.id
        receive(session, ":x!x@h PRIVMSG #a :on screen")
        XCTAssertEqual(announced.last, false, "the channel on screen: neither who nor where")
        XCTAssertNil(spoken.last?.1)
        session.isFrontmost = false

        receive(session, ":bob!b@h PRIVMSG me :first")
        let bob = try XCTUnwrap(session.buffer(named: "bob"))
        bob.speaks = true
        session.isFrontmost = true
        receive(session, ":bob!b@h PRIVMSG me :not shown yet")
        session.selectedBufferID = bob.id
        receive(session, ":bob!b@h PRIVMSG me :in front")
        XCTAssertEqual(Array(announced.suffix(2)), [false, false], "in a private chat, never who wrote it")

        XCTAssertEqual(Speaker.speakable("\u{02}look\u{02} https://example.org/x.png now"),
                       "look a link to example.org now")
    }

    func testHalfTypedTextStaysWithItsConversation() throws {
        let session = makeSession()
        receive(session, ":me!u@h JOIN #a", ":me!u@h JOIN #b")
        let a = try XCTUnwrap(session.buffer(named: "#a"))
        session.selectedBufferID = a.id
        a.draft = "a long text I was in the middle of"
        session.selectedBufferID = session.buffer(named: "#b")?.id
        session.selectedBufferID = a.id
        XCTAssertEqual(a.draft, "a long text I was in the middle of", "still there on coming back")

        let next = NetworkSession(config: session.config)
        next.restore(session.layout)
        XCTAssertEqual(next.buffer(named: "#a")?.draft, "a long text I was in the middle of", "and after a restart")
        XCTAssertEqual(next.buffer(named: "#b")?.draft, "")
    }

    func testAConversationIsKeptAsItWasClosedAndAcrossRestarts() throws {
        let session = makeSession()
        receive(session, ":bob!b@h PRIVMSG me :hi")
        let bob = try XCTUnwrap(session.buffer(named: "bob"))
        bob.speaks = true
        bob.search = "needle"
        bob.messagesOnly = true
        bob.anchorLine = 42
        bob.selection = TranscriptSelection(logID: 40, location: 7, length: 5)

        let next = NetworkSession(config: session.config)
        next.restore(try JSONDecoder().decode(BufferLayout.self, from: JSONEncoder().encode(session.layout)))
        let restored = try XCTUnwrap(next.buffer(named: "bob"))
        XCTAssertTrue(restored.speaks)
        XCTAssertEqual(restored.search, "needle")
        XCTAssertEqual(restored.anchorLine, 42, "where it was scrolled to")
        XCTAssertEqual(restored.selection, bob.selection, "and what was selected, after a restart")

        session.close(bob)
        XCTAssertNil(session.buffer(named: "bob"))
        receive(session, ":Bob!b@h PRIVMSG me :back again")
        let reopened = try XCTUnwrap(session.buffer(named: "bob"))
        XCTAssertTrue(reopened.speaks, "closed and opened again: as it was")
        XCTAssertEqual(reopened.search, "needle")
        XCTAssertTrue(reopened.messagesOnly)
        XCTAssertEqual(reopened.anchorLine, 42)
        XCTAssertTrue(session.closedBuffers.isEmpty, "taken back")

        session.close(reopened)
        let afterRestart = NetworkSession(config: session.config)
        afterRestart.restore(session.layout)
        XCTAssertNil(afterRestart.buffer(named: "bob"), "closed stays closed")
        afterRestart.openBuffer(named: "bob", kind: .query)
        XCTAssertEqual(afterRestart.buffer(named: "bob")?.search, "needle", "and comes back as it was")
    }

    func testMemosHaveAConversationOfTheirOwn() async throws {
        let session = makeSession()
        session.handle(.stateChanged(.registered))
        var sent: [String] = []
        session.sent = { sent.append($0.params.isEmpty ? $0.command : "\($0.command) \($0.params.joined(separator: " "))") }
        receive(session, ":bob!b@h PRIVMSG me :hi")
        XCTAssertEqual(session.queries.map(\.name), ["bob"], "not a private chat")
        XCTAssertTrue(session.buffers[1] === session.memoBuffer, "right under the server window")

        receive(session, ":MemoServ!s@services NOTICE me :You have 1 new memo.")
        XCTAssertTrue(session.memoBuffer.lines.contains { $0.text == "You have 1 new memo." })
        XCTAssertEqual(sent.last, "PRIVMSG MemoServ LIST", "a new memo: the inbox is fetched at once")
        receive(session, ":MemoServ!s@services NOTICE me :- 1 From: bob Sent: Oct 16 10:00:00 2026 [unread]")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(session.memos.inbox.map(\.from), ["bob"], "MemoServ's lines reach the mailbox")

        session.memoCommand("SEND alice see you tomorrow")
        XCTAssertEqual(sent.last, "PRIVMSG MemoServ SEND alice see you tomorrow")
        XCTAssertEqual(session.memoBuffer.lines.last?.isSelf, true, "shown as sent")

        session.close(session.memoBuffer)
        XCTAssertTrue(session.buffers.contains { $0 === session.memoBuffer }, "cannot be closed")
        session.selectedBufferID = session.serverBuffer.id
        session.selectBuffer(offset: 1)
        XCTAssertEqual(session.selectedBufferID, session.memoBuffer.id, "next after the server window")
    }

    func testPrivateChatListsBothSides() throws {
        let session = makeSession()
        receive(session, ":bob!b@h PRIVMSG me :hi")
        let query = try XCTUnwrap(session.buffer(named: "bob"))
        XCTAssertEqual(session.sortedMembers(of: query).map(\.nick), ["me", "bob"])
    }

    func testUsernameAndRealNameAreNeverMadeUp() {
        let identity = Identity(nick: "peter", alternateNicks: [], username: "", realName: "")
        let config = NetworkConfig(name: "N", host: "h").serverConfig(defaults: identity)
        XCTAssertEqual(config.username, "peter", "the server needs one, so the nick goes")
        XCTAssertEqual(config.realName, "peter")
    }
}

/// Commands, through a real client talking to the fake server.
@MainActor
final class NetworkSessionCommandTests: XCTestCase {

    private func connectedSession(perform: [String] = [], expectJoin: Bool = true) async -> (NetworkSession, FakeTransport) {
        let fake = FakeTransport()
        var config = NetworkConfig(name: "Test", host: "h", nick: "me")
        config.autoJoin = ["#auto"]
        config.performCommands = perform
        config.username = "me"
        config.realName = "me"
        let session = NetworkSession(config: config) {
            var config = $0
            config.timeouts.floodBurst = .seconds(1000)
            return IRCClient(config: config, makeTransport: { _ in fake })
        }
        session.connect()
        await fake.expect("CAP LS 302", "NICK me", "USER me 0 * me")
        fake.serverSends(":srv CAP * LS :", ":srv 001 me :Welcome")
        await fake.expect("CAP END")
        if expectJoin { await fake.expect("JOIN #auto") }
        return (session, fake)
    }

    func testCommandsBecomeProtocolLines() async {
        let (session, server) = await connectedSession()
        server.serverSends(":me!u@h JOIN #auto")
        try? await Task.sleep(for: .milliseconds(100))
        let channel = session.openBuffer(named: "#auto", kind: .channel)
        XCTAssertTrue(channel.isJoined)

        session.submit("/join alpha", in: channel)
        await server.expect("JOIN #alpha")
        session.submit("hello there", in: channel)
        await server.expect("PRIVMSG #auto :hello there")
        session.submit("/me waves", in: channel)
        await server.expect("PRIVMSG #auto :\u{01}ACTION waves\u{01}")
        session.submit("/msg bob hi bob", in: channel)
        await server.expect("PRIVMSG bob :hi bob")
        session.submit("/topic new topic", in: channel)
        await server.expect("TOPIC #auto :new topic")
        session.submit("/mode +o bob", in: channel)
        await server.expect("MODE #auto +o bob")
        session.submit("/part see you", in: channel)
        await server.expect("PART #auto :see you")
        session.submit("//slash", in: channel)
        await server.expect("PRIVMSG #auto /slash")
        session.submit("/list >10", in: channel)
        await server.expect("LIST >10")

        // Without echo-message, own lines are shown at once.
        XCTAssertTrue(channel.lines.contains { $0.isSelf && $0.text == "hello there" })
    }

    func testStartupCommandsRunBeforeJoiningAndQuietly() async {
        let (session, server) = await connectedSession(
            perform: ["/msg NickServ IDENTIFY secret", "/wait 0.2", "MODE me +x", "/quote AWAY :here"],
            expectJoin: false)
        await server.expect("PRIVMSG NickServ :IDENTIFY secret", "MODE me +x", "AWAY here")
        server.serverSends(":srv 900 me me!u@h me :You are now logged in as me")
        await server.expect("JOIN #auto")
        XCTAssertFalse(session.buffers.flatMap(\.lines).contains { $0.text.contains("secret") }, "not shown")
        XCTAssertNil(session.buffer(named: "NickServ"), "no chat opened for it")
    }

    func testCTCPAnswersAreTheAppsToGive() async {
        let (session, server) = await connectedSession()
        session.clientVersion = { "MyClient 1" }
        server.serverSends(":bob!b@h PRIVMSG me :\u{01}VERSION\u{01}")
        await server.expect("NOTICE bob :\u{01}VERSION MyClient 1\u{01}")

        // A flood of queries gets one answer every two seconds.
        server.serverSends(":bob!b@h PRIVMSG me :\u{01}PING 1\u{01}")
        try? await Task.sleep(for: .milliseconds(2100))
        session.clientVersion = { nil }
        session.highlightRules = { HighlightRules(ignores: [IgnoreEntry(nick: "troll")]) }
        server.serverSends(":bob!b@h PRIVMSG me :\u{01}VERSION\u{01}",
                           ":troll!t@h PRIVMSG me :\u{01}PING 2\u{01}",
                           ":bob!b@h PRIVMSG #auto :\u{01}PING 3\u{01}",
                           ":bob!b@h PRIVMSG me :\u{01}PING 4\u{01}")
        await server.expect("NOTICE bob :\u{01}PING 4\u{01}")
    }

    func testChannelsWaitForTheNickServLogin() async throws {
        let (session, server) = await connectedSession(perform: ["/msg NickServ IDENTIFY secret"], expectJoin: false)
        await server.expect("PRIVMSG NickServ :IDENTIFY secret")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(session.isLoggedIn)
        server.serverSends(":srv 900 me me!u@h me :You are now logged in as me")
        await server.expect("JOIN #auto")
    }

    func testRefusedChannelsAreJoinedAgainOnceLoggedIn() async throws {
        let (session, server) = await connectedSession()
        server.serverSends(":srv 477 me #auto :You need to be identified to a registered account to join this channel")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.buffer(named: "#auto")?.lines.last?.kind, .error, "said in the channel")
        server.serverSends(":NickServ!s@services MODE me +r")
        await server.expect("JOIN #auto")
    }

    func testAutomaticRepliesGoOutAfterAMoment() async {
        let (session, server) = await connectedSession()
        session.autoReplyDelay = { .milliseconds(50) }
        session.autoReply = { line, kind in kind == .query && line.text == "hi" ? "Hello!" : nil }
        server.serverSends(":bob!b@h PRIVMSG me :hi", ":bob!b@h PRIVMSG me :something else")
        // Opening the private chat asks whether bob is online, first.
        await server.expect("ISON bob", "PRIVMSG bob Hello!")
        XCTAssertEqual(session.buffer(named: "bob")?.lines.last { $0.isSelf }?.text, "Hello!", "shown as sent")
    }

    func testAutomaticRepliesAreReadAloudLikeOthersLines() async throws {
        let (session, server) = await connectedSession()
        var spoken: [String] = []
        session.speak = { line, _, _, _ in spoken.append("\(line.sender ?? ""): \(line.text)") }
        session.autoReplyDelay = { .milliseconds(50) }
        session.autoReply = { line, _ in line.text == "hi" ? "Hello!" : nil }
        session.openBuffer(named: "bob", kind: .query).speaks = true
        server.serverSends(":bob!b@h PRIVMSG me :hi")
        await server.expect("ISON bob", "PRIVMSG bob Hello!")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(spoken, ["bob: hi", "me: Hello!"], "what the user typed is not read; what went by itself is")
    }

    func testConversationsAreArrangedByDragging() async {
        let (session, _) = await connectedSession()
        for name in ["#b", "carol", "#c", "#a"] {
            session.openBuffer(named: name, kind: name.hasPrefix("#") ? .channel : .query)
        }
        let before = session.channels.map(\.name)
        XCTAssertEqual(Array(before.suffix(3)), ["#b", "#c", "#a"], "new ones at the end, as opened")
        session.moveBuffers(of: .channel, from: [before.count - 1], to: 0)
        XCTAssertEqual(session.channels.first?.name, "#a")
        XCTAssertEqual(session.queries.map(\.name), ["carol"], "private chats stay where they were")
        XCTAssertEqual(session.layout.buffers.filter { $0.kind == .channel }.map(\.name), session.channels.map(\.name),
                       "and the order is saved")
        XCTAssertEqual(session.layout.userOrdered, true)

        var old = session.layout
        old.userOrdered = nil
        old.buffers.reverse()
        let restored = NetworkSession(config: session.config)
        restored.restore(old)
        let names = restored.channels.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                       "a layout from before is sorted by name once")
    }

    func testJoiningManyChannelsAtOnce() async {
        let (session, server) = await connectedSession()
        let channels = (0..<60).map { "#channel-number-\($0)" }
        session.join(channels)
        var joined: [String] = []
        while joined.count < channels.count, let line = await server.nextLine() {
            XCTAssertTrue(line.hasPrefix("JOIN "))
            XCTAssertLessThan(line.utf8.count, 450, "split over several lines")
            joined += line.dropFirst(5).split(separator: ",").map(String.init)
        }
        XCTAssertEqual(joined, channels)
    }

    func testWhoisForSeveralUsersGoesOneAtATimeAndQuietly() async throws {
        let (session, server) = await connectedSession()
        session.whoisSpacing = .milliseconds(300)
        session.queueWhois(["alice", "bob", "me"])
        await server.expect("WHOIS alice")
        XCTAssertEqual(session.whoisQueue, ["bob"], "not yourself, and one at a time")

        server.serverSends(":srv 311 me alice ~a host.example * :Alice A", ":srv 318 me alice :End of /WHOIS list.")
        await server.expect("WHOIS bob")
        server.serverSends(":srv 401 me bob :No such nick/channel")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(session.userInfo(for: "alice")?.realName, "Alice A")
        XCTAssertTrue(session.whoisQueue.isEmpty)
        let printed = session.buffers.flatMap(\.lines).map(\.text)
        XCTAssertFalse(printed.contains { $0.contains("Alice A") || $0.contains("No such nick") },
                       "kept for the member list, not printed")
    }

    func testLongMessagesAreSplit() async {
        let (session, server) = await connectedSession()
        server.serverSends(":me!u@h JOIN #auto")
        try? await Task.sleep(for: .milliseconds(100))
        let channel = session.openBuffer(named: "#auto", kind: .channel)
        let words = Array(repeating: "word", count: 200).joined(separator: " ")
        session.submit(words, in: channel)
        let limit = IRCTextSplitter.maximumTextBytes(command: "PRIVMSG", target: "#auto", nick: "me")
        var sent = ""
        while sent.count < words.count {
            guard let line = await server.nextLine(), line.hasPrefix("PRIVMSG #auto :") else { break }
            let text = String(line.dropFirst("PRIVMSG #auto :".count))
            XCTAssertLessThanOrEqual(text.utf8.count, limit)
            sent += sent.isEmpty ? text : " " + text
        }
        XCTAssertEqual(sent, words)
    }
}

final class TextAndFormattingTests: XCTestCase {

    func testSplitterPrefersSpacesAndKeepsCharactersWhole() {
        XCTAssertEqual(IRCTextSplitter.split("aaa bbb ccc", maxBytes: 7), ["aaa bbb", "ccc"])
        XCTAssertEqual(IRCTextSplitter.split("abcdefgh", maxBytes: 3), ["abc", "def", "gh"])
        XCTAssertEqual(IRCTextSplitter.split("ééé", maxBytes: 3), ["é", "é", "é"])
        XCTAssertEqual(IRCTextSplitter.split("", maxBytes: 10), [""])
    }

    func testReverseSwapsTheColours() {
        // Once crashed the app: a channel topic with ^V in the channel list.
        XCTAssertEqual(IRCFormatting.strip("\u{03}4,2red on navy\u{16}reversed\u{16} back"),
                       "red on navyreversed back")
        let runs = IRCFormatting.runs("\u{03}4,2a\u{16}b")
        XCTAssertEqual(runs.map(\.text), ["a", "b"])
        XCTAssertEqual(runs[1].style.foreground, .index(2))
        XCTAssertEqual(runs[1].style.background, .index(4))
        XCTAssertEqual(IRCFormatting.strip("\u{16}\u{16}\u{16}x"), "x")
    }

    func testFormattingCodesAreRemovedFromText() {
        XCTAssertEqual(IRCFormatting.strip("\u{02}bold\u{02} \u{03}4,1red\u{03} \u{1D}it\u{0F}"), "bold red it")
        XCTAssertEqual(IRCFormatting.strip("\u{03}12,05x"), "x")
        XCTAssertEqual(IRCFormatting.strip("\u{03}4,text"), ",text", "a comma without a digit is text")
        XCTAssertEqual(IRCFormatting.strip("\u{04}ff0000red"), "red")
    }

    func testColoursAreParsed() {
        let runs = IRCFormatting.runs("\u{03}04,01red\u{03}52ext\u{03}99plain\u{04}FF8800,000080hex\u{04}x")
        XCTAssertEqual(runs.map(\.text), ["red", "ext", "plain", "hex", "x"])
        XCTAssertEqual(runs[0].style.foreground, .index(4))
        XCTAssertEqual(runs[0].style.background, .index(1))
        XCTAssertEqual(runs[1].style.foreground, .index(52), "the extended colours")
        XCTAssertNil(runs[2].style.foreground, "99 is the default colour")
        XCTAssertEqual(runs[3].style.foreground, .rgb(0xFF8800))
        XCTAssertEqual(runs[3].style.background, .rgb(0x000080))
        XCTAssertNil(runs[4].style.foreground, "^D without a colour resets")
        XCTAssertEqual(IRCFormatting.strip("\u{04}12x"), "12x", "not six hex digits: text")
    }

    func testColourCodesAlwaysHaveTwoDigits() {
        XCTAssertEqual(FormatCode.colour(foreground: 4), "\u{03}04")
        XCTAssertEqual(FormatCode.colour(foreground: nil, background: 2), "\u{03}99,02")
        let runs = IRCFormatting.runs(FormatCode.colour(foreground: 4) + "2 apples")
        XCTAssertEqual(runs.first?.text, "2 apples")
    }

    func testMessagesOnlyKeepsWhatPeopleWrote() {
        func line(_ kind: ChatLine.Kind, _ text: String) -> ChatLine {
            ChatLine(time: .now, kind: kind, sender: "bob", text: text)
        }
        XCTAssertTrue(line(.message, "hello").isConversation)
        XCTAssertTrue(line(.action, "waves").isConversation)
        XCTAssertFalse(line(.message, "ok").isConversation)
        XCTAssertFalse(line(.message, "\u{02}k\u{02} ").isConversation, "codes and spaces do not count")
        for kind: ChatLine.Kind in [.join, .part, .quit, .kick, .nick, .mode, .topic, .info, .error, .notice] {
            XCTAssertFalse(line(kind, "something long").isConversation, "\(kind)")
        }
    }

    @MainActor
    func testLinksAreDetected() {
        let text = IRCFormatting.attributed("see https://example.org/x now")
        let links = text.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.org/x")!])
    }
}
