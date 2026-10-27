import XCTest
@testable import Irctell

/// Plays the server: the test pushes lines to the client and reads back what
/// the client wrote, one line at a time.
final class FakeTransport: IRCTransport {
    private let incoming: AsyncThrowingStream<Data, Error>
    private let toClient: AsyncThrowingStream<Data, Error>.Continuation
    private let fromClient: AsyncStream<String>.Continuation
    private let reader: SharedIterator

    init() {
        (incoming, toClient) = AsyncThrowingStream.makeStream()
        let (written, fromClient) = AsyncStream<String>.makeStream()
        self.fromClient = fromClient
        reader = SharedIterator(written.makeAsyncIterator())
    }

    func open() async throws -> AsyncThrowingStream<Data, Error> { incoming }

    func send(_ data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\r\n") { fromClient.yield(String(line)) }
    }

    func close() { toClient.finish() }

    func serverSends(_ lines: String...) {
        for line in lines { toClient.yield(Data((line + "\r\n").utf8)) }
    }

    /// The next line the client wrote, failing the test after a second.
    func nextLine(file: StaticString = #filePath, line: UInt = #line) async -> String? {
        let iterator = reader
        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if result == nil { XCTFail("the client wrote nothing", file: file, line: line) }
        return result
    }

    func expect(_ expected: String..., file: StaticString = #filePath, line: UInt = #line) async {
        for want in expected {
            let got = await nextLine(file: file, line: line)
            XCTAssertEqual(got, want, file: file, line: line)
        }
    }
}

/// AsyncStream iterators are not Sendable; this lets one be used from a
/// child task. Only ever one reader at a time in these tests.
private final class SharedIterator: @unchecked Sendable {
    private var iterator: AsyncStream<String>.Iterator
    init(_ iterator: AsyncStream<String>.Iterator) { self.iterator = iterator }
    func next() async -> String? { await iterator.next() }
}

final class IRCClientTests: XCTestCase {

    private func makeClient(_ configure: (inout IRCServerConfig) -> Void = { _ in })
        -> (IRCClient, FakeTransport) {
        var config = IRCServerConfig(host: "irc.example.org", nick: "tester", realName: "Test User")
        configure(&config)
        let fake = FakeTransport()
        return (IRCClient(config: config, makeTransport: { _ in fake }), fake)
    }

    private func waitForState(_ client: IRCClient, _ wanted: IRCConnectionState,
                              file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if await client.state == wanted { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let state = await client.state
        XCTFail("state is \(state), wanted \(wanted)", file: file, line: line)
    }

    func testRegistersWithCapabilitiesAndSASL() async {
        let (client, server) = makeClient {
            $0.sasl = SASLCredentials(account: "tester", password: "secret")
            $0.serverPassword = "bouncer"
        }
        await client.connect()

        await server.expect("CAP LS 302", "PASS bouncer", "NICK tester", "USER tester 0 * :Test User")

        server.serverSends(":srv CAP * LS * :multi-prefix sasl=PLAIN,EXTERNAL",
                           ":srv CAP * LS :server-time unknown-cap")
        await server.expect("CAP REQ :multi-prefix sasl server-time")

        server.serverSends(":srv CAP tester ACK :multi-prefix sasl server-time")
        await server.expect("AUTHENTICATE PLAIN")

        server.serverSends("AUTHENTICATE +")
        await server.expect("AUTHENTICATE dGVzdGVyAHRlc3RlcgBzZWNyZXQ=")

        server.serverSends(":srv 900 tester tester!t@h tester :You are now logged in as tester",
                           ":srv 903 tester :SASL authentication successful")
        await server.expect("CAP END")

        server.serverSends(":srv 001 tester :Welcome", ":srv 005 tester NETWORK=Example :are supported")
        await waitForState(client, .registered)
        let capabilities = await client.capabilities
        let account = await client.account
        let network = await client.isupport.networkName
        XCTAssertEqual(capabilities, ["multi-prefix", "sasl", "server-time"])
        XCTAssertEqual(account, "tester")
        XCTAssertEqual(network, "Example")

        await client.disconnect(reason: "bye")
        await server.expect("QUIT bye")
        await waitForState(client, .disconnected)
    }

    func testSASLFailureStillRegisters() async {
        let (client, server) = makeClient { $0.sasl = SASLCredentials(account: "a", password: "b") }
        await client.connect()
        await server.expect("CAP LS 302", "NICK tester", "USER tester 0 * :Test User")
        server.serverSends(":srv CAP * LS :sasl")
        await server.expect("CAP REQ sasl")
        server.serverSends(":srv CAP * ACK sasl")
        await server.expect("AUTHENTICATE PLAIN")
        server.serverSends("AUTHENTICATE +")
        _ = await server.nextLine()
        server.serverSends(":srv 904 tester :SASL authentication failed")
        await server.expect("CAP END")

        var sawFailure = false
        for await event in client.events {
            if case .saslFailed(let reason) = event {
                XCTAssertEqual(reason, "SASL authentication failed")
                sawFailure = true
                break
            }
        }
        XCTAssertTrue(sawFailure)
        await client.disconnect()
    }

    func testServerWithoutCapabilitiesEndsNegotiationAtOnce() async {
        let (client, server) = makeClient()
        await client.connect()
        await server.expect("CAP LS 302", "NICK tester", "USER tester 0 * :Test User")
        server.serverSends(":srv CAP * LS :")
        await server.expect("CAP END")
        await client.disconnect()
    }

    func testNickInUseTriesAlternatesThenUnderscores() async {
        let (client, server) = makeClient { $0.alternateNicks = ["tester2"] }
        await client.connect()
        await server.expect("CAP LS 302", "NICK tester", "USER tester 0 * :Test User")
        server.serverSends(":srv 433 * tester :Nickname is already in use")
        await server.expect("NICK tester2")
        server.serverSends(":srv 433 * tester2 :Nickname is already in use")
        await server.expect("NICK tester_")
        server.serverSends(":srv 001 tester_ :Welcome")
        await waitForState(client, .registered)
        let nick = await client.nick
        XCTAssertEqual(nick, "tester_")
        await client.disconnect()
    }

    func testAnswersPingAndTracksOwnNickChanges() async {
        let (client, server) = makeClient()
        await client.connect()
        await server.expect("CAP LS 302", "NICK tester", "USER tester 0 * :Test User")
        server.serverSends(":srv 001 tester :Welcome", "PING :12345")
        await server.expect("PONG 12345")
        server.serverSends(":Tester!u@h NICK :renamed")
        for _ in 0..<100 where await client.nick != "renamed" {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let nick = await client.nick
        XCTAssertEqual(nick, "renamed")
        await client.disconnect()
    }

    func testAnswersDirectCTCPButNotChannelCTCP() async {
        let (client, server) = makeClient()
        await client.connect()
        await server.expect("CAP LS 302", "NICK tester", "USER tester 0 * :Test User")
        server.serverSends(":srv 001 tester :Welcome",
                           ":bob!b@h PRIVMSG #chan :\u{01}VERSION\u{01}",
                           ":bob!b@h PRIVMSG tester :\u{01}PING 42\u{01}")
        await server.expect("NOTICE bob :\u{01}PING 42\u{01}")
        await client.disconnect()
    }

    func testReconnectsAfterServerCloses() async {
        let first = FakeTransport(), second = FakeTransport()
        let transports = LockedQueue([first, second])
        var config = IRCServerConfig(host: "h", nick: "tester")
        config.timeouts.reconnectInitial = .milliseconds(10)
        let client = IRCClient(config: config, makeTransport: { _ in transports.pop() })

        await client.connect()
        await first.expect("CAP LS 302")
        first.serverSends("ERROR :Closing link")
        await second.expect("CAP LS 302")
        await client.disconnect()
    }

    func testPreparesBeforeEveryAttemptAndRetriesWhenPreparingFails() async {
        let transport = FakeTransport()
        let attempts = Counter()
        var config = IRCServerConfig(host: "h", nick: "tester")
        config.timeouts.reconnectInitial = .milliseconds(10)
        let client = IRCClient(config: config, makeTransport: { _ in transport })
        await client.setPreparation {
            // The tunnel will not open the first time.
            if attempts.increment() == 1 { throw URLError(.cannotConnectToHost) }
        }
        await client.connect()
        await transport.expect("CAP LS 302")
        XCTAssertEqual(attempts.value, 2)
        await client.disconnect()
    }

    func testReconnectBackoffDoublesUpToMaximum() async {
        var config = IRCServerConfig(host: "h", nick: "n")
        config.timeouts.reconnectInitial = .seconds(2)
        config.timeouts.reconnectMaximum = .seconds(60)
        let client = IRCClient(config: config, makeTransport: { _ in FakeTransport() })
        let delays = await [1, 2, 3, 5, 6, 40].asyncMap { await client.reconnectDelay(attempt: $0) }
        XCTAssertEqual(delays, [.seconds(2), .seconds(4), .seconds(8), .seconds(32), .seconds(60), .seconds(60)])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class LockedQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FakeTransport]
    init(_ items: [FakeTransport]) { self.items = items }
    func pop() -> FakeTransport { lock.withLock { items.removeFirst() } }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for item in self { result.append(await transform(item)) }
        return result
    }
}
