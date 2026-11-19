import AppKit
import XCTest
@testable import Irctell

/// Right-clicking a nick in the transcript, in an off-screen window that is
/// never made key.
@MainActor
final class TranscriptNickTests: XCTestCase {
    private var window: NSWindow!
    private var textView: TranscriptTextView!
    private var coordinator: TranscriptView.Coordinator!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 420, height: 320),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = TranscriptView.makeScrollView()
        scrollView.frame = window.contentView!.bounds
        scrollView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(scrollView)
        textView = (scrollView.documentView as! TranscriptTextView)
        coordinator = TranscriptView.Coordinator()
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        textView.linesIn = { [unowned coordinator = coordinator!] in coordinator.lines(in: $0) }
        let members: [String: String] = ["bob": "Bob", "alice": "alice", "carol": "carol", "dave": "dave", "x_y": "x_y"]
        textView.nickNamed = { members[$0.lowercased()] }
    }

    override func tearDown() async throws {
        window.close()
    }

    private func show(_ lines: [ChatLine]) {
        coordinator.show(lines)
        window.contentView!.layoutSubtreeIfNeeded()
        let layout = textView.layoutManager!
        layout.ensureLayout(for: textView.textContainer!)
    }

    private func message(_ sender: String, _ text: String, kind: ChatLine.Kind = .message) -> ChatLine {
        ChatLine(time: .now, kind: kind, sender: sender, text: text)
    }

    /// What a right-click at the view's point offers: the title of a nick's
    /// menu, or nil for the plain text menu.
    private func nickMenu(at point: NSPoint) throws -> String? {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: textView.convert(point, to: nil),
                                                     modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = textView.menu(for: event)
        return menu?.items.contains { $0.title == "Whois" } == true ? menu?.title : nil
    }

    /// Clicks all over each character of the occurrence of `word` and
    /// returns the places where the menu is not the nick's.
    private func misses(of word: String, nth: Int = 0, expecting nick: String) throws -> [String] {
        let layout = textView.layoutManager!, container = textView.textContainer!
        let text = textView.string as NSString
        var search = NSRange(location: 0, length: text.length)
        var found = text.range(of: word, options: [], range: search)
        for _ in 0..<nth {
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            found = text.range(of: word, options: [], range: search)
        }
        XCTAssertNotEqual(found.location, NSNotFound, word)
        var failures: [String] = []
        let origin = textView.textContainerOrigin
        for index in found.location..<NSMaxRange(found) {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = layout.location(forGlyphAt: glyph).x + line.minX
            let nextX = glyph + 1 < layout.numberOfGlyphs
                && layout.lineFragmentRect(forGlyphAt: glyph + 1, effectiveRange: nil).minY == line.minY
                ? layout.location(forGlyphAt: glyph + 1).x + line.minX
                : layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX
            for fractionX in [0.1, 0.5, 0.9] {
                for y in [line.minY + 0.5, line.midY, line.maxY - 0.5] {
                    let point = NSPoint(x: x + (nextX - x) * fractionX + origin.x, y: y + origin.y)
                    let got = try nickMenu(at: point)
                    if got != nick { failures.append("\(text.substring(with: NSRange(location: index, length: 1))) @\(fractionX),\(y - line.minY): \(got ?? "text menu")") }
                }
            }
        }
        return failures
    }

    func testEveryPartOfANickInATextGivesItsMenu() throws {
        show([message("alice", "hello Bob, are you there? carol: see the x_y thing"),
              message("carol", "some words first to take the line along to where it wraps, and then dave in the second line of it"),
              message("dave", "with bob's possessive form and more")])
        for (word, nth, nick) in [("Bob", 0, "Bob"), ("carol", 1, "carol"), ("x_y", 0, "x_y"), ("dave", 1, "dave"), ("bob", 0, "Bob")] {
            XCTAssertEqual(try misses(of: word, nth: nth, expecting: nick), [], word)
        }
    }

    func testNicksWithPunctuationAroundThem() throws {
        show([message("alice", "ask [Bob] or -carol- and _dave_ or {alice}, also `Bob` and Bob- too")])
        for (word, nth, nick) in [("Bob", 0, "Bob"), ("carol", 0, "carol"), ("dave", 0, "dave"), ("alice", 1, "alice"),
                                  ("Bob", 1, "Bob"), ("Bob", 2, "Bob")] {
            XCTAssertEqual(try misses(of: word, nth: nth, expecting: nick), [], "\(word) \(nth)")
        }
    }

    func testTheSenderOfALineIsANickEvenWhenGone() throws {
        show([message("gone_user", "I have left", kind: .message),
              message("notifier", "a notice", kind: .notice),
              message("waver", "waves", kind: .action)])
        XCTAssertEqual(try misses(of: "gone_user", expecting: "gone_user"), [])
        XCTAssertEqual(try misses(of: "notifier", expecting: "notifier"), [])
        XCTAssertEqual(try misses(of: "waver", expecting: "waver"), [])
        XCTAssertEqual(try misses(of: "<", expecting: "gone_user"), [], "the brackets belong to the nick")
    }

    func testAWordThatIsNoNickGivesTheTextMenu() throws {
        show([message("alice", "nothing here matches")])
        let misses = try misses(of: "nothing", expecting: "nothing")
        XCTAssertEqual(misses.count, 7 * 9, "not one click on it offers a nick's menu")
    }
}
