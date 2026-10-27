import XCTest
@testable import Irctell

final class IRCMessageTests: XCTestCase {

    func testParsesFullLine() throws {
        let message = try XCTUnwrap(IRCMessage(parsing:
            "@time=2026-10-14T12:30:00.123Z;msgid=abc :alice!al@example.org PRIVMSG #alpha :hello there\r\n"))
        XCTAssertEqual(message.tags["msgid"], "abc")
        XCTAssertEqual(message.prefix, IRCPrefix(name: "alice", user: "al", host: "example.org"))
        XCTAssertEqual(message.command, "PRIVMSG")
        XCTAssertEqual(message.params, ["#alpha", "hello there"])
        XCTAssertEqual(try XCTUnwrap(message.serverTime).timeIntervalSince1970, 1_791_981_000.123, accuracy: 0.0005)
    }

    func testParsesServerPrefixNumericAndMiddleParams() throws {
        let message = try XCTUnwrap(IRCMessage(parsing: ":irc.example.org 005 me NETWORK=Test CHANTYPES=# :are supported"))
        XCTAssertEqual(message.prefix?.name, "irc.example.org")
        XCTAssertNil(message.prefix?.user)
        XCTAssertEqual(message.numeric, 5)
        XCTAssertEqual(message.params, ["me", "NETWORK=Test", "CHANTYPES=#", "are supported"])
    }

    func testToleratesExtraSpacesAndEmptyTrailing() throws {
        let message = try XCTUnwrap(IRCMessage(parsing: "TOPIC   #a  :"))
        XCTAssertEqual(message.params, ["#a", ""])
        XCTAssertNil(IRCMessage(parsing: ""))
        XCTAssertNil(IRCMessage(parsing: "@a=b "))
    }

    func testLowercaseCommandIsNormalised() {
        XCTAssertEqual(IRCMessage(parsing: "ping :x")?.command, "PING")
    }

    func testTagEscapingRoundTrips() throws {
        let value = "a;b c\\d\r\ne"
        let message = IRCMessage(tags: ["+draft/reply": "1", "k": value], command: "TAGMSG", params: ["#x"])
        XCTAssertEqual(message.serialized, "@+draft/reply=1;k=a\\:b\\sc\\\\d\\r\\ne TAGMSG #x")
        let parsed = try XCTUnwrap(IRCMessage(parsing: message.serialized))
        XCTAssertEqual(parsed.tags["k"], value)
    }

    func testUnescapeDropsTrailingBackslashAndUnknownEscapes() {
        XCTAssertEqual(IRCMessage.unescapeTagValue("a\\b\\"), "ab")
        XCTAssertEqual(IRCMessage.parseTags("flag;x=")["flag"], "")
    }

    func testSerializesTrailingOnlyWhenNeeded() {
        XCTAssertEqual(IRCMessage("NICK", "bob").serialized, "NICK bob")
        XCTAssertEqual(IRCMessage("PRIVMSG", "#a", "hi there").serialized, "PRIVMSG #a :hi there")
        XCTAssertEqual(IRCMessage("PRIVMSG", "#a", ":)").serialized, "PRIVMSG #a ::)")
        XCTAssertEqual(IRCMessage("TOPIC", "#a", "").serialized, "TOPIC #a :")
    }

    func testSerializeStripsLineBreaksAgainstInjection() {
        let message = IRCMessage("PRIVMSG", "#a", "hi\r\nQUIT :pwned")
        XCTAssertEqual(message.serialized, "PRIVMSG #a :hiQUIT :pwned")
        XCTAssertFalse(message.serialized.contains("\n"))
    }

    func testPrefixParsing() {
        XCTAssertEqual(IRCPrefix(parsing: "nick@host"), IRCPrefix(name: "nick", host: "host"))
        XCTAssertEqual(IRCPrefix(parsing: "n!u@h").description, "n!u@h")
    }
}

final class IRCLineBufferTests: XCTestCase {

    func testSplitsAcrossChunks() {
        var buffer = IRCLineBuffer()
        XCTAssertEqual(buffer.append(Data("PING :a\r\nPRIV".utf8)), ["PING :a"])
        XCTAssertEqual(buffer.append(Data("MSG #x :y\n\r\n".utf8)), ["PRIVMSG #x :y"])
    }

    func testFallsBackToLatin1() {
        var buffer = IRCLineBuffer()
        let latin1: [UInt8] = Array("PRIVMSG #x :caf".utf8) + [0xE9, 0x0D, 0x0A]
        XCTAssertEqual(buffer.append(Data(latin1)), ["PRIVMSG #x :café"])
    }

    func testDiscardsRunawayLine() {
        var buffer = IRCLineBuffer()
        _ = buffer.append(Data(repeating: 0x41, count: IRCLineBuffer.maximumLineLength + 1))
        XCTAssertEqual(buffer.append(Data("\r\nPING :b\r\n".utf8)), ["PING :b"])
    }
}

final class ISupportTests: XCTestCase {

    func testAppliesTokensAndDefaults() throws {
        var support = ISupport()
        XCTAssertEqual(support.caseMapping, .rfc1459)
        XCTAssertTrue(support.isChannel("&local"))

        support.apply(try XCTUnwrap(IRCMessage(parsing:
            ":s 005 me NETWORK=Libera\\x20Chat CASEMAPPING=ascii CHANTYPES=# PREFIX=(qov)~@+ WHOX :are supported")))
        XCTAssertEqual(support.networkName, "Libera Chat")
        XCTAssertEqual(support.caseMapping, .ascii)
        XCTAssertFalse(support.isChannel("&local"))
        XCTAssertEqual(support["WHOX"], "")
        XCTAssertEqual(support.membershipPrefixes.map(\.symbol), ["~", "@", "+"])
        XCTAssertTrue(support.splitMembership("~@nick") == ("~@", "nick"))

        support.apply(try XCTUnwrap(IRCMessage(parsing: ":s 005 me -WHOX :are supported")))
        XCTAssertNil(support["WHOX"])
    }

    func testCaseMapping() {
        XCTAssertTrue(IRCCaseMapping.rfc1459.equal("Nick[a]~", "nick{A}^"))
        XCTAssertFalse(IRCCaseMapping.strictRFC1459.equal("a~", "a^"))
        XCTAssertFalse(IRCCaseMapping.ascii.equal("[", "{"))
    }
}

final class SASLAndCTCPTests: XCTestCase {

    func testPlainPayload() {
        XCTAssertEqual(SASL.plainPayload(account: "tester", password: "secret"),
                       ["dGVzdGVyAHRlc3RlcgBzZWNyZXQ="])
    }

    func testChunkingAt400() {
        XCTAssertEqual(SASL.chunk(String(repeating: "A", count: 400)).count, 2)
        XCTAssertEqual(SASL.chunk(String(repeating: "A", count: 400)).last, "+")
        XCTAssertEqual(SASL.chunk(String(repeating: "A", count: 401)).map(\.count), [400, 1])
        XCTAssertEqual(SASL.chunk(""), ["+"])
    }

    func testCTCP() throws {
        let action = try XCTUnwrap(CTCP(text: "\u{01}ACTION waves\u{01}"))
        XCTAssertEqual(action, CTCP(command: "ACTION", argument: "waves"))
        XCTAssertNil(action.reply(version: "v"))
        XCTAssertEqual(CTCP(text: "\u{01}version")?.reply(version: "v")?.text, "\u{01}VERSION v\u{01}")
        XCTAssertNil(CTCP(text: "plain text"))
    }
}
