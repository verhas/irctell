import XCTest
@testable import Irctell

/// The suggestion queue, with a stand-in for the model.
@MainActor
final class ReplyQueueTests: XCTestCase {
    private var directory: URL!
    private var asked: [String] = []
    private var suggester: ReplySuggester!
    private let session = NetworkSession(config: NetworkConfig(name: "N", host: "h", nick: "me"))

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        asked = []
        suggester = ReplySuggester(settings: SettingsStore(fileURL: directory.appending(path: "settings.plist")))
        suggester.isModelAvailable = { true }
        suggester.settleDelay = .zero
        suggester.interruptAfter = .milliseconds(200)
        suggester.hardLimit = .seconds(1)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The model: answers after `delay`, or nil when stopped first.
    private func model(delay: @escaping (String) -> Duration = { _ in .milliseconds(20) }) {
        suggester.generate = { [weak self] request in
            await MainActor.run { self?.asked.append(request.conversation) }
            do {
                try await Task.sleep(for: delay(request.conversation))
            } catch {
                return nil
            }
            return "re: \(request.conversation)"
        }
    }

    private func chat(_ nick: String, says text: String = "hi") -> ChatBuffer {
        let buffer = ChatBuffer(kind: .query, name: nick)
        buffer.append(ChatLine(time: .now, kind: .message, sender: nick, text: text))
        return buffer
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async {
        let end = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testTheConversationInFrontGoesFirst() async {
        model()
        let bob = chat("bob"), carol = chat("carol"), dave = chat("dave")
        suggester.request(for: bob, in: session, foreground: false)
        suggester.request(for: carol, in: session, foreground: false)
        suggester.request(for: dave, in: session, foreground: true)
        await waitUntil { carol.suggestion != nil }
        XCTAssertEqual(asked, ["dave", "bob", "carol"])
        XCTAssertEqual(dave.suggestion, "re: dave")
        XCTAssertEqual(bob.suggestion, "re: bob")

        suggester.request(for: bob, in: session, foreground: true)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(asked.count, 3, "a message is answered once")
    }

    func testABackgroundOneTakingTooLongMakesWayAndComesBack() async {
        var slowOnce = true
        model { conversation in
            if conversation == "bob", slowOnce {
                slowOnce = false
                return .seconds(5)
            }
            return .milliseconds(20)
        }
        let bob = chat("bob"), dave = chat("dave")
        suggester.request(for: bob, in: session, foreground: false)
        await waitUntil { asked == ["bob"] }
        let start = ContinuousClock.now
        suggester.request(for: dave, in: session, foreground: true)
        await waitUntil { dave.suggestion != nil }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "stopped after interruptAfter, not left to run")
        await waitUntil { bob.suggestion != nil }
        XCTAssertEqual(asked, ["bob", "dave", "bob"], "tried again after the one in front")
        XCTAssertEqual(bob.suggestion, "re: bob")
    }

    func testNothingRunsPastTheHardLimit() async {
        model { _ in .seconds(30) }
        let dave = chat("dave")
        let start = ContinuousClock.now
        suggester.request(for: dave, in: session, foreground: true)
        await waitUntil { !self.suggester.isWorking(on: dave) }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertNil(dave.suggestion)
        suggester.request(for: dave, in: session, foreground: true)
        XCTAssertFalse(suggester.isWorking(on: dave), "not asked again for the same message")
    }

    func testABusyConversationStillGetsSuggestions() async {
        model { _ in .milliseconds(300) }
        suggester.settleDelay = .milliseconds(200)
        let channel = chat("#golf")
        // A line every 100 ms: faster than the settling, faster than the model.
        for index in 0..<12 {
            channel.append(ChatLine(time: .now, kind: .message, sender: "x", text: "line \(index)"))
            suggester.request(for: channel, in: session, foreground: true)
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(channel.suggestion, "one came while the lines kept coming")
        await waitUntil { channel.suggestionAnswers == channel.lines.last.map(ReplySuggester.key) }
        XCTAssertEqual(channel.suggestionAnswers, channel.lines.last.map(ReplySuggester.key), "and then the newest")
        XCTAssertLessThan(asked.count, 8, "not one per line")
    }

    func testNothingInTheBackgroundStartsWhileTheFrontSettles() async {
        model()
        suggester.settleDelay = .milliseconds(300)
        let bob = chat("bob"), dave = chat("dave")
        suggester.request(for: dave, in: session, foreground: true)
        suggester.request(for: bob, in: session, foreground: false)
        await waitUntil { bob.suggestion != nil }
        XCTAssertEqual(asked, ["dave", "bob"])
    }

    func testAfterARestartTheNewestLoggedMessageIsAnswered() async throws {
        model()
        let home = directory.appending(path: "log")
        let log = try LogStore(fileURL: home.appending(path: "logs.sqlite"))
        let config = NetworkConfig(name: "N", host: "h", nick: "me")
        let restarted = NetworkSession(config: config, log: log)
        log.append(ChatLine(time: .now, kind: .message, sender: "bob", text: "still there?"), networkID: config.id,
                   networkName: "N", bufferName: "bob", bufferKind: .query)
        let bob = ChatBuffer(kind: .query, name: "bob")
        XCTAssertTrue(bob.lines.isEmpty, "nothing came since launch")
        suggester.request(for: bob, in: restarted, foreground: true)
        await waitUntil { bob.suggestion != nil }
        XCTAssertEqual(bob.suggestion, "re: bob")
        suggester.request(for: bob, in: restarted, foreground: true)
        XCTAssertFalse(suggester.isWorking(on: bob), "read back from the log, still the same message")
    }

    func testNoneWhileTypingOrAfterOwnLine() async {
        model()
        let bob = chat("bob")
        bob.draft = "I was writing"
        suggester.request(for: bob, in: session, foreground: true)
        XCTAssertFalse(suggester.isWorking(on: bob))
        bob.draft = ""
        bob.append(ChatLine(time: .now, kind: .message, sender: "me", text: "bye", isSelf: true))
        suggester.request(for: bob, in: session, foreground: true)
        XCTAssertFalse(suggester.isWorking(on: bob), "the last word was mine")
    }

    /// The real model, from inside the app; run by hand with
    /// TEST_RUNNER_IRCTELL_REAL_MODEL=1.
    func testTheRealModelAnswersInTheApp() async throws {
        guard ProcessInfo.processInfo.environment["IRCTELL_REAL_MODEL"] != nil else {
            throw XCTSkip("set IRCTELL_REAL_MODEL to try the model")
        }
        print("MODEL available: \(ReplySuggester.shared.isModelAvailable()), reason: \(ReplySuggester.shared.unavailableReason ?? "none")")
        let lines = [ChatLine(time: .now, kind: .message, sender: "alice", text: "hi, how are you today?")]
        do {
            let answer = try await ReplySuggester.askModelThrowing(
                ReplyRequest(lines: lines, me: "verhas", conversation: "alice", isPrivate: true))
            print("MODEL answer: \(answer ?? "nil")")
        } catch {
            print("MODEL error: \(error)")
            XCTFail("\(error)")
        }
    }
}
