import Foundation

/// Cuts the incoming byte stream into lines. TCP delivers bytes in whatever
/// chunks it likes, so a line can arrive split across reads, and one read can
/// hold many lines.
struct IRCLineBuffer {
    /// The longest line accepted: 8191 bytes of tags plus the 512 of the
    /// message itself, with room to spare. A server that never sends a line
    /// break would otherwise grow the buffer without limit.
    static let maximumLineLength = 16 * 1024

    private var pending = Data()

    /// Appends a chunk and returns every line it completed, without line ends.
    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            pending = Data(pending[pending.index(after: newline)...])
            if !line.isEmpty { lines.append(IRCLineBuffer.decode(line)) }
        }
        if pending.count > IRCLineBuffer.maximumLineLength {
            pending.removeAll()
        }
        return lines
    }

    /// IRC has no declared encoding. Nearly everything is UTF-8 now; what is
    /// not is almost always Latin-1 from an old client, and decoding that as
    /// ISO 8859-1 never fails, so no line is ever lost to its encoding.
    static func decode(_ bytes: Data) -> String {
        String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }
}

