import AppKit
import SwiftUI

/// Settings of the input field.
enum InputSettings {
    static let maxLines = "input.maxLines"
    static let defaultMaxLines = 15
    static let lineRange = 1...50
    static let enterKey = "input.enterKey"
}

/// What Return does in the input field. When it does not send, it starts a
/// new message, as ⌥Return always does.
enum EnterKeyMode: String, CaseIterable, Identifiable {
    case sends
    /// Sends one message; text that is already several is not sent by Return.
    case sendsOneMessage
    case neverSends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sends: "Sends the message"
        case .sendsOneMessage: "Sends, unless already several messages"
        case .neverSends: "Never sends"
        }
    }

    /// A long line typed in one go still counts as one message here: only a
    /// line break, or a paste that made several, holds Return back.
    func sends(draft: String, pastedAsSeveral: Bool) -> Bool {
        switch self {
        case .sends: true
        case .sendsOneMessage: !pastedAsSeveral && !draft.contains(where: \.isNewline)
        case .neverSends: false
        }
    }
}

/// The input field: one line that grows with the text up to `maxLines` and
/// then scrolls. The text is one piece to edit, but where one IRC message
/// would end and the next start, the next goes on a new line, under a thin
/// line. Nothing of that is in the text itself.
struct MessageEditor: NSViewRepresentable {
    @Binding var text: String
    /// Where each message after the first starts, as UTF-16 offsets.
    var messageStarts: (String) -> [Int]
    var maxLines: Int
    /// A new value takes the keyboard focus.
    var focusRequest: Int
    /// Told of the height the field wants.
    var heightChanged: (CGFloat) -> Void
    var submit: () -> Void
    /// Whether Return sends the text as it is now.
    var enterSends: () -> Bool
    /// A paste left the text as several messages.
    var pastedAsSeveral: () -> Void
    var complete: () -> Void
    /// ↑ (-1) or ↓ (1), and whether the caret is on the first or last line
    /// of the text; false leaves the key to move the caret.
    var browse: (_ step: Int, _ atEdge: Bool) -> Bool
    /// A ⌃ key with this character; false leaves it to the text view.
    var formatKey: (String) -> Bool

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MessageTextView.make()
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        return MessageScrollView.make(around: textView)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MessageTextView else { return }
        context.coordinator.editor = self
        textView.formatKey = formatKey
        textView.heightChanged = heightChanged
        textView.pastedAsSeveral = pastedAsSeveral
        if textView.string != text { textView.replaceText(with: text) }
        textView.messageStarts = messageStarts(text)
        textView.maxLines = maxLines
        textView.reportHeight()
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            textView.takeFocus()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var editor: MessageEditor
        weak var textView: MessageTextView?
        /// Nil until the first update: a field that appears takes the focus.
        var focusRequest: Int?

        init(_ editor: MessageEditor) {
            self.editor = editor
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if editor.text != textView.string { editor.text = textView.string }
            textView.messageStarts = editor.messageStarts(textView.string)
            textView.reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let textView = textView as? MessageTextView else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if editor.enterSends() { editor.submit() } else { textView.insertMessageBreak() }
                return true
            case #selector(NSResponder.insertTab(_:)):
                editor.complete()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                return editor.browse(-1, textView.isCaretOnFirstLine)
            case #selector(NSResponder.moveDown(_:)):
                return editor.browse(1, textView.isCaretOnLastLine)
            default:
                return false
            }
        }
    }
}

/// The input field's scroll view, its scroller always the overlay kind that
/// takes no width. A classic scroller -- what macOS shows with a mouse
/// attached -- appears for a moment whenever the text gets a line longer
/// than the field: it narrows the text, the text wraps once more, the field
/// grows, the scroller goes, the text unwraps, the field shrinks, and so on,
/// many times a second, for text that ends right at the edge of a line.
final class MessageScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    static func make(around textView: MessageTextView) -> MessageScrollView {
        let scrollView = MessageScrollView()
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = textView
        return scrollView
    }
}

/// The input field's text view, its own undo history kept apart from the
/// window's: the views of conversations come and go, the window stays.
final class MessageTextView: NSTextView {
    /// Room below a message's last line, with the thin line in its middle.
    static let separatorSpace: CGFloat = 7

    var formatKey: (String) -> Bool = { _ in false }
    var heightChanged: (CGFloat) -> Void = { _ in }
    var pastedAsSeveral: () -> Void = {}
    var maxLines = InputSettings.defaultMaxLines
    private var reportedHeight: CGFloat?
    private let undoHistory = UndoManager()
    private var pendingFocus = false

    private var chunks: MessageChunkLayout? { textContainer as? MessageChunkLayout }

    /// Where each message after the first starts: the lines are laid out
    /// again when that changed.
    var messageStarts: [Int] {
        get { chunks?.starts ?? [] }
        set {
            guard let chunks, chunks.starts != newValue, let layoutManager else { return }
            chunks.starts = newValue
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: (string as NSString).length),
                                           actualCharacterRange: nil)
            needsDisplay = true
        }
    }

    static func make() -> MessageTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = MessageChunkLayout(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.delegate = container

        let textView = MessageTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 20), textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        return textView
    }

    /// Takes the text, as an edit that can be undone; the caret goes to its
    /// end.
    func replaceText(with text: String) {
        breakUndoCoalescing()
        insertText(text, replacementRange: NSRange(location: 0, length: (string as NSString).length))
        breakUndoCoalescing()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .control, !hasMarkedText(), let key = event.charactersIgnoringModifiers, formatKey(key) { return }
        if flags == .option, !hasMarkedText(), MessageTextView.returnKeys.contains(event.keyCode) {
            insertMessageBreak()
            return
        }
        super.keyDown(with: event)
    }

    /// Return, and Enter on the numeric keypad.
    private static let returnKeys: Set<UInt16> = [36, 76]

    /// Ends the message here and goes on with the next, sending nothing.
    func insertMessageBreak() {
        insertText("\n", replacementRange: selectedRange())
    }

    // MARK: - Paste

    override func paste(_ sender: Any?) {
        super.paste(sender)
        didPaste()
    }

    override func pasteAsPlainText(_ sender: Any?) {
        super.pasteAsPlainText(sender)
        didPaste()
    }

    func didPaste() {
        if !messageStarts.isEmpty { pastedAsSeveral() }
    }

    // MARK: - Undo

    override var undoManager: UndoManager? { undoHistory }

    @objc func undo(_ sender: Any?) { undoHistory.undo() }
    @objc func redo(_ sender: Any?) { undoHistory.redo() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): undoHistory.canUndo
        case #selector(redo(_:)): undoHistory.canRedo
        default: super.validateMenuItem(item)
        }
    }

    // MARK: - Focus

    /// Takes the keyboard focus once in a window.
    func takeFocus() {
        pendingFocus = true
        DispatchQueue.main.async { [weak self] in self?.focusIfWanted() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfWanted()
    }

    private func focusIfWanted() {
        guard pendingFocus, let window else { return }
        pendingFocus = false
        window.makeFirstResponder(self)
    }

    // MARK: - Height

    /// A new width wraps the text differently.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { DispatchQueue.main.async { [weak self] in self?.reportHeight() } }
    }

    /// The height of the text, of the first `maxLines` lines at most.
    var wantedHeight: CGFloat {
        guard let layoutManager, let textContainer, let font else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        var lines = 0
        var bottom: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: textContainer)) {
            rect, _, _, _, stop in
            lines += 1
            bottom = rect.maxY
            if lines == self.maxLines { stop.pointee = true }
        }
        // Fewer than the limit: the empty line after a final new line counts.
        if lines < maxLines { bottom = max(bottom, layoutManager.usedRect(for: textContainer).maxY) }
        return ceil(max(bottom, layoutManager.defaultLineHeight(for: font)))
    }

    /// Tells a new height, later: not while SwiftUI is updating the view.
    func reportHeight() {
        let height = wantedHeight
        guard height != reportedHeight else { return }
        reportedHeight = height
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightChanged(height)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollRangeToVisible(self.selectedRange())
            }
        }
    }

    // MARK: - The caret's line

    /// On the first line laid out, wrapped lines counting.
    var isCaretOnFirstLine: Bool {
        guard let layoutManager, layoutManager.numberOfGlyphs > 0 else { return true }
        var line = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &line)
        let end = layoutManager.characterRange(forGlyphRange: line, actualGlyphRange: nil)
        let caret = selectedRange().location
        return caret < NSMaxRange(end) || NSMaxRange(end) == (string as NSString).length
    }

    var isCaretOnLastLine: Bool {
        guard let layoutManager, layoutManager.numberOfGlyphs > 0 else { return true }
        let length = (string as NSString).length
        let caret = selectedRange().location
        // After a final new line there is one more, empty line.
        if string.last?.isNewline == true { return caret == length }
        var line = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: &line)
        return caret >= layoutManager.characterRange(forGlyphRange: line, actualGlyphRange: nil).location
    }

    // MARK: - The thin lines

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, !messageStarts.isEmpty else { return }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        NSColor.separatorColor.setFill()
        let thickness = max(1 / (window?.backingScaleFactor ?? 2), 0.5)
        for start in messageStarts where start > 0 && start <= length {
            let glyph = layoutManager.glyphIndexForCharacter(at: start - 1)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = line.maxY + origin.y - MessageTextView.separatorSpace / 2
            let rule = NSRect(x: bounds.minX, y: y, width: bounds.width, height: thickness)
            if rule.intersects(dirtyRect) { rule.fill() }
        }
    }
}

/// Ends a line of the input field where a message ends, however much room is
/// left on it, and makes room below it for the thin line. Text only breaks
/// where the text container says, so the message's last line is given just
/// the width of what is left of the message.
final class MessageChunkLayout: NSTextContainer, NSLayoutManagerDelegate {
    /// Where each message after the first starts, in order.
    var starts: [Int] = []

    /// So the layout asks for each line's rectangle.
    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                          writingDirection: baseWritingDirection, remaining: remainingRect)
        guard let storage = layoutManager?.textStorage, let end = nextStart(after: characterIndex),
              end <= storage.length, end - characterIndex <= Int(rect.width) else { return rect }
        // A new line in the text ends the line by itself.
        if let last = Unicode.Scalar((storage.string as NSString).character(at: end - 1)),
           CharacterSet.newlines.contains(last) { return rect }
        let rest = storage.attributedSubstring(from: NSRange(location: characterIndex, length: end - characterIndex))
        let width = rest.size().width + 1
        if width < rect.width { rect.size.width = width }
        return rect
    }

    private func nextStart(after index: Int) -> Int? {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] > index { high = middle } else { low = middle + 1 }
        }
        return low < starts.count ? starts[low] : nil
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard nextStart(after: NSMaxRange(characters) - 1) == NSMaxRange(characters) else { return false }
        lineFragmentRect.pointee.size.height += MessageTextView.separatorSpace
        return true
    }
}
