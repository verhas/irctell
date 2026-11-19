import Foundation

/// Servers cut every line at 512 bytes, including the prefix they add on
/// relaying it, so long text has to be sent as several messages.
enum IRCTextSplitter {

    /// The bytes of text that fit in one `COMMAND target :text` line, leaving
    /// room for the `:nick!user@host ` prefix the server puts in front. The
    /// user and host are not known for certain, so their maximum is assumed.
    static func maximumTextBytes(command: String, target: String, nick: String) -> Int {
        let prefix = 1 + nick.utf8.count + 1 + 10 + 1 + 63 + 1
        let line = command.utf8.count + 1 + target.utf8.count + 2
        return max(64, 510 - prefix - line)
    }

    /// Splits at spaces where possible, never inside a character.
    static func split(_ text: String, maxBytes: Int) -> [String] {
        pieces(of: Substring(text), maxBytes: maxBytes).map(String.init)
    }

    /// The messages `text` is sent as, each still pointing into the text:
    /// the input field draws where one ends and the next starts.
    static func pieces(of text: Substring, maxBytes: Int) -> [Substring] {
        var pieces: [Substring] = []
        var rest = text
        while rest.utf8.count > maxBytes {
            var bytes = 0
            var end = rest.startIndex
            var lastSpace: Substring.Index?
            for index in rest.indices {
                let width = rest[index].utf8.count
                if bytes + width > maxBytes { break }
                bytes += width
                if rest[index] == " " { lastSpace = index }
                end = rest.index(after: index)
            }
            // A space right at the limit is the best place of all.
            if end < rest.endIndex, rest[end] == " " { lastSpace = end }
            if let space = lastSpace, space > rest.startIndex {
                pieces.append(rest[..<space])
                rest = rest[rest.index(after: space)...]
            } else {
                // One word longer than a line, or a single huge character.
                if end == rest.startIndex { end = rest.index(after: end) }
                pieces.append(rest[..<end])
                rest = rest[end...]
            }
        }
        if !rest.isEmpty || pieces.isEmpty { pieces.append(rest) }
        return pieces
    }
}
