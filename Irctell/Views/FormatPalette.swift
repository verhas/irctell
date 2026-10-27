import AppKit
import SwiftUI

/// The mIRC codes a message is formatted with, as typed with ⌃B, ⌃I, ⌃U,
/// ⌃K and ⌃O, or picked in the format palette.
enum FormatCode: String, CaseIterable {
    case bold = "\u{02}", italic = "\u{1D}", underline = "\u{1F}", strikethrough = "\u{1E}", plain = "\u{0F}"

    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .plain: "Plain"
        }
    }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .plain: "textformat.characters.dottedunderline"
        }
    }

    var shortcut: String {
        switch self {
        case .bold: "⌃B"
        case .italic: "⌃I"
        case .underline: "⌃U"
        case .strikethrough: ""
        case .plain: "⌃O"
        }
    }

    /// A colour code: always two digits, so a message starting with a digit
    /// does not change the colour. Without a foreground, 99, the default.
    static func colour(foreground: Int?, background: Int? = nil) -> String {
        let fg = String(format: "%02d", foreground ?? 99)
        return "\u{03}" + fg + (background.map { String(format: ",%02d", $0) } ?? "")
    }

    /// Whether the text has any formatting code in it.
    static func isFormatted(_ text: String) -> Bool {
        text.unicodeScalars.contains { [0x02, 0x03, 0x04, 0x0F, 0x11, 0x16, 0x1D, 0x1E, 0x1F].contains($0.value) }
    }
}

/// Bold, italics and the rest, and mIRC's 99 colours: a click adds the code
/// to the end of the message; what follows it is formatted so.
struct FormatPalette: View {
    let insert: (String) -> Void
    @State private var isBackground = false
    @State private var showsExtended = false
    /// The foreground last picked, which a background goes with.
    @State private var foreground: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(FormatCode.allCases, id: \.self) { code in
                    Button {
                        if code == .plain { foreground = nil }
                        insert(code.rawValue)
                    } label: {
                        Image(systemName: code.symbol)
                            .frame(width: 22, height: 18)
                    }
                    .help(code.shortcut.isEmpty ? code.title : "\(code.title) (\(code.shortcut))")
                }
            }
            Picker("Colour", selection: $isBackground) {
                Text("Text").tag(false)
                Text("Background").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            swatches(0..<16, columns: 8)
            DisclosureGroup("More colours", isExpanded: $showsExtended) {
                swatches(16..<99, columns: 12)
                    .padding(.top, 4)
            }
            .font(.callout)
            Text("Codes are added at the end of the message. Without a colour or after Plain, text is drawn as usual.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 300)
    }

    private func swatches(_ range: Range<Int>, columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: columns), spacing: 4) {
            ForEach(Array(range), id: \.self) { index in
                Button {
                    if isBackground {
                        insert(FormatCode.colour(foreground: foreground, background: index))
                    } else {
                        foreground = index
                        insert(FormatCode.colour(foreground: index))
                    }
                } label: {
                    swatch(index)
                }
                .buttonStyle(.plain)
                .help(index < 16 ? "\(index): \(IRCFormatting.colourNames[index])" : "\(index)")
            }
        }
    }

    private func swatch(_ index: Int) -> some View {
        let colour: NSColor = IRCFormatting.nsColor(.index(index)) ?? .clear
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color(nsColor: colour))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
            .frame(width: 18, height: 18)
    }
}

/// Opens the system's Character Viewer, with its emoji, for the text field
/// that has the focus.
struct EmojiButton: View {
    let focus: () -> Void

    var body: some View {
        Button {
            focus()
            // Once the field is first responder, so the emoji go into it.
            Task { @MainActor in NSApp.orderFrontCharacterPalette(nil) }
        } label: {
            Image(systemName: "face.smiling")
        }
        .buttonStyle(.borderless)
        .help("Emoji and symbols (⌃⌘Space)")
    }
}
