import AppKit
import SwiftUI

/// The lines of a conversation as one read-only text view, so a selection can
/// run from the middle of one line to the middle of another and copy as text
/// -- something separate SwiftUI Text views cannot do.
///
/// Lines are only ever appended to a buffer, or dropped from its front when it
/// reaches its limit, so the text view is updated by the difference rather
/// than rebuilt on every message.
struct TranscriptView: NSViewRepresentable {
    let lines: [ChatLine]
    /// Starts each line with the network it came on.
    var showsNetwork = false
    /// Where the pictures under the lines come from.
    var media: MediaStore?
    /// For the whole conversation, at the end of the right-click menu:
    /// downloading the pictures of its history.
    var historyMenuItems: () -> [NSMenuItem] = { [] }
    /// Lowercased nicks whose messages are highlighted.
    var highlightedNicks: Set<String> = []
    /// Whether there is more to read before the first line.
    var hasOlder = false
    /// Asked for when the user scrolls near the top.
    var loadOlder: () -> Void = {}
    /// Whether there is more to read after the last line: when gone back to
    /// a date.
    var hasNewer = false
    /// Asked for when the user scrolls near the bottom.
    var loadNewer: () -> Void = {}
    /// Gone back to a date: shown from the first line, not the last.
    var startsAtTop = false
    /// A line to bring to the middle of the view, with the text to select in
    /// it, once it is among the lines.
    var focus: TranscriptFocus?
    /// Told once the focus was shown.
    var focusShown: () -> Void = {}
    /// Told of the selection when it is within one logged line; nil when
    /// there is none, or it spans lines.
    var selectionChanged: (TranscriptSelection?) -> Void = { _ in }
    /// Told of the logged line in the middle as the user scrolls; nil when
    /// the newest lines are shown.
    var positionChanged: (Int64?) -> Void = { _ in }
    /// The nick a clicked word is, if it is one.
    var nickNamed: (String) -> String? = { _ in nil }
    /// Whois from a nick's right-click menu.
    var nickWhois: (String) -> Void = { _ in }
    /// Whether the nick's menu offers a private chat: not with oneself, nor
    /// in the chat with them.
    var canChatPrivately: (String) -> Bool = { _ in true }
    /// "Same Person…" from a nick's menu.
    var nickAliases: ((String) -> Void)?
    /// The user's actions for a nick: their names, and running them; and
    /// opening their editor.
    var nickActions: (String) -> [(name: String, run: () -> Void)] = { _ in [] }
    var editNickActions: (() -> Void)?
    /// A line double-clicked, where that means going somewhere: in the
    /// Mentions window. Nil elsewhere.
    var lineActivated: ((ChatLine) -> Void)?
    /// A nick clicked: once, or twice.
    var nickClicked: (String, Int) -> Void = { _, _ in }
    /// Asks for the keyboard focus to go to the input field: on a click that
    /// selects nothing, and on typing while the transcript has the focus.
    var focusInput: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TranscriptView.makeScrollView()
        let textView = scrollView.documentView as! TranscriptTextView
        textView.focusInput = focusInput
        textView.historyMenuItems = historyMenuItems
        textView.nickNamed = nickNamed
        textView.nickClicked = nickClicked
        textView.nickWhois = nickWhois
        textView.canChatPrivately = canChatPrivately
        textView.nickAliases = nickAliases
        textView.nickActions = nickActions
        textView.editNickActions = editNickActions
        textView.lineActivated = lineActivated.map { activate in
            { [weak coordinator = context.coordinator] index in
                if let line = coordinator?.line(atCharacter: index) { activate(line) }
            }
        }
        textView.lineRange = { [weak coordinator = context.coordinator] index in
            coordinator?.range(ofLineAt: index)
        }
        textView.linesIn = { [weak coordinator = context.coordinator] range in
            coordinator?.lines(in: range) ?? []
        }
        textView.lineRangesIn = { [weak coordinator = context.coordinator] range in
            coordinator?.lineRanges(in: range) ?? []
        }
        textView.linkMenuItems = { [weak coordinator = context.coordinator] url, index in
            coordinator?.linkMenuItems(url, at: index) ?? []
        }
        textView.pictureResized = { [weak coordinator = context.coordinator] action, width in
            coordinator?.media?.setWidth(Double(width), line: action.line, url: action.url)
        }
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        textView.mediaClicked = { [weak coordinator = context.coordinator] action in
            coordinator?.mediaClicked(action)
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.mediaChanged(_:)),
                                               name: MediaStore.changed, object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.selectionDidChange),
                                               name: NSTextView.didChangeSelectionNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        return scrollView
    }

    /// A read-only text view in a scroll view. TextKit 1, whose layout can
    /// be completed on demand: keeping the place when older lines are put in
    /// front needs the real height of what was added.
    static func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        let textView = TranscriptTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let textView = scrollView.documentView as? TranscriptTextView {
            textView.focusInput = focusInput
            textView.historyMenuItems = historyMenuItems
            textView.nickNamed = nickNamed
            textView.nickClicked = nickClicked
            textView.nickWhois = nickWhois
            textView.canChatPrivately = canChatPrivately
            textView.nickAliases = nickAliases
            textView.nickActions = nickActions
            textView.editNickActions = editNickActions
            let coordinator = context.coordinator
            textView.lineActivated = lineActivated.map { activate in
                { [weak coordinator] index in
                    if let line = coordinator?.line(atCharacter: index) { activate(line) }
                }
            }
        }
        let coordinator = context.coordinator
        coordinator.media = media
        coordinator.loadOlder = loadOlder
        coordinator.hasOlder = hasOlder
        coordinator.loadNewer = loadNewer
        coordinator.hasNewer = hasNewer
        coordinator.startsAtTop = startsAtTop
        coordinator.selectionChanged = selectionChanged
        coordinator.positionChanged = positionChanged
        coordinator.focusShown = focusShown
        if let focus, focus != coordinator.shownFocus { coordinator.pendingFocus = focus }
        coordinator.show(lines, showsNetwork: showsNetwork, highlighted: highlightedNicks)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Lines are appended, dropped from the front, or older ones put in
    /// front, so the text view is updated by the difference rather than
    /// rebuilt on every message.
    @MainActor
    final class Coordinator: NSObject {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var hasOlder = false
        var loadOlder: () -> Void = {}
        var hasNewer = false
        var loadNewer: () -> Void = {}
        var startsAtTop = false
        var selectionChanged: (TranscriptSelection?) -> Void = { _ in }
        var positionChanged: (Int64?) -> Void = { _ in }
        /// The position last told, so it is told once per change.
        private var toldPosition: Int64??
        var focusShown: () -> Void = {}
        /// The line to bring into view once it is shown, and the last one
        /// that was.
        var pendingFocus: TranscriptFocus?
        private(set) var shownFocus: TranscriptFocus?
        /// Set while the text is replaced: the selection it clears is not the
        /// user's doing.
        private var isUpdating = false
        /// Set while newer lines are being fetched: they are added below,
        /// and the view stays where it is.
        private var askedForNewer = false
        var media: MediaStore?
        /// Set while older lines are being fetched, so scrolling does not ask
        /// for them again and again.
        private var askedForOlder = false
        /// The lines in the text view, and how many characters each takes.
        private var shownLines: [ChatLine] = []
        private var shownLengths: [Int] = []
        private var showsNetwork = false
        private var highlighted: Set<String> = []
        private var shownDay = Calendar.current.startOfDay(for: .now)

        func show(_ lines: [ChatLine], showsNetwork: Bool = false, highlighted: Set<String> = []) {
            guard let textView, let storage = textView.textStorage else { return }
            isUpdating = true
            defer { isUpdating = false }
            let wasAtBottom = isAtBottom
            var rebuilt = false
            var prepended = false

            let restyle = highlighted != self.highlighted
            self.highlighted = highlighted
            // After midnight, yesterday's lines need their date.
            let today = Calendar.current.startOfDay(for: .now)
            let newDay = today != shownDay
            shownDay = today
            if showsNetwork != self.showsNetwork || shownLines.isEmpty || newDay {
                self.showsNetwork = showsNetwork
                rebuild(lines, in: storage)
                rebuilt = true
            } else if let oldFirst = shownLines.first, let oldLast = shownLines.last,
                      let position = lines.firstIndex(where: { $0.id == oldFirst.id }),
                      lines.count >= position + shownLines.count,
                      lines[position + shownLines.count - 1].id == oldLast.id {
                // Older lines in front, new ones at the end, or both.
                let newLines = lines[(position + shownLines.count)...]
                if position > 0 {
                    prepend(lines[..<position], to: storage)
                    prepended = true
                }
                storage.beginEditing()
                for line in newLines { append(line, to: storage) }
                storage.endEditing()
            } else if let newFirst = lines.first,
                      let dropped = shownLines.firstIndex(where: { $0.id == newFirst.id }), dropped > 0,
                      lines.count >= shownLines.count - dropped,
                      lines[shownLines.count - dropped - 1].id == shownLines.last?.id {
                // The oldest went; maybe new ones came.
                storage.beginEditing()
                let length = shownLengths[..<dropped].reduce(0, +)
                storage.deleteCharacters(in: NSRange(location: 0, length: length))
                shownLines.removeFirst(dropped)
                shownLengths.removeFirst(dropped)
                for line in lines[shownLines.count...] { append(line, to: storage) }
                storage.endEditing()
            } else {
                rebuild(lines, in: storage)
                rebuilt = true
            }

            if restyle && !rebuilt { applyBackgrounds(in: storage) }

            let pagedDown = askedForNewer && !rebuilt
            askedForNewer = false
            if let focus = pendingFocus, !lines.isEmpty, !isShown(focus) {
                // Its line is not among them: nothing to go back to.
                pendingFocus = nil
                DispatchQueue.main.async { [weak self] in self?.focusShown() }
            }
            if let focus = pendingFocus, isShown(focus) {
                pendingFocus = nil
                shownFocus = focus
                reveal(focus, in: textView)
                DispatchQueue.main.async { [weak self] in
                    self?.reveal(focus, in: textView)
                    textView.setNeedsDisplay(textView.visibleRect)
                    self?.focusShown()
                }
            } else if rebuilt && startsAtTop {
                textView.scroll(.zero)
                DispatchQueue.main.async {
                    textView.scroll(.zero)
                    textView.setNeedsDisplay(textView.visibleRect)
                }
            } else if rebuilt || (wasAtBottom && !prepended && !pagedDown) {
                // Follow new lines only when already at the end: someone
                // scrolled up to read is not pulled away from it.
                textView.scrollToEndOfDocument(nil)
                // A new view has no size until SwiftUI lays it out: once more
                // after that, or it would stay at the top.
                if rebuilt {
                    DispatchQueue.main.async {
                        textView.scrollToEndOfDocument(nil)
                        textView.setNeedsDisplay(textView.visibleRect)
                    }
                }
            }
            if rebuilt || prepended { askedForOlder = false }
            fillHeight()
            // Lines moved while parts of the view were drawn already: those
            // parts would stay as they were -- empty, or a line cut in half
            // -- until something else drew them.
            textView.setNeedsDisplay(textView.visibleRect)
            // A short transcript does not scroll, so it would never ask.
            DispatchQueue.main.async { [weak self] in self?.scrolled() }
        }

        /// The characters of a logged line; nil while it is not shown.
        private func characters(ofLine id: Int64) -> NSRange? {
            var start = 0
            for (line, length) in zip(shownLines, shownLengths) {
                if line.logID == id { return NSRange(location: start, length: length) }
                start += length
            }
            return nil
        }

        /// Whether what the focus needs is there: its line, or else the
        /// selected one.
        private func isShown(_ focus: TranscriptFocus) -> Bool {
            if let id = focus.logID { return characters(ofLine: id) != nil }
            return focus.selection.flatMap { characters(ofLine: $0.logID) } != nil
        }

        /// Scrolls the focus's line to the middle of the view, and selects
        /// its text if that line is shown.
        private func reveal(_ focus: TranscriptFocus, in textView: NSTextView) {
            fillHeight()
            guard let layout = textView.layoutManager, let container = textView.textContainer,
                  let scrollView else { return }
            layout.ensureLayout(for: container)
            isUpdating = true
            defer { isUpdating = false }
            if let selection = focus.selection, let line = characters(ofLine: selection.logID) {
                let location = min(selection.location, line.length - 1)
                textView.setSelectedRange(NSRange(location: line.location + location,
                                                  length: min(selection.length, line.length - location)))
            }
            guard let id = focus.logID, let line = characters(ofLine: id) else { return }
            let target = focus.selection?.logID == id ? textView.selectedRange() : NSRange(location: line.location, length: 1)
            let glyphs = layout.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += textView.textContainerOrigin.y
            let visible = scrollView.contentView.bounds.height
            let top = max(0, min(rect.midY - visible / 2, textView.frame.height - visible))
            textView.scroll(NSPoint(x: 0, y: top))
        }

        /// The logged line in the middle of what shows; nil at the newest.
        private func middleLine() -> Int64?? {
            guard let textView, let scrollView, let layout = textView.layoutManager,
                  let container = textView.textContainer, !shownLines.isEmpty else { return nil }
            if isAtBottom && !hasNewer { return .some(nil) }
            let visible = scrollView.contentView.bounds
            let point = NSPoint(x: 20, y: visible.midY - textView.textContainerOrigin.y)
            let glyph = layout.glyphIndex(for: point, in: container)
            guard let id = line(atCharacter: layout.characterIndexForGlyph(at: glyph))?.logID else { return nil }
            return .some(id)
        }

        /// The user's selection, as a line and the characters in it.
        @objc func selectionDidChange() {
            guard !isUpdating, let textView else { return }
            let selection = textView.selectedRange()
            guard selection.length > 0 else { return selectionChanged(nil) }
            var start = 0
            for (line, length) in zip(shownLines, shownLengths) {
                if selection.location < start + length {
                    guard let id = line.logID, NSMaxRange(selection) <= start + length else { break }
                    return selectionChanged(TranscriptSelection(logID: id, location: selection.location - start,
                                                                length: selection.length))
                }
                start += length
            }
            selectionChanged(nil)
        }

        /// At least as tall as the view, so a few lines can sit at its bottom.
        private func fillHeight() {
            guard let textView, let scrollView else { return }
            let height = scrollView.contentSize.height
            if textView.minSize.height != height {
                textView.minSize = NSSize(width: 0, height: height)
                textView.sizeToFit()
            }
            (textView as? TranscriptTextView)?.placeAtBottom()
        }

        /// Fetches older lines once the top is near, newer ones once the
        /// bottom is.
        @objc func scrolled() {
            fillHeight()
            // Not while a place to go to is waiting, or the text is changing:
            // that is not the user scrolling.
            if pendingFocus == nil, !isUpdating, let position = middleLine(), position != toldPosition {
                toldPosition = position
                positionChanged(position)
            }
            guard let scrollView else { return }
            if hasNewer, !askedForNewer, let documentView = scrollView.documentView,
               documentView.frame.height - scrollView.contentView.bounds.maxY < 400 {
                askedForNewer = true
                loadNewer()
            }
            guard hasOlder, !askedForOlder else { return }
            guard scrollView.contentView.bounds.minY < 400 else { return }
            askedForOlder = true
            loadOlder()
        }

        private var isAtBottom: Bool {
            guard let scrollView, let documentView = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            return visible.maxY >= documentView.frame.height - 24
        }

        private func rebuild(_ lines: [ChatLine], in storage: NSTextStorage) {
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            shownLines = []
            shownLengths = []
            for line in lines { append(line, to: storage) }
            storage.endEditing()
        }

        private func rendered(_ line: ChatLine) -> NSAttributedString {
            let text = TranscriptView.render(line, showsNetwork: showsNetwork)
            text.append(NSAttributedString(string: "\n"))
            if let background = TranscriptView.background(for: line, highlighted: highlighted) {
                text.addAttribute(.backgroundColor, value: background, range: NSRange(location: 0, length: text.length))
            }
            if let media, let id = line.logID {
                let indent = TranscriptView.indent(for: line.time)
                for item in media.items(for: line) {
                    text.append(TranscriptView.render(item, line: id, width: availableWidth - indent, indent: indent))
                }
            }
            return text
        }

        /// Room for a picture: the text's width, less the timestamp's.
        private var availableWidth: CGFloat {
            let width = (textView?.textContainer?.containerSize.width ?? 500) - 2 * 10
            return max(min(width, 560), 160)
        }

        /// A picture arrived, or was opened or closed: its line is drawn
        /// again, in place.
        @objc func mediaChanged(_ notification: Notification) {
            guard let id = notification.userInfo?["line"] as? Int64,
                  let index = shownLines.firstIndex(where: { $0.logID == id }),
                  let storage = textView?.textStorage else { return }
            let wasAtBottom = isAtBottom
            let location = shownLengths[..<index].reduce(0, +)
            let text = rendered(shownLines[index])
            storage.replaceCharacters(in: NSRange(location: location, length: shownLengths[index]), with: text)
            shownLengths[index] = text.length
            if wasAtBottom { textView?.scrollToEndOfDocument(nil) }
            if let textView { textView.setNeedsDisplay(textView.visibleRect) }
        }

        /// A click on the line above a picture opens or closes it. A click on
        /// the picture does nothing: dragging it resizes it.
        func mediaClicked(_ action: MediaAction) {
            if case .toggle(let collapse) = action.kind {
                media?.setCollapsed(collapse, line: action.line, url: action.url)
            }
        }

        /// The characters of the line the character belongs to, with its
        /// pictures.
        func range(ofLineAt index: Int) -> NSRange? {
            var start = 0
            for length in shownLengths {
                if index < start + length { return NSRange(location: start, length: length) }
                start += length
            }
            return nil
        }

        /// The characters of each line the range touches, in order.
        func lineRanges(in range: NSRange) -> [NSRange] {
            var start = 0
            var ranges: [NSRange] = []
            for length in shownLengths {
                if start >= NSMaxRange(range) { break }
                if start + length > range.location { ranges.append(NSRange(location: start, length: length)) }
                start += length
            }
            return ranges
        }

        /// The lines the range touches, in order.
        func lines(in range: NSRange) -> [ChatLine] {
            var start = 0
            var lines: [ChatLine] = []
            for (line, length) in zip(shownLines, shownLengths) {
                if start >= NSMaxRange(range) { break }
                if start + length > range.location { lines.append(line) }
                start += length
            }
            return lines
        }

        /// The line the character belongs to.
        func line(atCharacter index: Int) -> ChatLine? {
            var end = 0
            for (line, length) in zip(shownLines, shownLengths) {
                end += length
                if index < end { return line }
            }
            return nil
        }

        /// A link's menu: open it, privately or not, and get the picture it
        /// may be -- also one that failed before, or came with imported logs.
        func linkMenuItems(_ url: URL, at index: Int) -> [NSMenuItem] {
            var items: [NSMenuItem] = [ClosureMenuItem(title: "Open Link") { NSWorkspace.shared.open(url) }]
            if let browser = PrivateBrowser.browser {
                items.append(ClosureMenuItem(title: "Open in Private Window (\(browser.name))") { [weak self] in
                    if let problem = PrivateBrowser.open(url) { self?.alert("Could not open a private window", problem) }
                })
            }
            let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            if isWeb, let media, let id = line(atCharacter: index)?.logID {
                let state = media.state(of: url.absoluteString, line: id)
                if !state.shownHere {
                    items.append(.separator())
                    items.append(ClosureMenuItem(title: state.stored ? "Show Picture" : "Download Picture") { [weak self] in
                        Task { @MainActor in
                            if let problem = await media.download(url, forLine: id) {
                                self?.alert("Could not get the picture", problem)
                            }
                        }
                    })
                }
            }
            items.append(.separator())
            items.append(ClosureMenuItem(title: "Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            })
            return items
        }

        private func alert(_ title: String, _ text: String) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            if let window = textView?.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }

        private func append(_ line: ChatLine, to storage: NSTextStorage) {
            let text = rendered(line)
            storage.append(text)
            shownLines.append(line)
            shownLengths.append(text.length)
        }

        /// Puts older lines in front, keeping the lines on screen where they
        /// were.
        private func prepend(_ lines: ArraySlice<ChatLine>, to storage: NSTextStorage) {
            guard let textView, let scrollView, let layout = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let heightBefore = layout.usedRect(for: container).height
            let origin = scrollView.contentView.bounds.origin

            let block = NSMutableAttributedString()
            var lengths: [Int] = []
            for line in lines {
                let text = rendered(line)
                block.append(text)
                lengths.append(text.length)
            }
            storage.beginEditing()
            storage.insert(block, at: 0)
            storage.endEditing()
            shownLines.insert(contentsOf: lines, at: 0)
            shownLengths.insert(contentsOf: lengths, at: 0)

            layout.ensureLayout(for: container)
            textView.sizeToFit()
            let added = layout.usedRect(for: container).height - heightBefore
            scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + added))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// The selected members changed: only the backgrounds change.
        private func applyBackgrounds(in storage: NSTextStorage) {
            storage.beginEditing()
            var location = 0
            for (line, length) in zip(shownLines, shownLengths) {
                let range = NSRange(location: location, length: length)
                storage.removeAttribute(.backgroundColor, range: range)
                if let background = TranscriptView.background(for: line, highlighted: highlighted) {
                    storage.addAttribute(.backgroundColor, value: background, range: range)
                }
                location += length
            }
            storage.endEditing()
        }
    }

    /// Lines of the selected members, then lines that mention the user.
    static func background(for line: ChatLine, highlighted: Set<String>) -> NSColor? {
        if line.isActivity, let sender = line.sender, highlighted.contains(sender.lowercased()) {
            return NSColor.controlAccentColor.withAlphaComponent(0.18)
        }
        if line.isHighlight {
            return NSColor.systemYellow.withAlphaComponent(0.22)
        }
        return nil
    }

    // MARK: - Rendering a picture

    static let mediaAction = NSAttributedString.Key("IrctellMediaAction")
    /// Which part of a line the characters are, for copying without the time
    /// or the nick.
    static let linePart = NSAttributedString.Key("IrctellLinePart")

    enum LinePart: String {
        case time, nick, text
    }

    /// What a click on a picture, or on the line above it, does.
    final class MediaAction: NSObject {
        enum Kind { case toggle(collapse: Bool), open }
        let kind: Kind
        let line: Int64
        let url: String

        init(_ kind: Kind, line: Int64, url: String) {
            self.kind = kind
            self.line = line
            self.url = url
        }
    }

    /// A line to open or close the picture, and below it the picture, at most
    /// `width` wide and 320 points high.
    static func render(_ item: MediaItem, line: Int64, width: CGFloat, indent: CGFloat = 40) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.paragraphSpacing = 4
        let host = URL(string: item.url)?.host() ?? ""
        let title = (item.collapsed ? "▸ Show picture" : "▾ Hide picture") + " · \(host) · \(item.width)×\(item.height)"
        let result = NSMutableAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
            mediaAction: MediaAction(.toggle(collapse: !item.collapsed), line: line, url: item.url),
            .cursor: NSCursor.pointingHand,
        ])
        guard !item.collapsed else { return result }
        let size = item.image.size
        let scale = item.displayWidth.map { $0 / max(size.width, 1) }
            ?? min(1, width / max(size.width, 1), 320 / max(size.height, 1))
        let attachment = NSTextAttachment()
        attachment.image = item.image
        attachment.bounds = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let picture = NSMutableAttributedString(attachment: attachment)
        picture.append(NSAttributedString(string: "\n"))
        picture.addAttributes([
            .paragraphStyle: paragraph,
            mediaAction: MediaAction(.open, line: line, url: item.url),
            .toolTip: "\(item.url)\nDrag to resize",
        ], range: NSRange(location: 0, length: picture.length))
        result.append(picture)
        return result
    }

    // MARK: - Rendering a line

    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    private static let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let dateTimeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy-MM-dd HH:mm"
        return formatter
    }()

    /// The time of a line from today; with the date, "25-03-14 21:07", of an
    /// older one.
    static func timestamp(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(timeFormat) : dateTimeFormat.string(from: date)
    }

    /// How far the text after the timestamp starts, so wrapped lines and
    /// pictures line up under it.
    static func indent(for date: Date) -> CGFloat {
        (timestamp(date) + "  " as NSString).size(withAttributes: [.font: timeFont]).width
    }

    static func render(_ line: ChatLine, showsNetwork: Bool = false) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        var marked = 0
        /// Tags what was appended since the last part.
        func mark(_ part: LinePart) {
            result.addAttribute(linePart, value: part.rawValue,
                                range: NSRange(location: marked, length: result.length - marked))
            marked = result.length
        }
        let time = timestamp(line.time) + "  "
        result.append(NSAttributedString(string: time, attributes: [
            .font: timeFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        if showsNetwork, let network = line.network {
            result.append(NSAttributedString(string: "[\(network)] ", attributes: [
                .font: timeFont, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        mark(.time)

        let nick = line.sender ?? ""
        let nickColor = line.isSelf ? NSColor.secondaryLabelColor : IRCFormatting.nsColor(forNick: nick)
        func styledNick(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: boldFont, .foregroundColor: nickColor])
        }

        switch line.kind {
        case .message:
            result.append(styledNick("<\(nick)> "))
            mark(.nick)
            result.append(IRCFormatting.nsAttributed(line.text, font: font, color: .labelColor))
        case .action:
            result.append(NSAttributedString(string: "• ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            result.append(styledNick(nick + " "))
            mark(.nick)
            result.append(IRCFormatting.nsAttributed(line.text, font: italicFont, color: .labelColor))
        case .notice:
            result.append(styledNick("-\(nick)- "))
            mark(.nick)
            result.append(IRCFormatting.nsAttributed(line.text, font: font, color: .labelColor))
        case .join, .part, .quit, .kick, .nick, .topic, .mode:
            result.append(NSAttributedString(string: symbol(for: line.kind) + " ",
                                             attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            mark(.nick)
            result.append(IRCFormatting.nsAttributed(line.text, font: font, color: .secondaryLabelColor))
        case .info:
            result.append(IRCFormatting.nsAttributed(line.text, font: font, color: .secondaryLabelColor))
        case .error:
            result.append(NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        }
        mark(.text)

        // Wrapped lines start under the text, not under the timestamp.
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = (time as NSString).size(withAttributes: [.font: timeFont]).width
        paragraph.paragraphSpacing = 2
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func symbol(for kind: ChatLine.Kind) -> String {
        switch kind {
        case .join: "→"
        case .part, .quit: "←"
        case .kick: "⨯"
        case .nick: "≈"
        case .topic: "✎"
        default: "•"
        }
    }
}

/// The transcript's text view. It keeps the focus only while text is
/// selected, for copying: a plain click, or typing, goes on to the input field,
/// and the keystroke goes with it.
final class TranscriptTextView: NSTextView {
    var focusInput: () -> Void = {}
    var nickNamed: (String) -> String? = { _ in nil }
    var nickClicked: (String, Int) -> Void = { _, _ in }
    var nickWhois: (String) -> Void = { _ in }
    var mediaClicked: (TranscriptView.MediaAction) -> Void = { _ in }
    var canChatPrivately: (String) -> Bool = { _ in true }
    var nickAliases: ((String) -> Void)?
    var nickActions: (String) -> [(name: String, run: () -> Void)] = { _ in [] }
    var editNickActions: (() -> Void)?
    var lineActivated: ((Int) -> Void)?
    var linkMenuItems: (URL, Int) -> [NSMenuItem] = { _, _ in [] }
    var historyMenuItems: () -> [NSMenuItem] = { [] }
    /// The whole line a character is in, for selecting by lines.
    var lineRange: (Int) -> NSRange? = { _ in nil }
    /// The lines in a range of the text, for reading them aloud.
    var linesIn: (NSRange) -> [ChatLine] = { _ in [] }
    /// The characters of each line in a range of the text, for copying.
    var lineRangesIn: (NSRange) -> [NSRange] = { _ in [] }
    var pictureResized: (TranscriptView.MediaAction, CGFloat) -> Void = { _, _ in }

    /// While the lines do not fill the view, they sit at its bottom, as in a
    /// chat, and move up as more come.
    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        guard let layout = layoutManager, let container = textContainer else { return origin }
        let free = bounds.height - layout.usedRect(for: container).height - 2 * textContainerInset.height
        if free > 0 { origin.y += free }
        return origin
    }

    /// Moves the lines down to the bottom again, after lines came or the
    /// view was resized. Only the changed lines would be drawn by
    /// themselves: the rest, now in a new place, would vanish until the
    /// window was drawn again.
    func placeAtBottom() {
        let before = textContainerOrigin
        invalidateTextContainerOrigin()
        if textContainerOrigin != before { needsDisplay = true }
    }

    /// A new size lays the lines out again: all of what shows is drawn again.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateTextContainerOrigin()
        setNeedsDisplay(visibleRect)
    }

    /// Links open from their menu only: a click is for selecting.
    override func clicked(onLink link: Any, at charIndex: Int) {}

    /// On a link: what to do with it. On a nick: a menu for that user, who is
    /// also selected in the member list. Elsewhere, the usual text menu. None
    /// of them with the Services.
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = characterIndex(at: event)
        if let index, let url = linkURL(at: index) {
            let menu = NSMenu(title: url.absoluteString)
            for item in linkMenuItems(url, index) { menu.addItem(item) }
            menu.allowsContextMenuPlugIns = false
            return menu
        }
        guard let nick = word(at: event).flatMap(nickNamed) else {
            let menu = super.menu(for: event)
            menu?.allowsContextMenuPlugIns = false
            if let menu, let copy = copyItem() {
                // In place of the plain Copy.
                let index = menu.items.firstIndex { $0.action == #selector(copy(_:)) }
                if let index { menu.removeItem(at: index) }
                menu.insertItem(copy, at: index ?? 0)
            }
            if let menu, let item = readAloudItem() {
                menu.insertItem(item, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
            let history = historyMenuItems()
            if let menu, !history.isEmpty {
                menu.addItem(.separator())
                for item in history { menu.addItem(item) }
            }
            return menu
        }
        nickClicked(nick, 1)
        let menu = NSMenu(title: nick)
        menu.allowsContextMenuPlugIns = false
        let header = NSMenuItem(title: nick, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(ClosureMenuItem(title: "Whois") { [weak self] in self?.nickWhois(nick) })
        if canChatPrivately(nick) {
            menu.addItem(ClosureMenuItem(title: "Private Chat") { [weak self] in self?.nickClicked(nick, 2) })
        }
        if let nickAliases {
            menu.addItem(ClosureMenuItem(title: "Same Person…") { nickAliases(nick) })
        }
        let actions = nickActions(nick)
        if !actions.isEmpty || editNickActions != nil {
            let item = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Actions")
            for action in actions { submenu.addItem(ClosureMenuItem(title: action.name, handler: action.run)) }
            if let editNickActions {
                if !actions.isEmpty { submenu.addItem(.separator()) }
                submenu.addItem(ClosureMenuItem(title: "Edit Actions…", handler: editNickActions))
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        if selectedRange().length > 0 {
            menu.addItem(.separator())
            if let copy = copyItem() { menu.addItem(copy) }
            if let item = readAloudItem() { menu.addItem(item) }
        }
        return menu
    }

    /// Copy, with a choice of what of the lines: as shown, without the
    /// times, or only what was written. Nil without a selection.
    private func copyItem() -> NSMenuItem? {
        guard selectedRange().length > 0 else { return nil }
        let item = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        let choices = NSMenu(title: "Copy")
        let all = NSMenuItem(title: "As Shown", action: #selector(copy(_:)), keyEquivalent: "c")
        all.keyEquivalentModifierMask = .command
        choices.addItem(all)
        choices.addItem(ClosureMenuItem(title: "Nicks and Messages") { [weak self] in
            self?.copySelection(keeping: [.nick, .text])
        })
        choices.addItem(ClosureMenuItem(title: "Text Only") { [weak self] in
            self?.copySelection(keeping: [.text])
        })
        item.submenu = choices
        return item
    }

    /// Copies the selected parts of the lines, one line each.
    func copySelection(keeping parts: Set<TranscriptView.LinePart>) {
        let text = selectedText(keeping: parts)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// What of the selection is in the parts, line by line; lines left with
    /// nothing are left out.
    func selectedText(keeping parts: Set<TranscriptView.LinePart>) -> String {
        guard let storage = textStorage else { return "" }
        let selection = selectedRange()
        var lines: [String] = []
        for line in lineRangesIn(selection) {
            guard let range = line.intersection(selection), range.length > 0 else { continue }
            var kept = ""
            storage.enumerateAttribute(TranscriptView.linePart, in: range) { value, piece, _ in
                guard let raw = value as? String, let part = TranscriptView.LinePart(rawValue: raw),
                      parts.contains(part) else { return }
                kept += storage.attributedSubstring(from: piece).string
            }
            let trimmed = kept.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the selected lines aloud, the user's own too, each with who
    /// wrote it; nil without a selection.
    private func readAloudItem() -> NSMenuItem? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        let lines = linesIn(range)
        guard !lines.isEmpty else { return nil }
        let title = lines.count == 1 ? "Read Aloud" : "Read \(lines.count) Lines Aloud"
        let item = ClosureMenuItem(title: title) { Speaker.shared.read(lines) }
        if Speaker.shared.isMuted {
            item.isEnabled = false
            item.toolTip = "Irctell is muted"
        }
        return item
    }

    private func linkURL(at index: Int) -> URL? {
        switch textStorage?.attribute(.link, at: index, effectiveRange: nil) {
        case let url as URL: url
        case let text as String: URL(string: text)
        default: nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            selectLines(from: event)
            return
        }
        if event.clickCount == 1, let index = characterIndex(at: event), let action = textStorage?.attribute(
            TranscriptView.mediaAction, at: index, effectiveRange: nil) as? TranscriptView.MediaAction {
            if case .open = action.kind {
                resizePicture(at: index, action: action, from: event)
            } else {
                mediaClicked(action)
            }
            return
        }
        if event.clickCount == 2, let lineActivated, let index = characterIndex(at: event) {
            lineActivated(index)
            return
        }
        let nick = word(at: event).flatMap(nickNamed)
        // Returns once the button is up, after any dragging to select.
        super.mouseDown(with: event)
        let plainClick = selectedRange().length == 0
        if let nick, plainClick || event.clickCount == 2 {
            nickClicked(nick, event.clickCount)
        }
        if plainClick {
            moveFocusToInput(forwarding: nil)
        }
    }

    /// ⌘-drag: whole lines are selected, from the one clicked to the one
    /// under the mouse, up or down.
    private func selectLines(from event: NSEvent) {
        guard let window, let first = lineRange(insertionIndex(at: event)) else { return }
        setSelectedRange(first)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) {
            event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            autoscroll(with: event)
            if let current = lineRange(insertionIndex(at: event)) {
                setSelectedRange(NSUnionRange(first, current))
            }
        }
    }

    /// The character nearest the mouse, also past the end of a line or
    /// above or below the text.
    private func insertionIndex(at event: NSEvent) -> Int {
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        return max(min(index, (string as NSString).length - 1), 0)
    }

    /// Dragging a picture: right or down makes it larger, its proportions
    /// kept; the width is saved when the button comes up.
    private func resizePicture(at index: Int, action: TranscriptView.MediaAction, from event: NSEvent) {
        guard let storage = textStorage, let window,
              let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
        else { return }
        let start = event.locationInWindow
        let original = attachment.bounds
        let ratio = original.height / max(original.width, 1)
        let maxWidth = max((textContainer?.containerSize.width ?? 600) - 40, 60)
        var width = original.width
        var moved = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) {
            event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            moved = true
            let delta = max(event.locationInWindow.x - start.x, start.y - event.locationInWindow.y)
            width = min(max(original.width + delta, 40), maxWidth).rounded()
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: (width * ratio).rounded())
            storage.edited(.editedAttributes, range: NSRange(location: index, length: 1), changeInLength: 0)
        }
        if moved { pictureResized(action, width) }
    }

    /// Characters a nick is made of.
    private static let nickCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_[]{}\\|^`"))

    /// The character under the mouse, if the mouse is on one.
    private func characterIndex(at event: NSEvent) -> Int? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyph = layout.glyphIndex(for: point, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point)
        else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    /// The nick-like word under the mouse, if the mouse is on text.
    private func word(at event: NSEvent) -> String? {
        guard let index = characterIndex(at: event) else { return nil }
        let text = string as NSString
        func isNickCharacter(_ position: Int) -> Bool {
            guard position >= 0, position < text.length,
                  let scalar = Unicode.Scalar(text.character(at: position)) else { return false }
            return TranscriptTextView.nickCharacters.contains(scalar)
        }
        guard isNickCharacter(index) else { return nil }
        var start = index, end = index + 1
        while isNickCharacter(start - 1) { start -= 1 }
        while isNickCharacter(end) { end += 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shortcuts like Copy, and keys that scroll, stay here.
        if modifiers.contains(.command) || modifiers.contains(.control) || Self.isNavigation(event) {
            super.keyDown(with: event)
        } else {
            moveFocusToInput(forwarding: event)
        }
    }

    private static func isNavigation(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        let keys: [Int] = [NSPageUpFunctionKey, NSPageDownFunctionKey, NSHomeFunctionKey, NSEndFunctionKey,
                           NSUpArrowFunctionKey, NSDownArrowFunctionKey]
        return keys.contains(Int(scalar.value))
    }

    /// The SwiftUI focus change lands on a later turn of the run loop; wait
    /// for the field's editor, put the cursor at the end -- not select all of
    /// the draft -- and hand it the keystroke.
    private func moveFocusToInput(forwarding event: NSEvent?) {
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        focusInput()
        guard let window else { return }
        func deliver(attempt: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
                if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    if let event { editor.keyDown(with: event) }
                } else if attempt < 20 {
                    deliver(attempt: attempt + 1)
                }
            }
        }
        deliver(attempt: 0)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used from a nib")
    }

    @objc private func run() {
        handler()
    }
}

/// Where to bring the transcript: a logged line to the middle -- none to
/// stay where it is -- and text to select, in that line or another.
struct TranscriptFocus: Equatable {
    var logID: Int64?
    var selection: TranscriptSelection?
    /// So the same line asked for again is shown again.
    var request = UUID()
}
