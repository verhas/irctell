import Foundation

/// Laughs and sad faces in a message, heard as sounds rather than read out:
/// "rotfl" is a big laugh, not "R O T F L".
enum Reaction: String, CaseIterable, Sendable {
    /// :) ;) :P and the smiling emoji.
    case giggle
    /// lol, haha, :D, xD.
    case laugh
    /// rofl, rotfl, lmao, 🤣.
    case bigLaugh
    /// :( :'( and the sad emoji.
    case sad

    static let enabledKey = "speech.reactionSounds"

    /// What finds them. Words as words, ignoring case; faces only standing
    /// apart, so "http://" or "a:(b" do not count.
    private static let patterns: [(Reaction, String)] = [
        (.bigLaugh, #"\b(?:rofl\w*|rotfl\w*|lmf?ao+|roflol)\b|[🤣😂]"#),
        (.laugh, #"\b(?:l(?:o+l+)+[zs]?|lulz?|(?:ha){2,}h?|(?:he){2,}h?|(?:hi){2,}h?|xd+)\b"#
            + #"|(?<!\S)(?:[:;=8]-?D+|:'D)(?!\S)|[😀😃😄😁😆😹]"#),
        (.giggle, #"(?<!\S)(?:[:=]-?\)+|\(+-?[:=]|;-?\)+|:-?[pP]|:\]|\^\^|\^_\^)(?![^\s.,!?])|[🙂😊😉😋😜😛☺]"#),
        (.sad, #"(?<!\S)(?:[:=;]'?-?\(+|:-?\[|\)+-?:|:'\()(?![^\s.,!?])|[🙁☹😞😢😭😔😟😥]"#),
    ]

    private static let expressions: [(Reaction, NSRegularExpression)] = patterns.compactMap { reaction, pattern in
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (reaction, $0) }
    }

    /// A piece of a message: text to say, or a sound.
    enum Piece: Equatable {
        case text(String)
        /// The reaction, and the text it was found in.
        case sound(Reaction, String)

        var reaction: Reaction? {
            if case .sound(let reaction, _) = self { return reaction }
            return nil
        }
    }

    /// The text cut where the laughs and faces are. The same sound twice in
    /// a row is heard once: ":) :)" is one giggle.
    static func pieces(of text: String) -> [Piece] {
        let ns = text as NSString
        var found: [(NSRange, Reaction)] = []
        for (reaction, expression) in expressions {
            for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where !found.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) {
                found.append((match.range, reaction))
            }
        }
        found.sort { $0.0.location < $1.0.location }

        var pieces: [Piece] = []
        var position = 0
        func addText(_ range: NSRange) {
            let piece = ns.substring(with: range)
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
            else { return }
            pieces.append(.text(piece))
        }
        for (range, reaction) in found {
            addText(NSRange(location: position, length: range.location - position))
            if pieces.last?.reaction != reaction { pieces.append(.sound(reaction, ns.substring(with: range))) }
            position = NSMaxRange(range)
        }
        addText(NSRange(location: position, length: ns.length - position))
        return pieces
    }

    // MARK: - The sounds

    /// Irctell's own, and any the user put in ~/.irctell/sounds/<name>/.
    var sounds: [URL] {
        let bundled = (Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("reaction-\(rawValue)-") }
        let own = (try? FileManager.default.contentsOfDirectory(
            at: IrctellHome.directory.appending(path: "sounds/\(rawValue)"), includingPropertiesForKeys: nil)) ?? []
        let audio = Set(["m4a", "mp3", "wav", "aiff", "aif", "caf", "flac"])
        return bundled + own.filter { audio.contains($0.pathExtension.lowercased()) }
    }

    /// One of its sounds, picked at random; nil without any.
    var randomSound: URL? { sounds.randomElement() }
}
