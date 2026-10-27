import XCTest
@testable import Irctell

@MainActor
final class AutoReplyTests: XCTestCase {
    private var directory: URL!
    private var settings: SettingsStore!
    private var replier: AutoReplier!
    private let network = UUID()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        settings = SettingsStore(fileURL: directory.appending(path: "settings.plist"))
        replier = AutoReplier(settings: settings)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func line(_ text: String, from sender: String = "bob", kind: ChatLine.Kind = .message,
                      highlight: Bool = false) -> ChatLine {
        ChatLine(time: .now, kind: kind, sender: sender, text: text, isHighlight: highlight)
    }

    func testTheSamplesAnswerTheUsualThings() {
        let rules = AutoReplier.samples
        XCTAssertEqual(replier.rule(matching: "hi there")?.id, rules[0].id)
        XCTAssertEqual(replier.rule(matching: "\u{02}Hello\u{02}!")?.id, rules[0].id, "formatting does not get in the way")
        XCTAssertEqual(replier.rule(matching: "how are you?")?.id, rules[1].id)
        XCTAssertEqual(replier.rule(matching: "how r u")?.id, rules[1].id)
        XCTAssertEqual(replier.rule(matching: "asl?")?.id, rules[2].id)
        XCTAssertEqual(replier.rule(matching: "a/s/l pls")?.id, rules[2].id)
        XCTAssertEqual(replier.rule(matching: "are you there?")?.id, rules[3].id)
        XCTAssertEqual(replier.rule(matching: "thanks a lot")?.id, rules[4].id)
        XCTAssertEqual(replier.rule(matching: "ok bye")?.id, rules[5].id)
        XCTAssertNil(replier.rule(matching: "this is about something else"), "no 'hi' inside words")
        for rule in rules { XCTAssertNil(AutoReplier.error(in: rule.pattern), rule.pattern) }
    }

    func testOnlyWhenOnWhereAndHowOftenAllowed() {
        let now = Date.now
        XCTAssertNil(replier.reply(to: line("hi"), in: .query, network: network, me: "me", now: now), "off")
        settings.set(true, forKey: AutoReplier.enabledKey)

        let answer = replier.reply(to: line("hi"), in: .query, network: network, me: "me", now: now)
        XCTAssertTrue(answer?.contains("bob") == true || answer != nil, "\(answer ?? "nil")")
        XCTAssertFalse(answer?.contains("{nick}") ?? true, "the placeholder filled in")
        XCTAssertNil(replier.reply(to: line("hello"), in: .query, network: network, me: "me", now: now + 60),
                     "the same person, the same rule: not again soon")
        XCTAssertNil(replier.reply(to: line("hi", from: "carol"), in: .query, network: network, me: "me", now: now + 1),
                     "nobody within a few seconds of the last")
        XCTAssertNotNil(replier.reply(to: line("hi", from: "carol"), in: .query, network: network, me: "me",
                                      now: now + 5))
        XCTAssertNotNil(replier.reply(to: line("hi"), in: .query, network: network, me: "me", now: now + 11 * 60),
                        "after ten minutes")

        XCTAssertNil(replier.reply(to: line("hi", from: "dave"), in: .channel, network: network, me: "me", now: now + 1000),
                     "private chats only")
        settings.set(AutoReplyScope.mentions.rawValue, forKey: AutoReplier.scopeKey)
        XCTAssertNotNil(replier.reply(to: line("hi me", from: "dave", highlight: true), in: .channel, network: network,
                                      me: "me", now: now + 1010))
        XCTAssertNil(replier.reply(to: line("thanks", from: "erin", kind: .notice), in: .query, network: network,
                                   me: "me", now: now + 1020), "never a notice")
    }

    func testOwnRules() {
        settings.set(true, forKey: AutoReplier.enabledKey)
        replier.rules = [AutoReplyRule(pattern: "^ping$", replies: ["pong, {nick}, from {me}"])]
        XCTAssertEqual(replier.reply(to: line("PING"), in: .query, network: network, me: "peter"), "pong, bob, from peter")
        XCTAssertNil(replier.rule(matching: "hi"), "the samples are gone once there are own rules")
    }

    func testOnlyTheStartOfAPrivateConversationIsAnswered() {
        settings.set(true, forKey: AutoReplier.enabledKey)
        XCTAssertEqual(replier.startMessages, 4, "the first four messages by default")
        XCTAssertNotNil(replier.reply(to: line("hi"), in: .query, network: network, me: "me", position: 4))
        XCTAssertNil(replier.reply(to: line("hello", from: "carol"), in: .query, network: network, me: "me",
                                   position: 5, now: .now + 60), "the fifth message: talking already")
        settings.set(0, forKey: AutoReplier.startMessagesKey)
        XCTAssertNotNil(replier.reply(to: line("hello", from: "carol"), in: .query, network: network, me: "me",
                                      position: 50, now: .now + 60), "0: every message")

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func said(_ minutes: Double, _ kind: ChatLine.Kind = .message) -> ChatLine {
            ChatLine(time: start + minutes * 60, kind: kind, sender: "bob", text: "x")
        }
        XCTAssertEqual(AutoReplier.position(inConversation: []), 1)
        XCTAssertEqual(AutoReplier.position(inConversation: [said(0), said(1), said(2, .join), said(3)]), 3,
                       "joins and the like do not count")
        XCTAssertEqual(AutoReplier.position(inConversation: [said(0), said(1), said(50), said(52)]), 2,
                       "after half an hour of silence, a new conversation")
    }
}
