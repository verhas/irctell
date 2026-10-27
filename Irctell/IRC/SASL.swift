import Foundation

enum SASL {
    /// The AUTHENTICATE parameters that carry a PLAIN login.
    ///
    /// The payload is `authzid NUL authcid NUL password`, base64-encoded and
    /// cut into 400-byte pieces. A final piece of exactly 400 bytes is followed
    /// by `+`, so the server can tell the payload ended rather than that more
    /// is on its way.
    static func plainPayload(account: String, password: String) -> [String] {
        let raw = Data((account + "\0" + account + "\0" + password).utf8)
        return chunk(raw.base64EncodedString())
    }

    static func chunk(_ encoded: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(encoded)
        while !rest.isEmpty {
            pieces.append(String(rest.prefix(400)))
            rest = rest.dropFirst(400)
        }
        if pieces.isEmpty || pieces.last?.count == 400 {
            pieces.append("+")
        }
        return pieces
    }
}
