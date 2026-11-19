import AppKit
import SwiftUI
import XCTest
@testable import Irctell

/// The input field's lines, in a view that is in no window that takes focus.
@MainActor
final class MessageEditorTests: XCTestCase {
    private var window: NSWindow!
    private var textView: MessageTextView!
    private var scrollView: NSScrollView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        textView = MessageTextView.make()
        scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.documentView = textView
        scrollView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(scrollView)
        textView.frame.size.width = 400
    }

    override func tearDown() async throws {
        window.close()
    }

    /// The characters each laid out line starts at.
    private func lineStarts() -> [Int] {
        let layout = textView.layoutManager!, container = textView.textContainer!
        layout.ensureLayout(for: container)
        var starts: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            starts.append(layout.characterIndexForGlyph(at: glyphs.location))
        }
        return starts
    }

    private func set(_ text: String, starts: [Int]) {
        textView.string = text
        textView.messageStarts = starts
    }

    func testAMessageBreakingAtASpaceStartsANewLine() {
        let first = "short message"
        let text = first + " second message"
        set(text, starts: [first.utf16.count + 1])
        XCTAssertEqual(lineStarts(), [0, first.utf16.count + 1])
        XCTAssertEqual(textView.string, text, "the text itself stays one piece")
    }

    func testAWordCutInTwoStartsANewLine() {
        let text = String(repeating: "x", count: 20) + String(repeating: "y", count: 20)
        set(text, starts: [20])
        XCTAssertEqual(lineStarts(), [0, 20])
    }

    func testThinCharactersAtTheCutStillBreak() {
        let text = String(repeating: "i", count: 11) + String(repeating: "l", count: 11)
        set(text, starts: [11])
        XCTAssertEqual(lineStarts(), [0, 11])
    }

    func testAMessageLongerThanALineWrapsAndThenBreaks() {
        let words = String(repeating: "lorem ipsum ", count: 30)
        let cut = words.utf16.count
        set(words + "next", starts: [cut])
        let starts = lineStarts()
        XCTAssertGreaterThan(starts.count, 3)
        XCTAssertEqual(starts.last, cut, "the next message on a line of its own")
        XCTAssertLessThan(starts[starts.count - 2], cut)
    }

    func testRoomIsLeftForTheThinLine() {
        set("one two", starts: [4])
        let layout = textView.layoutManager!
        layout.ensureLayout(for: textView.textContainer!)
        let first = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let second = layout.lineFragmentRect(forGlyphAt: 4, effectiveRange: nil)
        XCTAssertEqual(first.height, second.height + MessageTextView.separatorSpace, accuracy: 0.5)
        XCTAssertEqual(second.minY, first.maxY, accuracy: 0.5)
    }

    func testTypingAtTheBreakMovesTheLinesAlong() {
        set("aaa bbb", starts: [4])
        XCTAssertEqual(lineStarts(), [0, 4])
        textView.messageStarts = []
        XCTAssertEqual(lineStarts(), [0], "laid out again when the starts change")
        textView.messageStarts = [2]
        XCTAssertEqual(lineStarts(), [0, 2])
    }

    func testTheHeightGrowsUpToTheLimit() {
        textView.maxLines = 3
        let lineHeight = textView.wantedHeight
        textView.string = "one"
        XCTAssertEqual(textView.wantedHeight, lineHeight)
        textView.string = "one\ntwo"
        XCTAssertEqual(textView.wantedHeight, 2 * lineHeight, accuracy: 1)
        textView.string = "one\ntwo\n"
        XCTAssertEqual(textView.wantedHeight, 3 * lineHeight, accuracy: 1, "the new empty line counts")
        textView.string = (1...20).map(String.init).joined(separator: "\n")
        XCTAssertEqual(textView.wantedHeight, 3 * lineHeight, accuracy: 1)
    }

    /// Text ending right at the edge of a line, a space after a word most
    /// often: with a classic scroller (a mouse attached) the field went one
    /// line taller and back many times a second, the scroller coming and
    /// going and narrowing the text each time.
    func testTheHeightSettlesWhenTheTextEndsAtTheEdgeOfALine() async throws {
        let words = "the quick brown fox jumps over the lazy dog and keeps running far away from here "
        for cut in 28..<words.count {
            let text = String(words.prefix(cut))
            let field = MessageTextView.make()
            let scroll = MessageScrollView.make(around: field)
            scroll.scrollerStyle = .legacy // what the system asks for with a mouse
            scroll.frame = NSRect(x: 0, y: 0, width: 200, height: 17)
            window.contentView!.addSubview(scroll)
            defer { scroll.removeFromSuperview() }
            var reports = 0
            field.heightChanged = { height in
                reports += 1
                scroll.frame.size.height = height // what SwiftUI's frame(height:) does
            }
            field.string = text
            field.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            for _ in 0..<15 {
                field.reportHeight() // as after every SwiftUI update
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertLessThanOrEqual(reports, 2, "\"\(text)\": the height keeps changing")
        }
    }

    func testTheCaretKnowsItsLine() {
        textView.string = "one\ntwo\nthree"
        textView.layoutManager!.ensureLayout(for: textView.textContainer!)
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(textView.isCaretOnFirstLine)
        XCTAssertFalse(textView.isCaretOnLastLine)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertFalse(textView.isCaretOnFirstLine)
        XCTAssertFalse(textView.isCaretOnLastLine)
        textView.setSelectedRange(NSRange(location: 13, length: 0))
        XCTAssertTrue(textView.isCaretOnLastLine)
    }

    func testReplacedTextCanBeUndoneAndCarriesTheFont() throws {
        // An undo takes back what one event did: here each edit is one.
        let undo = try XCTUnwrap(textView.undoManager)
        undo.groupsByEvent = false
        func edit(_ text: String) {
            undo.beginUndoGrouping()
            textView.replaceText(with: text)
            undo.endUndoGrouping()
        }
        edit("hello")
        XCTAssertEqual(textView.selectedRange().location, 5, "the caret at the end")
        XCTAssertEqual(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, textView.font)
        edit("")
        XCTAssertEqual(textView.string, "")
        textView.undo(nil)
        XCTAssertEqual(textView.string, "hello")
    }

    // MARK: - Where the messages start

    private func session(nick: String = "me") -> (NetworkSession, ChatBuffer) {
        let session = NetworkSession(config: NetworkConfig(name: "N", host: "h", nick: nick))
        session.handle(.registered(nick: nick))
        session.handle(.stateChanged(.registered))
        return (session, session.openBuffer(named: "#room", kind: .channel))
    }

    func testAShortDraftIsOneMessage() {
        let (session, channel) = session()
        XCTAssertEqual(session.messageStarts(in: "hello there", for: channel), [])
        XCTAssertEqual(session.messageStarts(in: "", for: channel), [])
    }

    func testTheStartsAreWhereTheTextIsReallyCut() {
        let (session, channel) = session()
        let draft = (1...400).map { "word\($0)" }.joined(separator: " ")
        let limit = IRCTextSplitter.maximumTextBytes(command: "PRIVMSG", target: "#room", nick: "me")
        let pieces = IRCTextSplitter.split(draft, maxBytes: limit)
        XCTAssertGreaterThan(pieces.count, 2)
        let starts = session.messageStarts(in: draft, for: channel)
        XCTAssertEqual(starts.count, pieces.count - 1)
        let text = draft as NSString
        for (start, piece) in zip(starts, pieces.dropFirst()) {
            XCTAssertTrue(text.substring(from: start).hasPrefix(piece), "at \(start)")
        }
    }

    func testAccentsCountInBytesAndOffsetsInUTF16() {
        let (session, channel) = session()
        let draft = String(repeating: "é😀", count: 200)
        let limit = IRCTextSplitter.maximumTextBytes(command: "PRIVMSG", target: "#room", nick: "me")
        let pieces = IRCTextSplitter.split(draft, maxBytes: limit)
        XCTAssertEqual(session.messageStarts(in: draft, for: channel).first, pieces[0].utf16.count)
    }

    func testEachLineIsAMessage() {
        let (session, channel) = session()
        XCTAssertEqual(session.messageStarts(in: "one\ntwo\n\nthree", for: channel), [4, 9])
    }

    func testCommandsSendingTextAreCutToo() {
        let (session, channel) = session()
        let long = String(repeating: "a ", count: 400)
        XCTAssertFalse(session.messageStarts(in: "/me " + long, for: channel).isEmpty)
        XCTAssertFalse(session.messageStarts(in: "/msg bob " + long, for: channel).isEmpty)
        XCTAssertFalse(session.messageStarts(in: "//x " + long, for: channel).isEmpty)
        XCTAssertEqual(session.messageStarts(in: "/topic " + long, for: channel), [], "sent as one line")
        XCTAssertEqual(session.messageStarts(in: "/join #a", for: channel), [])
    }

    // MARK: - Return, ⌥Return

    /// A coordinator as the field has it; returns how many times it sent.
    private func coordinator(enterSends: Bool, sent: @escaping () -> Void) -> MessageEditor.Coordinator {
        let editor = MessageEditor(text: .constant(""), messageStarts: { _ in [] }, maxLines: 15, focusRequest: 0,
                                   heightChanged: { _ in }, submit: sent, enterSends: { enterSends },
                                   pastedAsSeveral: {}, complete: {}, browse: { _, _ in false }, formatKey: { _ in false })
        return MessageEditor.Coordinator(editor)
    }

    func testReturnSendsOrStartsANewMessage() {
        textView.string = "hello"
        var sent = 0
        let sending = coordinator(enterSends: true) { sent += 1 }
        XCTAssertTrue(sending.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(textView.string, "hello")

        let holding = coordinator(enterSends: false) { sent += 1 }
        XCTAssertTrue(holding.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(sent, 1, "not sent")
        XCTAssertEqual(textView.string, "hello\n")
    }

    func testOptionReturnBreaksTheMessageAtTheCaretAndSendsNothing() throws {
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        for keyCode: UInt16 in [36, 76] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
                                                       timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                                                       charactersIgnoringModifiers: "\r", isARepeat: false,
                                                       keyCode: keyCode))
            textView.keyDown(with: event)
        }
        XCTAssertEqual(textView.string, "hello\n\n world")
        XCTAssertEqual(textView.selectedRange().location, 7)
    }

    func testTheThreeReturnKeyModes() {
        let long = String(repeating: "word ", count: 400)
        XCTAssertTrue(EnterKeyMode.sends.sends(draft: "a\nb", pastedAsSeveral: true))
        XCTAssertFalse(EnterKeyMode.neverSends.sends(draft: "a", pastedAsSeveral: false))

        let mode = EnterKeyMode.sendsOneMessage
        XCTAssertTrue(mode.sends(draft: "a", pastedAsSeveral: false))
        XCTAssertTrue(mode.sends(draft: long, pastedAsSeveral: false), "typed in one go")
        XCTAssertFalse(mode.sends(draft: long, pastedAsSeveral: true), "pasted")
        XCTAssertFalse(mode.sends(draft: "a\nb", pastedAsSeveral: false))
        XCTAssertFalse(mode.sends(draft: "a\n", pastedAsSeveral: false), "⌥Return at the end")
    }

    func testAPasteCountsOnlyWhenItLeavesSeveralMessages() {
        var told = 0
        textView.pastedAsSeveral = { told += 1 }
        set("short", starts: [])
        textView.didPaste()
        XCTAssertEqual(told, 0)
        set("short long", starts: [6])
        textView.didPaste()
        XCTAssertEqual(told, 1)
    }

    func testALineBreakAtTheEndShowsTheNextMessage() {
        let (session, channel) = session()
        XCTAssertEqual(session.messageStarts(in: "hello\n", for: channel), [6])
        XCTAssertEqual(session.messageStarts(in: "\n", for: channel), [], "nothing before it")
        XCTAssertEqual(session.messageStarts(in: "hello\nworld", for: channel), [6])

        set("hello\n", starts: [6])
        let layout = textView.layoutManager!
        layout.ensureLayout(for: textView.textContainer!)
        let first = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        XCTAssertEqual(layout.extraLineFragmentRect.minY, first.maxY, "the caret's line is below the first")
        XCTAssertGreaterThan(first.height, layout.defaultLineHeight(for: textView.font!), "with room for the thin line")
        XCTAssertGreaterThanOrEqual(textView.wantedHeight, first.maxY + layout.extraLineFragmentRect.height - 1)
    }

    func testCommandWClosesTheConversationNotTheServerWindow() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = NetworkStore(fileURL: home.appending(path: "n.plist"), usesKeychain: false)
        let config = NetworkConfig(name: "N", host: "h", nick: "me")
        let model = AppModel(store: store, settings: SettingsStore(fileURL: home.appending(path: "s.plist")), log: nil)
        model.save(config)
        model.open(config.id, select: true, connect: false)
        let session = try XCTUnwrap(model.selectedSession)
        let chat = session.openBuffer(named: "bob", kind: .query)
        session.selectedBufferID = chat.id

        model.closeSelectedConversation()
        XCTAssertFalse(session.buffers.contains { $0 === chat })

        session.selectedBufferID = session.serverBuffer.id
        model.closeSelectedConversation()
        XCTAssertTrue(session.buffers.contains { $0 === session.serverBuffer })
        XCTAssertEqual(model.sessions.count, 1)
    }

    // MARK: - Who wrote last

    private func receive(_ session: NetworkSession, _ lines: String...) {
        for line in lines { session.handle(.received(IRCMessage(parsing: line)!)) }
    }

    private func channelWithMembers() -> (NetworkSession, ChatBuffer) {
        let (session, _) = session()
        receive(session, ":me!u@h JOIN #room",
                ":srv 353 me = #room :me anna +abel @arno carol",
                ":srv 366 me #room :End of /NAMES list.")
        return (session, session.buffer(named: "#room")!)
    }

    func testTabCompletionOffersWhoWroteLastFirst() {
        let (session, channel) = channelWithMembers()
        XCTAssertEqual(session.completions(for: "a", in: channel), ["abel", "anna", "arno"], "nobody wrote yet")
        receive(session, "@time=2026-01-01T10:00:00.000Z :arno!u@h PRIVMSG #room :first",
                "@time=2026-01-01T10:00:05.000Z :abel!u@h PRIVMSG #room :second")
        XCTAssertEqual(session.completions(for: "a", in: channel), ["abel", "arno", "anna"])
        receive(session, "@time=2026-01-01T10:00:09.000Z :arno!u@h PRIVMSG #room :again")
        XCTAssertEqual(session.completions(for: "a", in: channel), ["arno", "abel", "anna"])
    }

    func testWritingElsewhereDoesNotCount() {
        let (session, channel) = channelWithMembers()
        receive(session, ":me!u@h JOIN #other",
                "@time=2026-01-01T10:00:00.000Z :anna!u@h PRIVMSG #room :here",
                "@time=2026-01-01T11:00:00.000Z :abel!u@h PRIVMSG #other :over there")
        XCTAssertEqual(session.completions(for: "a", in: channel), ["anna", "abel", "arno"])
    }

    func testANewNickKeepsItsPlace() {
        let (session, channel) = channelWithMembers()
        receive(session, "@time=2026-01-01T10:00:00.000Z :abel!u@h PRIVMSG #room :hi",
                ":abel!u@h NICK :adam")
        XCTAssertEqual(session.completions(for: "a", in: channel).first, "adam")
    }

    func testTheMemberOrders() {
        let (session, channel) = channelWithMembers()
        receive(session, "@time=2026-01-01T10:00:00.000Z :carol!u@h PRIVMSG #room :one",
                "@time=2026-01-01T10:00:05.000Z :anna!u@h PRIVMSG #room :two")
        XCTAssertEqual(session.sortedMembers(of: channel, order: .alphabetical).map(\.nick),
                       ["abel", "anna", "arno", "carol", "me"])
        XCTAssertEqual(session.sortedMembers(of: channel, order: .recent).map(\.nick),
                       ["anna", "carol", "abel", "arno", "me"])
        XCTAssertEqual(session.sortedMembers(of: channel, order: .voicedFirst).map(\.nick),
                       ["arno", "abel", "anna", "carol", "me"])
    }

    func testAfterLaunchTheOrderComesFromTheLog() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "recent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try LogStore(fileURL: directory.appending(path: "logs.sqlite"))
        let session = NetworkSession(config: NetworkConfig(name: "N", host: "h", nick: "me"), log: log)
        session.handle(.registered(nick: "me"))
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, sender) in ["bob", "alice"].enumerated() {
            log.append(ChatLine(time: then + Double(offset), kind: .message, sender: sender, text: "hi"), networkID: session.id,
                       networkName: "N", bufferName: "#room", bufferKind: .channel)
        }
        receive(session, ":me!u@h JOIN #room", ":srv 353 me = #room :me bob alice carol",
                ":srv 366 me #room :End of /NAMES list.")
        let channel = try XCTUnwrap(session.buffer(named: "#room"))
        XCTAssertEqual(session.sortedMembers(of: channel, order: .recent).map(\.nick), ["alice", "bob", "carol", "me"])
    }

    // MARK: - Nicks in the text

    func testWhatAWordCanBeAsANick() {
        XCTAssertEqual(TranscriptTextView.nickCandidates("bob"), ["bob"])
        XCTAssertEqual(TranscriptTextView.nickCandidates("[bob]").first, "[bob]")
        XCTAssertTrue(TranscriptTextView.nickCandidates("[bob]").contains("bob"))
        XCTAssertTrue(TranscriptTextView.nickCandidates("_bob").contains("bob"))
        XCTAssertTrue(TranscriptTextView.nickCandidates("bob--").contains("bob"))
        XCTAssertFalse(TranscriptTextView.nickCandidates("---").contains(""), "nothing left is no nick")
        XCTAssertLessThanOrEqual(TranscriptTextView.nickCandidates(String(repeating: "-", count: 400)).count, 25)
    }

    func testAMembersNickIsComparedTheNetworksWay() {
        let (session, _) = session()
        receive(session, ":me!u@h JOIN #room", ":srv 353 me = #room :me Bob[m]", ":srv 366 me #room :End of /NAMES list.")
        let channel = session.buffer(named: "#room")!
        XCTAssertEqual(session.memberNick("bob{m}", in: channel), "Bob[m]", "rfc1459: [ is the upper case of {")
        XCTAssertNil(session.memberNick("nobody", in: channel))
    }
}
