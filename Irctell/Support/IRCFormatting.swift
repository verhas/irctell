import AppKit
import SwiftUI

/// mIRC formatting codes: bold, italics, underline, colours and the rest are
/// control characters inside the message text. The parser turns text into
/// styled runs; the renderers turn the runs into AppKit or SwiftUI text, and
/// make links clickable.
enum IRCFormatting {

    /// A colour: one of mIRC's 99 by number, or with ^D an RGB value.
    enum Colour: Equatable, Hashable {
        case index(Int)
        case rgb(UInt32)

        /// Its number, for a numbered colour.
        var index: Int? {
            if case .index(let index) = self { return index }
            return nil
        }
    }

    struct Style: Equatable {
        var bold = false, italic = false, underline = false, strikethrough = false, monospace = false
        var foreground: Colour?
        var background: Colour?
    }

    struct Run: Equatable {
        var text: String
        var style: Style
    }

    /// mIRC's colours: the 16 standard ones, then the 83 extended ones;
    /// 99 is "the default colour".
    static let palette: [UInt32] = [
        0xFFFFFF, 0x000000, 0x00007F, 0x009300, 0xFF0000, 0x7F0000, 0x9C009C, 0xFC7F00,
        0xFFFF00, 0x00FC00, 0x009393, 0x00FFFF, 0x0000FC, 0xFF00FF, 0x7F7F7F, 0xD2D2D2,
        0x470000, 0x472100, 0x474700, 0x324700, 0x004700, 0x00472C, 0x004747, 0x002747, 0x000047, 0x2E0047, 0x470047, 0x47002A,
        0x740000, 0x743A00, 0x747400, 0x517400, 0x007400, 0x007449, 0x007474, 0x004074, 0x000074, 0x4B0074, 0x740074, 0x740045,
        0xB50000, 0xB56300, 0xB5B500, 0x7DB500, 0x00B500, 0x00B571, 0x00B5B5, 0x0063B5, 0x0000B5, 0x7500B5, 0xB500B5, 0xB5006B,
        0xFF0000, 0xFF8C00, 0xFFFF00, 0xB2FF00, 0x00FF00, 0x00FFA0, 0x00FFFF, 0x008CFF, 0x0000FF, 0xA500FF, 0xFF00FF, 0xFF0098,
        0xFF5959, 0xFFB459, 0xFFFF71, 0xCFFF60, 0x6FFF6F, 0x65FFC9, 0x6DFFFF, 0x59B4FF, 0x5959FF, 0xC459FF, 0xFF66FF, 0xFF59BC,
        0xFF9C9C, 0xFFD39C, 0xFFFF9C, 0xE2FF9C, 0x9CFF9C, 0x9CFFDB, 0x9CFFFF, 0x9CD3FF, 0x9C9CFF, 0xDC9CFF, 0xFF9CFF, 0xFF94D3,
        0x000000, 0x131313, 0x282828, 0x363636, 0x4D4D4D, 0x656565, 0x818181, 0x9F9F9F, 0xBCBCBC, 0xE2E2E2, 0xFFFFFF,
    ]

    /// The names of the standard 16, for the colour picker.
    static let colourNames = [
        "White", "Black", "Navy", "Green", "Red", "Maroon", "Purple", "Orange",
        "Yellow", "Lime", "Teal", "Cyan", "Blue", "Pink", "Grey", "Light Grey",
    ]

    static func nsColor(_ colour: Colour?) -> NSColor? {
        let rgb: UInt32
        switch colour {
        case .index(let index)? where palette.indices.contains(index): rgb = palette[index]
        case .rgb(let value)?: rgb = value
        default: return nil
        }
        return NSColor(srgbRed: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255,
                       blue: Double(rgb & 0xFF) / 255, alpha: 1)
    }

    /// A text colour on the window's own background: black in dark mode or
    /// white in light mode is unreadable there, and is drawn in `fallback`.
    static func readable(_ colour: NSColor, fallback: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            // Relative luminance: of the window, and of the colour.
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let background = dark ? 0.013 : 1
            guard let rgb = colour.usingColorSpace(.sRGB) else { return colour }
            func linear(_ c: CGFloat) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
            let ratio = (max(luminance, background) + 0.05) / (min(luminance, background) + 0.05)
            // Only the nearly invisible: yellow on white, black or navy on
            // dark; the bright greens and the greys stay.
            return ratio < 1.3 ? fallback : colour
        }
    }

    // MARK: - Parsing

    static func runs(_ text: String) -> [Run] {
        var runs: [Run] = []
        var style = Style()
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            runs.append(Run(text: current, style: style))
            current = ""
        }

        let chars = Array(text)
        var i = 0
        /// Reads up to two digits at `i`; nil when there are none.
        func readNumber() -> Int? {
            var digits = ""
            while digits.count < 2, i < chars.count, chars[i].isASCII, let d = chars[i].wholeNumberValue {
                digits.append(String(d))
                i += 1
            }
            return Int(digits)
        }
        /// A colour code's number: 99, and anything past it, is the default.
        func colour(_ number: Int?) -> Colour? {
            number.flatMap { $0 < 99 ? .index($0) : nil }
        }
        /// Reads six hex digits at `at`; nil, and nothing read, without them.
        func readHex(at start: Int) -> UInt32? {
            guard start + 6 <= chars.count else { return nil }
            let digits = chars[start..<start + 6]
            guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            return UInt32(String(digits), radix: 16)
        }

        while i < chars.count {
            let ch = chars[i]
            i += 1
            switch ch {
            case "\u{02}": flush(); style.bold.toggle()
            case "\u{1D}": flush(); style.italic.toggle()
            case "\u{1F}": flush(); style.underline.toggle()
            case "\u{1E}": flush(); style.strikethrough.toggle()
            case "\u{11}": flush(); style.monospace.toggle()
            case "\u{16}":
                // Reverse: one after the other. `swap` would write two parts
                // of `style` at once, which Swift stops at run time, as
                // `flush` holds on to `style` too.
                flush()
                let foreground = style.foreground
                style.foreground = style.background
                style.background = foreground
            case "\u{0F}": flush(); style = Style()
            case "\u{03}":
                flush()
                if let fg = readNumber() {
                    style.foreground = colour(fg)
                    // A comma only belongs to the code when a digit follows it.
                    if i + 1 < chars.count, chars[i] == ",", chars[i + 1].isASCII, chars[i + 1].isNumber {
                        i += 1
                        style.background = colour(readNumber())
                    }
                } else {
                    style.foreground = nil
                    style.background = nil
                }
            case "\u{04}":
                // ^DRRGGBB[,RRGGBB]
                flush()
                if let fg = readHex(at: i) {
                    i += 6
                    style.foreground = .rgb(fg)
                    if i < chars.count, chars[i] == ",", let bg = readHex(at: i + 1) {
                        i += 7
                        style.background = .rgb(bg)
                    }
                } else {
                    style.foreground = nil
                    style.background = nil
                }
            default:
                // Other control characters would render as boxes.
                if ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first,
                   scalar.value < 0x20, scalar != "\t" {
                    continue
                }
                current.append(ch)
            }
        }
        flush()
        return runs
    }

    /// The text without any formatting codes.
    static func strip(_ text: String) -> String {
        runs(text).map(\.text).joined()
    }

    // MARK: - AppKit

    /// Formatted text for the transcript, in the given font and colour.
    static func nsAttributed(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in runs(text) {
            var runFont = font
            var traits: NSFontDescriptor.SymbolicTraits = []
            if run.style.bold { traits.insert(.bold) }
            if run.style.italic { traits.insert(.italic) }
            if run.style.monospace {
                runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            }
            if !traits.isEmpty {
                let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits))
                runFont = NSFont(descriptor: descriptor, size: font.pointSize) ?? runFont
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: nsColor(run.style.foreground).map {
                    run.style.background == nil ? readable($0, fallback: color) : $0
                } ?? color,
            ]
            if let background = nsColor(run.style.background) { attributes[.backgroundColor] = background }
            if run.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        for (range, url) in links(in: result.string) {
            result.addAttribute(.link, value: url, range: range)
        }
        return result
    }

    // MARK: - SwiftUI

    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for run in runs(text) {
            var piece = AttributedString(run.text)
            var font = Font.body
            if run.style.monospace { font = font.monospaced() }
            if run.style.bold { font = font.bold() }
            if run.style.italic { font = font.italic() }
            if run.style != Style() { piece.font = font }
            if run.style.underline { piece.underlineStyle = .single }
            if run.style.strikethrough { piece.strikethroughStyle = .single }
            if let fg = nsColor(run.style.foreground) {
                piece.foregroundColor = Color(nsColor: run.style.background == nil ? readable(fg, fallback: .labelColor) : fg)
            }
            if let bg = nsColor(run.style.background) { piece.backgroundColor = Color(nsColor: bg) }
            result += piece
        }
        let plain = String(result.characters)
        for (range, url) in links(in: plain) {
            if let target = Range(range, in: result) { result[target].link = url }
        }
        return result
    }

    // MARK: - Links

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The http and https links in a message, formatting codes removed, each
    /// once, in order.
    static func webLinks(in text: String) -> [URL] {
        var seen = Set<URL>()
        return links(in: strip(text)).map(\.1).filter {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && seen.insert($0).inserted
        }
    }

    private static func links(in text: String) -> [(NSRange, URL)] {
        guard let detector = linkDetector, text.contains(where: { $0 == "." || $0 == ":" }) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            match.url.map { (match.range, $0) }
        }
    }

    // MARK: - Nick colours

    private static let nickColors: [NSColor] = [
        .systemRed, .systemOrange, .systemGreen, .systemMint, .systemTeal, .systemCyan,
        .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown,
    ]

    /// A stable colour per nick, so a person is recognisable down the screen.
    static func nsColor(forNick nick: String) -> NSColor {
        var hash: UInt32 = 5381
        for byte in nick.lowercased().utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return nickColors[Int(hash % UInt32(nickColors.count))]
    }

    static func color(forNick nick: String) -> Color {
        Color(nsColor: nsColor(forNick: nick))
    }
}
