import Foundation

/// How a network compares nicks and channel names. IRC is case-insensitive,
/// and on most networks `[]\~` are the upper case of `{}|^` -- a leftover
/// from the Scandinavian character sets the protocol was born with.
enum IRCCaseMapping: String, Sendable {
    case ascii
    case rfc1459
    case strictRFC1459 = "strict-rfc1459"

    func fold(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "A"..."Z":
                scalars.append(Unicode.Scalar(scalar.value + 32)!)
            case "[" where self != .ascii: scalars.append("{")
            case "]" where self != .ascii: scalars.append("}")
            case "\\" where self != .ascii: scalars.append("|")
            case "~" where self == .rfc1459: scalars.append("^")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    func equal(_ lhs: String, _ rhs: String) -> Bool {
        fold(lhs) == fold(rhs)
    }
}

/// What the server announced about itself in RPL_ISUPPORT (005), with the
/// defaults the protocol assumes for anything it left out.
struct ISupport: Sendable, Equatable {
    /// Every token as sent; a token without `=` maps to "".
    private(set) var tokens: [String: String] = [:]

    /// Folds in one 005 message: `<nick> TOKEN TOKEN=value -TOKEN :are supported`.
    mutating func apply(_ message: IRCMessage) {
        guard message.params.count > 2 else { return }
        for token in message.params[1..<(message.params.count - 1)] {
            if token.hasPrefix("-") {
                tokens[String(token.dropFirst())] = nil
            } else if let eq = token.firstIndex(of: "=") {
                tokens[String(token[..<eq])] = ISupport.unescape(token[token.index(after: eq)...])
            } else {
                tokens[token] = ""
            }
        }
    }

    subscript(key: String) -> String? { tokens[key] }

    var networkName: String? { tokens["NETWORK"].flatMap { $0.isEmpty ? nil : $0 } }

    var caseMapping: IRCCaseMapping {
        tokens["CASEMAPPING"].flatMap(IRCCaseMapping.init(rawValue:)) ?? .rfc1459
    }

    var channelTypes: Set<Character> {
        Set(tokens["CHANTYPES"] ?? "#&")
    }

    /// Channel membership modes, highest rank first, with the symbol each
    /// shows as in NAMES and WHO: `PREFIX=(qaohv)~&@%+`.
    var membershipPrefixes: [(mode: Character, symbol: Character)] {
        let raw = tokens["PREFIX"] ?? "(ov)@+"
        guard raw.first == "(", let close = raw.firstIndex(of: ")") else { return [] }
        let modes = raw[raw.index(after: raw.startIndex)..<close]
        let symbols = raw[raw.index(after: close)...]
        return Array(zip(modes, symbols))
    }

    func isChannel(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return channelTypes.contains(first)
    }

    /// Whether a channel mode letter takes a parameter when set or unset.
    /// CHANMODES=A,B,C,D: A (lists) and B always do, C only when set, D
    /// never; membership modes (o, v, ...) always name a nick.
    func modeTakesParameter(_ mode: Character, adding: Bool) -> Bool {
        if membershipPrefixes.contains(where: { $0.mode == mode }) { return true }
        let groups = (tokens["CHANMODES"] ?? "beI,k,l,imnpst")
            .split(separator: ",", omittingEmptySubsequences: false)
        if groups.count > 0, groups[0].contains(mode) { return true }
        if groups.count > 1, groups[1].contains(mode) { return true }
        if groups.count > 2, groups[2].contains(mode) { return adding }
        return false
    }

    /// The symbol a membership mode shows as: `o` is `@`.
    func membershipSymbol(for mode: Character) -> Character? {
        membershipPrefixes.first { $0.mode == mode }?.symbol
    }

    /// Lower is higher rank: the position of the member's best prefix, or
    /// past the end for a member with none.
    func rank(ofPrefixes symbols: String) -> Int {
        let order = membershipPrefixes.map(\.symbol)
        return symbols.compactMap { order.firstIndex(of: $0) }.min() ?? order.count
    }

    /// Splits `@+nick` from a NAMES reply into its prefix symbols and nick;
    /// several symbols appear when multi-prefix is enabled.
    func splitMembership(_ entry: String) -> (symbols: String, nick: String) {
        let symbols = Set(membershipPrefixes.map(\.symbol))
        let prefix = entry.prefix { symbols.contains($0) }
        return (String(prefix), String(entry.dropFirst(prefix.count)))
    }

    /// Values may carry `\xHH` escapes, e.g. a NETWORK name with a space.
    private static func unescape(_ raw: Substring) -> String {
        var bytes: [UInt8] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "\\",
               let x = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex), x < raw.endIndex, raw[x] == "x",
               let end = raw.index(index, offsetBy: 4, limitedBy: raw.endIndex),
               let byte = UInt8(raw[raw.index(index, offsetBy: 2)..<end], radix: 16) {
                bytes.append(byte)
                index = end
            } else {
                bytes.append(contentsOf: Array(String(raw[index]).utf8))
                index = raw.index(after: index)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
