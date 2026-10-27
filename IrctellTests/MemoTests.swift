import XCTest
@testable import Irctell

/// The mailbox, from MemoServ's answers as Atheme (Libera.Chat) and Anope
/// word them.
@MainActor
final class MemoTests: XCTestCase {
    private var file: URL!
    private var commands: [String] = []

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appending(path: "memos-\(UUID().uuidString).json")
        commands = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func makeBox() -> MemoBox {
        let box = MemoBox(fileURL: file)
        box.command = { [weak self] in self?.commands.append($0) }
        return box
    }

    /// The listing ends when MemoServ stops talking.
    private func waitForListing(_ box: MemoBox) async {
        for _ in 0..<100 where box.isChecking { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testAthemeInboxReadSendAndDelete() async throws {
        let box = makeBox()
        box.check()
        XCTAssertEqual(commands, ["LIST"])
        for line in ["You have 2 memos (1 new).",
                     "- 1 From: bob Sent: Oct 16 10:00:00 2026 [unread]",
                     "- 2 From: carol Sent: Oct 15 09:12:44 2026"] {
            box.received(line)
        }
        await waitForListing(box)
        XCTAssertEqual(box.inbox.map(\.from), ["bob", "carol"])
        XCTAssertEqual(box.inbox.map(\.isUnread), [true, false])
        XCTAssertEqual(box.inbox[0].date, "Oct 16 10:00:00 2026")
        XCTAssertEqual(box.unreadCount, 1)

        box.open(box.inbox[0])
        XCTAssertEqual(commands.last, "READ 1")
        for line in ["Memo 1 - Sent by bob, Oct 16 10:00:00 2026", "------------------------------------------",
                     "see you at the meetup"] {
            box.received(line)
        }
        XCTAssertEqual(box.inbox[0].text, "see you at the meetup")
        XCTAssertFalse(box.inbox[0].isUnread, "read now")

        box.send(to: "alice", text: "thanks\nfor the help")
        XCTAssertEqual(commands.last, "SEND alice thanks for the help", "one line")
        XCTAssertEqual(box.outbox.first?.status, .sending)
        box.received("The memo has been successfully sent to \u{02}alice\u{02}.")
        XCTAssertEqual(box.outbox.first?.status, .delivered)

        box.send(to: "zed", text: "hello?")
        box.received("\u{02}zed\u{02} is not registered.")
        XCTAssertEqual(box.outbox.first?.status, .failed("zed is not registered."))

        box.delete(box.inbox[1])
        XCTAssertEqual(commands.last, "DEL 2")
        box.received("1 memo deleted.")
        XCTAssertEqual(commands.last, "LIST", "numbers move: listed again")
        box.received("You have 1 memo (0 new).")
        box.received("- 1 From: bob Sent: Oct 16 10:00:00 2026")
        await waitForListing(box)
        XCTAssertEqual(box.inbox.map(\.from), ["bob"])
        XCTAssertEqual(box.inbox[0].text, "see you at the meetup", "the text read stays")

        // Saved: there after a restart, also offline.
        let again = MemoBox(fileURL: file)
        XCTAssertEqual(again.inbox, box.inbox)
        XCTAssertEqual(again.outbox.map(\.status), [.failed("zed is not registered."), .delivered])
    }

    func testAnopeListingAndReading() async {
        let box = makeBox()
        box.check()
        for line in ["Memos for \u{02}me\u{02}. To read, type: \u{02}/msg MemoServ READ \u{1F}num\u{1F}\u{02}",
                     "  Num  Sender  Date/Time",
                     " * 1  bob     Oct 16 10:00:00 2026 UTC",
                     "   2  carol   Oct 15 09:12:44 2026 UTC"] {
            box.received(line)
        }
        await waitForListing(box)
        XCTAssertEqual(box.inbox.map(\.number), [1, 2])
        XCTAssertEqual(box.inbox.map(\.from), ["bob", "carol"])
        XCTAssertEqual(box.inbox.map(\.isUnread), [true, false])
        XCTAssertEqual(box.inbox[1].date, "Oct 15 09:12:44 2026 UTC")

        for line in ["Memo 1 from bob (Oct 16 10:00:00 2026 UTC).", "To delete, type: /msg MemoServ DEL 1",
                     "hello there"] {
            box.received(line)
        }
        XCTAssertEqual(box.inbox[0].text, "hello there")

        box.send(to: "alice", text: "hi")
        box.received("Memo sent to \u{02}alice\u{02}.")
        XCTAssertEqual(box.outbox.first?.status, .delivered)

        box.received("You have no memos.")
        XCTAssertTrue(box.inbox.isEmpty)
    }

    func testANewMemoIsListedAtOnce() {
        let box = makeBox()
        box.received("You have a new memo from \u{02}bob\u{02} (#3).")
        XCTAssertEqual(commands, ["LIST"])
        box.received("You have 2 new memos.")
        XCTAssertEqual(commands, ["LIST", "LIST"])
    }

    func testWhatIsNotUnderstoodIsShown() {
        let box = makeBox()
        box.received("Unknown command FOO. \"/msg MemoServ HELP\" for help.")
        XCTAssertEqual(box.status, "Unknown command FOO. \"/msg MemoServ HELP\" for help.")
        XCTAssertTrue(box.inbox.isEmpty)
    }
}
