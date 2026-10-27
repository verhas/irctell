import XCTest
@testable import Irctell

/// Scripts, run for real: small bash and Python programs, with a network
/// session that records what would go to the server.
@MainActor
final class ScriptingTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var host: ScriptHost!
    private var settings: SettingsStore!
    private var session: NetworkSession!
    private var sent: [String] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = SettingsStore(fileURL: directory.appending(path: "settings.plist"))
        model = AppModel(store: NetworkStore(fileURL: directory.appending(path: "networks.plist"), usesKeychain: false),
                         settings: settings, log: try LogStore(fileURL: directory.appending(path: "logs.sqlite")))
        host = ScriptHost(store: ScriptStore(settings: settings))
        host.app = model
        model.testScriptHost = host
        let network = try XCTUnwrap(model.networks.first)
        if network.connectAtLaunch { model.toggleConnectAtLaunch(network.id) }
        model.open(network.id, connect: false)
        session = try XCTUnwrap(model.session(for: network.id))
        session.handle(.registered(nick: "me"))
        session.handle(.stateChanged(.registered))
        sent = []
        session.sent = { [weak self] message in self?.sent.append(message.serialized) }
        receive(":me!u@h JOIN #delta", ":me!u@h JOIN #other")
    }

    override func tearDown() async throws {
        for script in host.scripts { host.stop(script.id) }
        try? await Task.sleep(for: .milliseconds(200))
        try? FileManager.default.removeItem(at: directory)
    }

    private func receive(_ lines: String...) {
        for line in lines { session.handle(.received(IRCMessage(parsing: line)!)) }
    }

    /// A script file, executable.
    private func script(_ name: String, _ body: String) throws -> String {
        let file = directory.appending(path: name)
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    private func use(_ scripts: ScriptDefinition...) {
        ScriptStore(settings: settings).list = scripts
        host.reload()
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(6)) async {
        let end = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(30)) }
    }

    private func sentLines(_ prefix: String) -> [String] { sent.filter { $0.hasPrefix(prefix) } }

    // MARK: - Pieces

    func testWordsDurationsAndFilters() {
        XCTAssertEqual(ScriptDefinition.words(#"/usr/bin/python3 "my script.py" --name 'a b' c\ d"#),
                       ["/usr/bin/python3", "my script.py", "--name", "a b", "c d"])
        XCTAssertEqual(ScriptDefinition.words(#"echo """#), ["echo", ""])
        XCTAssertEqual(ScriptDefinition.seconds("10m"), 600)
        XCTAssertEqual(ScriptDefinition.seconds("30s"), 30)
        XCTAssertEqual(ScriptDefinition.seconds("2h"), 7200)
        XCTAssertNil(ScriptDefinition.seconds("soon"))

        let trigger = ScriptTrigger(on: "message", channels: "#delta*", notNicks: "*bot", text: #"^!roll\s+(\d+)d(\d+)"#)
        var event = ScriptEvent(on: "message", network: "Libera", channel: "#delta-night", nick: "bob", text: "!roll 2d6",
                                isSelf: false)
        let (matched, groups) = trigger.matches(event)
        XCTAssertTrue(matched)
        XCTAssertEqual(groups, ["2", "6"])
        event.nick = "dicebot"
        XCTAssertFalse(trigger.matches(event).0, "not nicks")
        event.nick = "bob"
        event.isSelf = true
        XCTAssertFalse(trigger.matches(event).0, "own lines left out by default")
        event.isSelf = false
        event.channel = "#other"
        XCTAssertFalse(trigger.matches(event).0)

        var permissions = ScriptPermissions()
        XCTAssertTrue(permissions.allowsSending(to: "#x", isChannel: true, isOrigin: false), "everything by default")
        permissions.sendTo = "origin"
        XCTAssertFalse(permissions.allowsSending(to: "#x", isChannel: true, isOrigin: false))
        permissions.sendTo = "#delta*"
        XCTAssertTrue(permissions.allowsSending(to: "#delta", isChannel: true, isOrigin: false))
        permissions.commands = ["msg", "me"]
        XCTAssertTrue(permissions.allowsCommand("ME"))
        XCTAssertFalse(permissions.allowsCommand("kick"))
    }

    // MARK: - The text protocol

    func testATextScriptAnswersWhereTheEventCameFrom() async throws {
        let path = try script("dice.sh", """
            #!/bin/bash
            echo "$IRCTELL_NICK rolled $1 dice with $2 sides in $IRCTELL_CHANNEL"
            echo "/me shakes the dice"
            echo "//slashes stay"
            """)
        use(ScriptDefinition(name: "Dice", command: [path],
                             triggers: [ScriptTrigger(on: "message", channels: "#delta", text: #"^!roll\s+(\d+)d(\d+)"#)]))
        receive(":bob!b@h PRIVMSG #delta :!roll 2d6", ":bob!b@h PRIVMSG #other :!roll 1d4")
        await waitUntil { self.sentLines("PRIVMSG #delta").count >= 3 }
        XCTAssertEqual(sentLines("PRIVMSG #delta"), [
            "PRIVMSG #delta :bob rolled 2 dice with 6 sides in #delta",
            "PRIVMSG #delta :\u{01}ACTION shakes the dice\u{01}",
            "PRIVMSG #delta :/slashes stay",
        ])
        XCTAssertTrue(sentLines("PRIVMSG #other").isEmpty, "another channel: no trigger")
    }

    func testOwnTypedLinesTriggerWhenAskedAndScriptsNeverAnswerThemselves() async throws {
        let dice = try script("roll.sh", "#!/bin/bash\necho \"$IRCTELL_NICK rolled 4\"\n")
        var roll = ScriptDefinition(name: "roll", command: [dice],
                                    triggers: [ScriptTrigger(on: "message", text: "^!roll")])
        use(roll)
        let games = try XCTUnwrap(session.buffer(named: "#delta"))
        session.submit("!roll", in: games)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(sentLines("PRIVMSG #delta"), ["PRIVMSG #delta !roll"], "own lines: not by default")

        roll.triggers[0].lines = "all"
        use(roll)
        session.submit("!roll", in: games)
        await waitUntil { self.sentLines("PRIVMSG #delta :me rolled").count == 1 }
        XCTAssertEqual(sentLines("PRIVMSG #delta :me rolled"), ["PRIVMSG #delta :me rolled 4"], "typed by me, answered")

        // A script answering every line, its own kind included: once only.
        let echo = try script("parrot.sh", "#!/bin/bash\necho \"parrot: $IRCTELL_TEXT\"\n")
        use(ScriptDefinition(name: "parrot", command: [echo], triggers: [ScriptTrigger(on: "message", lines: "all")]))
        sent = []
        session.submit("hello", in: games)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(sentLines("PRIVMSG #delta"), ["PRIVMSG #delta hello", "PRIVMSG #delta :parrot: hello"],
                       "its own line does not set it off again")
    }

    func testRunAndPrivateMessagesAndIgnoredNicks() async throws {
        let echo = try script("echo.sh", "#!/bin/bash\necho \"$IRCTELL_EVENT: $IRCTELL_ARGS$IRCTELL_TEXT\"\n")
        use(ScriptDefinition(name: "Echo", command: [echo],
                             triggers: [ScriptTrigger(on: "run"), ScriptTrigger(on: "private_message")]))
        let games = try XCTUnwrap(session.buffer(named: "#delta"))
        session.submit("/run echo hello there", in: games)
        await waitUntil { !self.sentLines("PRIVMSG #delta").isEmpty }
        XCTAssertEqual(sentLines("PRIVMSG #delta"), ["PRIVMSG #delta :run: hello therehello there"])

        receive(":carol!c@h PRIVMSG me :psst")
        await waitUntil { !self.sentLines("PRIVMSG carol").isEmpty }
        XCTAssertEqual(sentLines("PRIVMSG carol"), ["PRIVMSG carol :private_message: psst"], "back in the private chat")

        model.setIgnore("dave", scope: .everything, network: session.id)
        receive(":dave!d@h PRIVMSG me :hello?")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(sentLines("PRIVMSG dave").isEmpty, "ignored nicks reach no script by default")

        session.submit("/run nothing", in: games)
        XCTAssertTrue(games.lines.last?.text.contains("No script") == true)
    }

    func testDryRunShowsAndLimitsHold() async throws {
        let chatty = try script("chatty.sh", "#!/bin/bash\nfor i in 1 2 3 4 5 6; do echo \"line $i\"; done\n")
        var dry = ScriptDefinition(name: "Dry", command: [chatty], triggers: [ScriptTrigger(on: "run")])
        dry.permissions.dryRun = true
        var limited = ScriptDefinition(name: "Limited", command: [chatty], triggers: [ScriptTrigger(on: "run")])
        limited.linesPerMinute = 3
        let sleepy = try script("sleepy.sh", "#!/bin/bash\nsleep 30\necho never\n")
        var slow = ScriptDefinition(name: "Slow", command: [sleepy], triggers: [ScriptTrigger(on: "run")])
        slow.timeout = 1
        use(dry, limited, slow)
        let games = try XCTUnwrap(session.buffer(named: "#delta"))

        session.submit("/run dry", in: games)
        await waitUntil { games.lines.contains { $0.text.contains("would say: line 6") } }
        XCTAssertTrue(sentLines("PRIVMSG").isEmpty, "a dry run sends nothing")

        session.submit("/run limited", in: games)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(sentLines("PRIVMSG #delta").count, 3, "three lines a minute")

        session.submit("/run slow", in: games)
        await waitUntil { self.host.statuses[slow.id]?.running == 1 }
        await waitUntil({ self.host.statuses[slow.id]?.running == 0 }, timeout: .seconds(8))
        XCTAssertEqual(host.statuses[slow.id]?.running, 0, "stopped at its time limit")
        XCTAssertFalse(sentLines("PRIVMSG").contains { $0.contains("never") })
    }

    // MARK: - The JSON protocol

    func testAJSONServiceSubscribesRepliesAsksAndStores() async throws {
        let path = try script("bot.py", """
            #!/usr/bin/env python3
            import json, sys
            def send(**message):
                print(json.dumps(message), flush=True)
            for line in sys.stdin:
                message = json.loads(line)
                kind = message["type"]
                if kind == "hello":
                    send(type="subscribe", events=["message"], channels="#delta")
                    send(type="log", level="info", text="ready as " + message["script"])
                    print("subscribed", file=sys.stderr, flush=True)
                elif kind == "event" and message["text"] == "!who":
                    send(type="query", id="q-" + message["id"], what="members", network=message["network"],
                         channel=message["channel"])
                    send(type="store", key="asked", value={"by": message["nick"]})
                elif kind == "event" and message["text"] == "!stored":
                    send(type="query", id="s-" + message["id"], what="store", key="asked")
                elif kind == "event" and message["text"] == "!elsewhere":
                    send(type="say", id="x", network=message["network"], target="#other", text="sneaky")
                elif kind == "event":
                    send(type="reply", re=message["id"], text="heard " + message["nick"] + ": " + message["text"])
                elif kind == "result" and message["re"].startswith("q-"):
                    nicks = ", ".join(m["nick"] for m in message["members"])
                    send(type="say", network="\(session.displayName)", target="#delta", text="here: " + nicks)
                elif kind == "result" and message["re"].startswith("s-"):
                    send(type="say", network="\(session.displayName)", target="#delta", text="asked by " + message["value"]["by"])
                elif kind == "error":
                    print("error " + message["code"], file=sys.stderr, flush=True)
            """)
        var service = ScriptDefinition(name: "Bot", command: [path], mode: .service, protocol: .json)
        service.permissions.sendTo = "#delta"
        use(service)
        // Python can take a while to start: until it has subscribed, a message
        // reaches no one.
        await waitUntil({ self.host.statuses[service.id]?.errors.contains("subscribed") == true }, timeout: .seconds(10))
        try await Task.sleep(for: .milliseconds(200))
        receive(":bob!b@h PRIVMSG #delta :hi all")
        await waitUntil { self.sentLines("PRIVMSG #delta :heard").count == 1 }
        XCTAssertEqual(sentLines("PRIVMSG #delta :heard"), ["PRIVMSG #delta :heard bob: hi all"],
                       "state \(String(describing: host.statuses[service.id])) sent \(sent)")

        receive(":bob!b@h PRIVMSG #delta :!who")
        await waitUntil { !self.sentLines("PRIVMSG #delta :here").isEmpty }
        XCTAssertTrue(sentLines("PRIVMSG #delta :here").first?.contains("me") == true, "the members, asked")

        receive(":bob!b@h PRIVMSG #delta :!stored")
        await waitUntil { !self.sentLines("PRIVMSG #delta :asked").isEmpty }
        XCTAssertEqual(sentLines("PRIVMSG #delta :asked"), ["PRIVMSG #delta :asked by bob"], "kept in its store")

        receive(":bob!b@h PRIVMSG #delta :!elsewhere")
        await waitUntil { self.host.statuses[service.id]?.errors.contains("error not_permitted") == true }
        XCTAssertTrue(sentLines("PRIVMSG #other").isEmpty, "may send to #delta only")

        receive(":bob!b@h PRIVMSG #other :not subscribed")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(sent.contains { $0.contains("not subscribed") })
    }

    func testBadLinesAreAnsweredAndAFailingServiceIsRestarted() async throws {
        let counter = directory.appending(path: "starts.txt")
        let path = try script("flaky.sh", """
            #!/bin/bash
            echo started >> "\(counter.path)"
            echo "this is not json"
            read -r hello
            read -r answer
            echo "$answer" >&2
            exit 3
            """)
        let service = ScriptDefinition(name: "Flaky", command: [path], mode: .service, protocol: .json)
        use(service)
        await waitUntil({ (try? String(contentsOf: counter, encoding: .utf8))?.split(separator: "\n").count ?? 0 >= 2 },
                        timeout: .seconds(6))
        let starts = (try? String(contentsOf: counter, encoding: .utf8))?.split(separator: "\n").count ?? 0
        XCTAssertGreaterThanOrEqual(starts, 2, "restarted after failing")
        XCTAssertTrue(host.statuses[service.id]?.errors.contains { $0.contains("bad_json") } == true,
                      "told its line was not JSON")
    }
}
