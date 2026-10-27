import AppKit
import SwiftUI
import XCTest
@testable import Irctell

@MainActor
final class AppModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A model as on a launch: everything read from the directory's files.
    private func makeModel() -> AppModel {
        AppModel(store: NetworkStore(fileURL: directory.appending(path: "networks.plist"), usesKeychain: false),
                 settings: SettingsStore(fileURL: directory.appending(path: "settings.plist")),
                 log: try? LogStore(fileURL: directory.appending(path: "logs.sqlite")))
    }

    func testFirstRunStartsWithTheKnownNetworks() {
        let model = makeModel()
        XCTAssertGreaterThan(model.networks.count, 30)
        XCTAssertTrue(model.networks.contains { $0.host == "irc.libera.chat" && $0.useTLS && $0.port == 6697 })
        XCTAssertTrue(model.sessions.isEmpty, "nothing is opened on its own")
        XCTAssertEqual(makeModel().networks.map(\.id), model.networks.map(\.id), "the seeded list is saved")

        model.remove([model.networks[0].id])
        XCTAssertEqual(makeModel().networks.count, model.networks.count, "seeded once, not on every launch")
    }

    func testAnSSHTunnelThatCannotOpenSaysWhy() async {
        do {
            try await SSHTunnelService.shared.ensureOpen(to: "nobody@irctell-test.invalid", port: 54_321)
            XCTFail("there is no such server")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("ssh: "), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("irctell-test.invalid"), error.localizedDescription)
        }
        XCTAssertFalse(SSHTunnelService.shared.isOpen(to: "nobody@irctell-test.invalid", port: 54_321))
    }

    func testANetworkThroughAProxy() throws {
        var config = NetworkConfig(name: "Tor", host: "libera75jm6of4wxpxt4aynol3xjmbtxgfyjpu34ss4d7r7q2v5zrpyd.onion",
                                   port: 6697, nick: "me")
        XCTAssertNil(config.serverConfig(defaults: .current).proxy, "none unless asked for")
        config.proxyKind = .socks
        config.proxyPort = 1080
        config.proxyUsername = "user"
        XCTAssertEqual(config.serverConfig(defaults: .current).proxy,
                       SOCKSProxy(host: "127.0.0.1", port: 1080, username: "user", password: nil))
        config.proxyKind = .ssh
        config.sshDestination = "me@vps.example.org"
        config.sshTunnelPort = 1081
        XCTAssertEqual(config.serverConfig(defaults: .current).proxy, SOCKSProxy(host: "127.0.0.1", port: 1081))
        XCTAssertEqual(SSHTunnelService.arguments(destination: "me@vps.example.org", port: 1081).suffix(4),
                       ["-o", "ServerAliveCountMax=3", "--", "me@vps.example.org"])
        XCTAssertTrue(SSHTunnelService.arguments(destination: "x", port: 1081).contains("127.0.0.1:1081"),
                      "the proxy only for this Mac")
        config.proxyKind = .tor
        let tor = try XCTUnwrap(config.serverConfig(defaults: .current).proxy)
        XCTAssertEqual(tor.host, "127.0.0.1")
        XCTAssertEqual(tor.port, 9050)
        XCTAssertEqual(tor.username, "irctell-\(config.id.uuidString.prefix(8))", "circuits of its own")

        let model = makeModel()
        model.save(config)
        let saved = try XCTUnwrap(makeModel().network(config.id))
        XCTAssertEqual(saved.proxyKind, .tor)
        XCTAssertEqual(saved.proxyPort, 1080)
        XCTAssertEqual(saved.proxyUsername, "user")
        XCTAssertEqual(saved.sshDestination, "me@vps.example.org")
        XCTAssertEqual(saved.sshTunnelPort, 1081)
        XCTAssertEqual(model.mediaMode(network: config.id, bufferKey: "#a", kind: .channel), .off,
                       "pictures would be fetched around the proxy")

        XCTAssertEqual(SOCKS5Framer.error(forReply: 5), .ECONNREFUSED)
        XCTAssertEqual(SOCKS5Framer.error(forReply: 4), .EHOSTUNREACH)
    }

    func testOpeningAndClosingTabsKeepsTheList() throws {
        let model = makeModel()
        let libera = try XCTUnwrap(model.networks.first { $0.host == "irc.libera.chat" })
        let oftc = try XCTUnwrap(model.networks.first { $0.host == "irc.oftc.net" })

        model.open(libera.id)
        model.open(oftc.id)
        model.open(libera.id)
        XCTAssertEqual(model.sessions.map(\.id), [libera.id, oftc.id], "opening twice brings the tab forward")
        XCTAssertEqual(model.selectedSessionID, libera.id)

        let restored = makeModel()
        restored.start()
        XCTAssertEqual(restored.sessions.map(\.id), [libera.id, oftc.id], "open tabs come back on the next launch")

        model.closeTab(try XCTUnwrap(model.session(for: libera.id)))
        XCTAssertEqual(model.sessions.map(\.id), [oftc.id])
        XCTAssertEqual(model.selectedSessionID, oftc.id)
        XCTAssertNotNil(model.network(libera.id), "closing a tab keeps the network")

        for session in model.sessions + restored.sessions { session.disconnect() }
    }

    func testFavouritesSortFirstAndRemovingClosesTheTab() throws {
        let model = makeModel()
        let undernet = try XCTUnwrap(model.networks.first { $0.host == "irc.undernet.org" })
        model.toggleFavorite(undernet.id)
        XCTAssertEqual(model.sortedNetworks.first?.id, undernet.id)

        model.open(undernet.id)
        model.remove([undernet.id])
        XCTAssertNil(model.network(undernet.id))
        XCTAssertTrue(model.sessions.isEmpty)

        XCTAssertEqual(model.addKnownNetworks(), 1, "only the removed one is missing")
    }

    func testOpenChannelsAndChatsComeBackOnTheNextLaunch() throws {
        let model = makeModel()
        let libera = try XCTUnwrap(model.networks.first { $0.host == "irc.libera.chat" })
        model.toggleConnectAtLaunch(libera.id)
        model.open(libera.id, connect: false)
        let session = try XCTUnwrap(model.session(for: libera.id))
        session.handle(.registered(nick: "me"))
        for line in [":me!u@h JOIN #alpha", ":me!u@h JOIN #beta", ":bob!b@h PRIVMSG me :hi"] {
            session.handle(.received(IRCMessage(parsing: line)!))
        }
        session.selectedBufferID = session.buffer(named: "#beta")?.id
        model.toggleAutoJoin("#alpha", on: libera.id)
        XCTAssertEqual(model.network(libera.id)?.autoJoin, ["#alpha"], "Rejoin at Login is the auto-join list")

        let restored = makeModel()
        restored.start()
        let again = try XCTUnwrap(restored.session(for: libera.id))
        XCTAssertTrue(again.isOffline, "Connect at Launch is off")
        XCTAssertEqual(again.buffers.map(\.name), ["Libera.Chat", "MemoServ", "#alpha", "#beta", "bob"])
        XCTAssertEqual(again.buffer(named: "bob")?.kind, .query)
        XCTAssertEqual(again.selectedBuffer?.name, "#beta")
        XCTAssertFalse(again.buffer(named: "#alpha")?.isJoined ?? true, "shown, joined only once connected")

        restored.toggleAutoJoin("#ALPHA", on: libera.id)
        XCTAssertEqual(restored.network(libera.id)?.autoJoin, [])
    }

    func testTabsAreReorderedByDragging() {
        let model = makeModel()
        let ids = Array(model.networks.prefix(3).map(\.id))
        // Never connected: not now, and not when started again below.
        for id in ids where model.network(id)?.connectAtLaunch == true { model.toggleConnectAtLaunch(id) }
        for id in ids { model.open(id, select: false, connect: false) }
        model.moveSession(ids[2], toGap: 0)
        XCTAssertEqual(model.sessions.map(\.id), [ids[2], ids[0], ids[1]], "before the first")
        model.moveSession(ids[2], toGap: 3)
        XCTAssertEqual(model.sessions.map(\.id), [ids[0], ids[1], ids[2]], "after the last")
        model.moveSession(ids[0], toGap: 1)
        XCTAssertEqual(model.sessions.map(\.id), [ids[0], ids[1], ids[2]], "its own gap: nothing moves")
        model.moveSession(ids[0], toGap: 2)
        let restored = makeModel()
        restored.start()
        XCTAssertEqual(restored.sessions.map(\.id), [ids[1], ids[0], ids[2]], "the order kept for the next launch")
    }

    func testTheTabBarIsOneLineHigh() async throws {
        let model = makeModel()
        for id in model.networks.prefix(2).map(\.id) {
            if model.network(id)?.connectAtLaunch == true { model.toggleConnectAtLaunch(id) }
            model.open(id, select: false, connect: false)
        }
        // Laid out as in the window: the bar above content that takes the rest.
        final class Height { var value: CGFloat = 0 }
        let measured = Height()
        let content = VStack(spacing: 0) {
            NetworkTabBar()
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { measured.value = geometry.size.height }
                })
            Color.clear
        }
        .environment(model)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        defer { window.close() }
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        for _ in 0..<50 where measured.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(measured.value, 0)
        XCTAssertLessThan(measured.value, 50, "one row of tabs, not half the window")
    }

    func testTheUnseenPrivateChatWaitingLongestIsOpened() throws {
        let model = makeModel()
        let ids = Array(model.networks.prefix(2).map(\.id))
        for id in ids {
            if model.network(id)?.connectAtLaunch == true { model.toggleConnectAtLaunch(id) }
            model.open(id, select: false, connect: false)
        }
        let first = try XCTUnwrap(model.session(for: ids[0])), second = try XCTUnwrap(model.session(for: ids[1]))
        for session in [first, second] { session.handle(.registered(nick: "me")) }
        func privately(_ session: NetworkSession, _ line: String) {
            session.handle(.received(IRCMessage(parsing: line)!))
        }
        XCTAssertTrue(model.unseenPrivateChats.isEmpty)
        privately(first, "@time=2026-10-17T10:05:00.000Z :bob!b@h PRIVMSG me :later")
        privately(second, "@time=2026-10-17T10:01:00.000Z :carol!c@h PRIVMSG me :earliest")
        privately(first, "@time=2026-10-17T10:03:00.000Z :dave!d@h PRIVMSG me :between")
        privately(second, "@time=2026-10-17T10:09:00.000Z :carol!c@h PRIVMSG me :again")
        XCTAssertEqual(model.unseenPrivateChats.map(\.buffer.name), ["carol", "dave", "bob"],
                       "by their oldest unseen message, across networks")

        model.showOldestUnseenPrivateChat()
        XCTAssertEqual(model.selectedSessionID, second.id, "to the other network")
        XCTAssertEqual(second.selectedBuffer?.name, "carol")
        XCTAssertEqual(model.unseenPrivateChats.map(\.buffer.name), ["dave", "bob"], "seen now")
        model.showOldestUnseenPrivateChat()
        XCTAssertEqual(first.selectedBuffer?.name, "dave")
        model.showOldestUnseenPrivateChat()
        XCTAssertEqual(first.selectedBuffer?.name, "bob")
        XCTAssertTrue(model.unseenPrivateChats.isEmpty)
    }

    func testOptionTabOpensUnseenChatsThenGoesBackAndForth() throws {
        let model = makeModel()
        let ids = Array(model.networks.prefix(2).map(\.id))
        for id in ids {
            if model.network(id)?.connectAtLaunch == true { model.toggleConnectAtLaunch(id) }
            model.open(id, select: false, connect: false)
        }
        let first = try XCTUnwrap(model.session(for: ids[0])), second = try XCTUnwrap(model.session(for: ids[1]))
        for session in [first, second] { session.handle(.registered(nick: "me")) }
        first.handle(.received(IRCMessage(parsing: ":me!u@h JOIN #alpha")!))
        first.handle(.received(IRCMessage(parsing: ":me!u@h JOIN #beta")!))
        let swift = try XCTUnwrap(first.buffer(named: "#alpha")), macos = try XCTUnwrap(first.buffer(named: "#beta"))
        model.selectedSessionID = first.id
        first.selectedBufferID = macos.id
        first.selectedBufferID = swift.id
        second.handle(.received(IRCMessage(parsing: ":carol!c@h PRIVMSG me :are you there?")!))

        model.unseenOrBack()
        XCTAssertEqual(model.selectedSessionID, second.id, "the unseen private chat, on the other network")
        XCTAssertEqual(second.selectedBuffer?.name, "carol")
        model.unseenOrBack()
        XCTAssertEqual(model.selectedSessionID, first.id, "none waiting: back where it came from")
        XCTAssertEqual(first.selectedBuffer?.name, "#alpha")
        model.unseenOrBack()
        XCTAssertEqual(second.selectedBuffer?.name, "carol", "and forth")
        XCTAssertEqual(model.selectedSessionID, second.id)

        // Moved elsewhere by hand: back within the network, as before.
        model.selectedSessionID = first.id
        model.unseenOrBack()
        XCTAssertEqual(model.selectedSessionID, first.id)
        XCTAssertEqual(first.selectedBuffer?.name, "#beta", "the conversation before #alpha")
    }

    func testSettingsAndNetworksAreBinaryPropertyLists() throws {
        let model = makeModel()
        model.open(model.networks[0].id, connect: false)
        for name in ["settings.plist", "networks.plist"] {
            let data = try Data(contentsOf: directory.appending(path: name))
            var format = PropertyListSerialization.PropertyListFormat.xml
            _ = try PropertyListSerialization.propertyList(from: data, format: &format)
            XCTAssertEqual(format, .binary, name)
        }
    }

    func testEarlierSettingsAndNetworkListAreTakenOver() throws {
        let legacy = try XCTUnwrap(UserDefaults(suiteName: "IrctellTests.legacy"))
        defer { legacy.removePersistentDomain(forName: "IrctellTests.legacy") }
        legacy.set("oldnick", forKey: Identity.nickKey)
        let settings = SettingsStore(fileURL: directory.appending(path: "settings.plist"), migratingFrom: legacy)
        XCTAssertEqual(settings.string(forKey: Identity.nickKey), "oldnick")
        legacy.set("changed", forKey: Identity.nickKey)
        XCTAssertEqual(SettingsStore(fileURL: settings.fileURL, migratingFrom: legacy).string(forKey: Identity.nickKey),
                       "oldnick", "taken over once; the file rules after that")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appending(path: "networks.json")
        try JSONEncoder().encode([NetworkConfig(name: "Old", host: "old.example")]).write(to: json)
        let store = NetworkStore(fileURL: directory.appending(path: "networks.plist"), usesKeychain: false,
                                 legacyFiles: [json])
        XCTAssertEqual(store.load().map(\.host), ["old.example"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testOlderNetworkFilesConnectAtLaunch() throws {
        let json = #"[{"id":"6A1F1E0C-3D2B-4C5A-9E8F-111111111111","name":"N","host":"h","nick":""}]"#
        let decoded = try JSONDecoder().decode([NetworkConfig].self, from: Data(json.utf8))
        XCTAssertTrue(decoded[0].connectAtLaunch)
    }

    func testIdentityDefaultsFillEmptyFields() {
        let identity = Identity(nick: "peter", alternateNicks: ["peter_"], username: "pv", realName: "Peter")
        var network = NetworkConfig(name: "N", host: "h")
        var config = network.serverConfig(defaults: identity)
        XCTAssertEqual(config.nick, "peter")
        XCTAssertEqual(config.alternateNicks, ["peter_"])
        XCTAssertEqual(config.username, "pv")
        XCTAssertEqual(config.realName, "Peter")

        network.nick = "other"
        network.saslPassword = "secret"
        config = network.serverConfig(defaults: identity)
        XCTAssertEqual(config.nick, "other")
        XCTAssertEqual(config.alternateNicks, [], "a network's own nick does not get the default alternates")
        XCTAssertEqual(config.sasl?.account, "other")
    }
}

@MainActor
final class TranscriptTests: XCTestCase {

    private func line(_ text: String) -> ChatLine {
        ChatLine(time: .now, kind: .info, text: text)
    }

    /// The text of each line, without its timestamp.
    private func shownLines(_ textView: NSTextView) -> [String] {
        textView.string.split(separator: "\n").map { String($0.split(separator: "  ", maxSplits: 1).last ?? "") }
    }

    func testAppendsDropsAndRebuilds() {
        let scrollView = TranscriptView.makeScrollView()
        let textView = scrollView.documentView as! NSTextView
        let coordinator = TranscriptView.Coordinator()
        coordinator.textView = textView
        coordinator.scrollView = scrollView

        var lines = [line("a"), line("b"), line("c")]
        coordinator.show(lines)
        XCTAssertEqual(shownLines(textView), ["a", "b", "c"])

        lines += [line("d")]
        coordinator.show(lines)
        XCTAssertEqual(shownLines(textView), ["a", "b", "c", "d"])

        // The buffer reached its limit: the oldest lines went, a new one came.
        lines = Array(lines.dropFirst(2)) + [line("e")]
        coordinator.show(lines)
        XCTAssertEqual(shownLines(textView), ["c", "d", "e"])

        coordinator.show([])
        XCTAssertEqual(textView.string, "")

        coordinator.show([line("x")])
        XCTAssertEqual(shownLines(textView), ["x"])
    }

    func testOlderLinesGoInFront() {
        let scrollView = TranscriptView.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let textView = scrollView.documentView as! NSTextView
        let coordinator = TranscriptView.Coordinator()
        coordinator.textView = textView
        coordinator.scrollView = scrollView

        let recent = (10..<20).map { line("m\($0)") }
        coordinator.show(recent)
        let older = (0..<10).map { line("m\($0)") }
        coordinator.show(older + recent + [line("new")])
        XCTAssertEqual(shownLines(textView), (0..<20).map { "m\($0)" } + ["new"])
    }

    func testSelectedMembersAreHighlighted() {
        let message = ChatLine(time: .now, kind: .message, sender: "Alice", text: "hi")
        XCTAssertNotNil(TranscriptView.background(for: message, highlighted: ["alice"]))
        XCTAssertNil(TranscriptView.background(for: message, highlighted: ["bob"]))
        let join = ChatLine(time: .now, kind: .join, sender: "Alice", text: "Alice joined")
        XCTAssertNil(TranscriptView.background(for: join, highlighted: ["alice"]), "messages only")
    }

    func testOlderLinesShowTheirDate() throws {
        let now = Date.now
        XCTAssertEqual(TranscriptView.timestamp(now, now: now), now.formatted(date: .omitted, time: .shortened))
        var parts = DateComponents()
        parts.year = 2014; parts.month = 3; parts.day = 31; parts.hour = 20; parts.minute = 5
        let old = try XCTUnwrap(Calendar.current.date(from: parts))
        XCTAssertEqual(TranscriptView.timestamp(old, now: now), "14-03-31 20:05")
        let line = ChatLine(time: old, kind: .message, sender: "bob", text: "hi")
        XCTAssertTrue(TranscriptView.render(line).string.hasPrefix("14-03-31 20:05  <bob> hi"))
    }

    func testNetworkNameIsShownOnlyWhenAsked() {
        var line = ChatLine(time: .now, kind: .message, sender: "bob", text: "hi")
        line.network = "OFTC"
        XCTAssertFalse(TranscriptView.render(line).string.contains("[OFTC]"))
        XCTAssertTrue(TranscriptView.render(line, showsNetwork: true).string.contains("[OFTC] <bob> hi"))
    }

    func testCopyingWithoutTimesOrNicks() {
        let lines = [ChatLine(time: .now, kind: .message, sender: "bob", text: "hello \u{02}there\u{02}"),
                     ChatLine(time: .now, kind: .action, sender: "amy", text: "waves"),
                     ChatLine(time: .now, kind: .join, sender: "cid", text: "cid joined"),
                     ChatLine(time: .now, kind: .message, sender: "bob", text: "last words here")]
        let view = TranscriptTextView()
        var ranges: [NSRange] = []
        for line in lines {
            let text = TranscriptView.render(line)
            text.append(NSAttributedString(string: "\n"))
            ranges.append(NSRange(location: view.textStorage!.length, length: text.length))
            view.textStorage?.append(text)
        }
        view.lineRangesIn = { selection in ranges.filter { $0.intersection(selection)?.length ?? 0 > 0 } }
        // From the start to the middle of the last line's text.
        let last = view.textStorage!.string as NSString
        let cut = last.range(of: "last words").location + 4
        view.setSelectedRange(NSRange(location: 0, length: cut))
        XCTAssertEqual(view.selectedText(keeping: [.nick, .text]),
                       "<bob> hello there\n• amy waves\n→ cid joined\n<bob> last")
        XCTAssertEqual(view.selectedText(keeping: [.text]), "hello there\nwaves\ncid joined\nlast")

        // A few words from the middle of a line: those words.
        let words = last.range(of: "there")
        view.setSelectedRange(words)
        XCTAssertEqual(view.selectedText(keeping: [.nick, .text]), "there")
    }

    func testAFewLinesSitAtTheBottom() throws {
        let scrollView = TranscriptView.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        let coordinator = TranscriptView.Coordinator()
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        coordinator.show([line("only one")])
        XCTAssertGreaterThanOrEqual(textView.frame.height, 300)
        XCTAssertGreaterThan(textView.textContainerOrigin.y, 200, "down at the bottom, not at the top")
    }

    func testAFocusedLineIsSelectedInTheMiddle() throws {
        let scrollView = TranscriptView.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        let coordinator = TranscriptView.Coordinator()
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        var reported: TranscriptSelection?
        coordinator.selectionChanged = { reported = $0 }
        var position: Int64?? = .none
        coordinator.positionChanged = { position = .some($0) }
        NotificationCenter.default.addObserver(coordinator, selector: #selector(TranscriptView.Coordinator.selectionDidChange),
                                               name: NSTextView.didChangeSelectionNotification, object: textView)
        let lines = (1...200).map { index in
            var line = line("message number \(index)")
            line.logID = Int64(index)
            return line
        }
        let text = TranscriptView.render(lines[99]).string as NSString
        let word = text.range(of: "number")
        coordinator.pendingFocus = TranscriptFocus(logID: 100, selection: TranscriptSelection(
            logID: 100, location: word.location, length: word.length))
        coordinator.show(lines)
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        XCTAssertEqual(selected, "number")
        XCTAssertTrue(TranscriptView.render(lines[99]).string.contains("message number 100"))
        let glyphs = textView.layoutManager!.glyphRange(forCharacterRange: textView.selectedRange(), actualCharacterRange: nil)
        let rect = textView.layoutManager!.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
        let visible = scrollView.contentView.bounds
        XCTAssertEqual(rect.midY + textView.textContainerOrigin.y, visible.midY, accuracy: 20, "in the middle")

        // The user selecting in one line is reported as that line; across
        // two, not at all.
        let start = (textView.string as NSString).range(of: "message number 7\n").location
        textView.setSelectedRange(NSRange(location: start + 8, length: 6))
        XCTAssertEqual(reported?.logID, 7)
        textView.setSelectedRange(NSRange(location: start, length: 60))
        XCTAssertNil(reported)

        // Scrolled: the line in the middle is told; at the end, none.
        coordinator.scrolled()
        XCTAssertEqual(position, .some(100), "the line brought to the middle")
        textView.scrollToEndOfDocument(nil)
        coordinator.scrolled()
        XCTAssertEqual(position, .some(nil))
    }

    func testRenderingKeepsTextAndLinks() {
        let rendered = TranscriptView.render(ChatLine(time: .now, kind: .message, sender: "alice",
                                                      text: "\u{02}see\u{02} https://example.org"))
        XCTAssertTrue(rendered.string.hasSuffix("<alice> see https://example.org"))
        var foundLink: URL?
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { foundLink = url }
        }
        XCTAssertEqual(foundLink, URL(string: "https://example.org"))
    }
}

@MainActor
final class InputFocusTests: XCTestCase {

    /// Typing into the transcript lands in the input field. The window is
    /// borderless and off screen, ordered in without activating the app, so
    /// nothing takes the user's focus.
    func testTypingInTheTranscriptGoesToTheInput() async throws {
        let session = NetworkSession(config: NetworkConfig(name: "T", host: "h", nick: "me"))
        let window = KeyableWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConversationView(session: session, buffer: session.serverBuffer))
        defer { window.close() }
        window.orderFrontRegardless()
        // Key within Irctell only: the app is not activated, so the user's
        // front app keeps the keyboard.
        window.makeKey()
        window.layoutIfNeeded()

        let transcript = try XCTUnwrap(findView(TranscriptTextView.self, in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(transcript))

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: "h", charactersIgnoringModifiers: "h",
                                                   isARepeat: false, keyCode: 4))
        transcript.keyDown(with: event)
        try await waitUntil { (window.firstResponder as? NSTextView)?.string == "h" }
    }

    /// A long line typed stays inside the field, left of the palette and
    /// emoji buttons.
    func testALongLineStaysInsideTheField() async throws {
        let session = NetworkSession(config: NetworkConfig(name: "T", host: "h", nick: "me"))
        let channel = session.openBuffer(named: "#alpha", kind: .channel)
        let window = KeyableWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 300),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        session.selectedBufferID = channel.id
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(store: NetworkStore(fileURL: home.appending(path: "n.plist"), usesKeychain: false),
                             settings: SettingsStore(fileURL: home.appending(path: "s.plist")), log: nil)
        window.contentView = ProcessInfo.processInfo.environment["IRCTELL_WHOLE_VIEW"] != nil
            ? NSHostingView(rootView: AnyView(NetworkView(session: session).environment(model)))
            : NSHostingView(rootView: AnyView(ConversationView(session: session, buffer: channel)))
        defer { window.close() }
        window.orderFrontRegardless()
        window.makeKey()
        window.layoutIfNeeded()

        let transcript = try XCTUnwrap(findView(TranscriptTextView.self, in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(transcript))
        transcript.keyDown(with: try key("x", code: 7))
        try await waitUntil { (window.firstResponder as? NSTextView)?.string == "x" }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let field = try XCTUnwrap(editor.delegate as? NSTextField)
        func frames(_ label: String) {
            let fieldFrame = field.convert(field.bounds, to: nil)
            let clip = editor.enclosingScrollView ?? editor.superview
            let visible = clip.map { $0.convert($0.bounds, to: nil) } ?? .zero
            print("FIELD \(label): field \(fieldFrame) editor-visible \(visible) window \(window.frame.width)")
        }
        frames("short")
        for _ in 0..<12 { editor.insertText("a rather long message typed in ", replacementRange: editor.selectedRange()) }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        frames("long")
        if let out = ProcessInfo.processInfo.environment["IRCTELL_SNAPSHOT"], let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: out))
        }
        let fieldFrame = field.convert(field.bounds, to: nil)
        let visible = (editor.enclosingScrollView ?? editor.superview).map { $0.convert($0.bounds, to: nil) } ?? .zero
        XCTAssertLessThanOrEqual(fieldFrame.maxX, window.frame.width - 50, "room left for the two buttons")
        XCTAssertLessThanOrEqual(visible.maxX, fieldFrame.maxX + 3, "the text drawn within the field")
    }

    /// ↑ brings back what was sent before, plain arrows having the
    /// function-key flag.
    func testUpArrowBringsBackTheLastLine() async throws {
        let session = NetworkSession(config: NetworkConfig(name: "T", host: "h", nick: "me"))
        session.submit("/help", in: session.serverBuffer)
        let window = KeyableWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConversationView(session: session, buffer: session.serverBuffer))
        defer { window.close() }
        window.orderFrontRegardless()
        window.makeKey()
        window.layoutIfNeeded()

        let transcript = try XCTUnwrap(findView(TranscriptTextView.self, in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(transcript))
        transcript.keyDown(with: try key("x", code: 7))
        try await waitUntil { (window.firstResponder as? NSTextView)?.string == "x" }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        // The test app's own windows out of the way: one of them being the key
        // window, the arrow went there.
        for other in NSApplication.shared.windows where other !== window { other.orderOut(nil) }
        window.makeKey()
        window.sendEvent(try key(up, code: 126, modifiers: [.function, .numericPad]))
        try await waitUntil { editor.string == "/help" }
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// SwiftUI moves focus only in a key window; a borderless one is not
    /// allowed to be key by default.
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private func findView<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findView(type, in: subview) { return match }
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
final class LogStoreTests: XCTestCase {
    private var directory: URL!
    private var store: LogStore!
    private let libera = UUID(), oftc = UUID()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        store = try LogStore(fileURL: directory.appending(path: "logs.sqlite"))
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func log(_ text: String, network: UUID, buffer: String, kind: ChatBuffer.Kind = .channel, sender: String = "x",
                     time: Date = .now) {
        store.append(ChatLine(time: time, kind: .message, sender: sender, text: text), networkID: network,
                     networkName: network == libera ? "Libera" : "OFTC", bufferName: buffer, bufferKind: kind)
    }

    func testGoingBackToADateAndScrollingDownToNow() throws {
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let hour: TimeInterval = 3600
        let count = 2 * TranscriptFeed.pageSize + 10
        for index in 0..<count {
            log("line \(index)", network: libera, buffer: "#alpha", time: start + Double(index) * hour)
        }
        let scope = LogStore.Scope.buffer(network: libera, key: "#alpha")
        XCTAssertEqual(store.timeSpan(of: scope), start...(start + Double(count - 1) * hour))

        let feed = TranscriptFeed(store: store, scope: scope, since: start + 100.5 * hour)
        XCTAssertEqual(feed.lines.first?.text, "line 101", "the first line from that time on")
        XCTAssertEqual(feed.lines.count, TranscriptFeed.pageSize)
        XCTAssertTrue(feed.hasOlder)
        XCTAssertTrue(feed.hasNewer)

        log("live", network: libera, buffer: "#alpha")
        XCTAssertNotEqual(feed.lines.last?.text, "live", "new lines wait in the log while in the past")
        while feed.hasNewer { feed.loadNewer() }
        XCTAssertEqual(feed.lines.last?.text, "live", "scrolled down to now")
        XCTAssertEqual(feed.lines.count, count - 101 + 1)
        log("later", network: libera, buffer: "#alpha")
        XCTAssertEqual(feed.lines.last?.text, "later", "and from now on they come in as written")

        // Back from a search to a line found: the lines around it.
        let found = try XCTUnwrap(store.lines(in: scope, matching: "line 400", limit: 1).first?.logID)
        let around = TranscriptFeed(store: store, scope: scope, around: found)
        let middle = try XCTUnwrap(around.lines.firstIndex { $0.logID == found })
        XCTAssertEqual(middle, TranscriptFeed.pageSize / 2 - 1, "half a page before it, itself the last of them")
        XCTAssertEqual(around.lines.count, TranscriptFeed.pageSize)
        XCTAssertTrue(around.hasOlder)
        XCTAssertTrue(around.hasNewer)

        let future = TranscriptFeed(store: store, scope: scope, since: .now + 3600)
        XCTAssertEqual(future.lines.last?.text, "later", "nothing after the date: the newest there is")
        XCTAssertFalse(future.hasNewer)
    }

    func testHistoryIsReadBackAPageAtATime() {
        for index in 0..<(TranscriptFeed.pageSize + 5) { log("line \(index)", network: libera, buffer: "#alpha") }
        log("elsewhere", network: libera, buffer: "#other")
        log("other network", network: oftc, buffer: "#alpha")

        let feed = TranscriptFeed(store: store, scope: .buffer(network: libera, key: "#alpha"))
        XCTAssertEqual(feed.lines.count, TranscriptFeed.pageSize)
        XCTAssertEqual(feed.lines.last?.text, "line \(TranscriptFeed.pageSize + 4)")
        XCTAssertTrue(feed.hasOlder)
        feed.loadOlder()
        XCTAssertEqual(feed.lines.first?.text, "line 0", "back to the start of the log")
        XCTAssertFalse(feed.hasOlder)

        log("live", network: libera, buffer: "#ALPHA")
        log("not here", network: oftc, buffer: "#alpha")
        XCTAssertEqual(feed.lines.last?.text, "live", "new lines come in as they are written")
    }

    func testSearchIsFullText() {
        log("Swift concurrency is great", network: libera, buffer: "#alpha")
        log("Kotlin coroutines", network: libera, buffer: "#alpha")
        log("talking about CONCURRENT things", network: libera, buffer: "#alpha")
        let feed = TranscriptFeed(store: store, scope: .buffer(network: libera, key: "#alpha"), search: "concurr")
        XCTAssertEqual(feed.lines.map(\.text), ["Swift concurrency is great", "talking about CONCURRENT things"])

        log("more concurrency", network: libera, buffer: "#alpha")
        log("unrelated", network: libera, buffer: "#alpha")
        XCTAssertEqual(feed.lines.last?.text, "more concurrency", "live lines are filtered too")
        XCTAssertEqual(feed.lines.count, 3)

        XCTAssertEqual(TranscriptFeed(store: store, scope: .buffer(network: libera, key: "#alpha"),
                                      search: "\"AND (").lines.count, 0,
                       "FTS syntax in the search box is taken as words")
    }

    func testAggregatedPrivateChatsSpanNetworks() {
        log("hi on libera", network: libera, buffer: "Bob", kind: .query, sender: "Bob")
        log("hi on oftc", network: oftc, buffer: "bob", kind: .query, sender: "bob")
        log("in a channel", network: oftc, buffer: "#kilo", sender: "bob")
        let feed = TranscriptFeed(store: store, scope: .nick("BOB"))
        XCTAssertEqual(feed.lines.map(\.text), ["hi on libera", "hi on oftc"])
        XCTAssertEqual(feed.lines.map(\.network), ["Libera", "OFTC"])
    }

    func testNicksForCompletion() {
        log("hi", network: libera, buffer: "#a", sender: "Alice")
        log("hi", network: oftc, buffer: "#a", sender: "alicia")
        log("hi", network: libera, buffer: "#a", sender: "bob")
        log("hi", network: libera, buffer: "#a", sender: "ALICE")
        XCTAssertEqual(store.nicks(startingWith: "ali", limit: 5), ["Alice", "alicia"], "once each, the latest first")
        XCTAssertEqual(store.nicks(startingWith: "%", limit: 5), [], "LIKE's wildcards are taken as text")
        XCTAssertEqual(store.nicks(containing: "lic", limit: 5).count, 2)
    }

    func testOnePersonsNicksShowTogether() throws {
        log("from bob", network: libera, buffer: "bob", kind: .query, sender: "bob")
        log("from bob_away", network: libera, buffer: "bob_away", kind: .query, sender: "bob_away")
        log("bob on oftc", network: oftc, buffer: "bob", kind: .query, sender: "bob")
        log("someone else", network: libera, buffer: "carol", kind: .query, sender: "carol")
        let feed = TranscriptFeed(store: store, scope: .query(network: libera, nicks: ["bob", "bob_away"]))
        XCTAssertEqual(feed.lines.map(\.text), ["from bob", "from bob_away"], "this network, both nicks")
        log("later, away", network: libera, buffer: "bob_away", kind: .query, sender: "bob_away")
        XCTAssertEqual(feed.lines.last?.text, "later, away")
        XCTAssertEqual(TranscriptFeed(store: store, scope: .nicks(["bob", "bob_away"])).lines.count, 4)
    }

    func testClearHidesHistory() {
        log("old", network: libera, buffer: "#a")
        let floor = store.lastInsertedID
        log("new", network: libera, buffer: "#a")
        XCTAssertEqual(TranscriptFeed(store: store, scope: .buffer(network: libera, key: "#a"), floor: floor)
            .lines.map(\.text), ["new"])
    }

    func testSessionsWriteTheirLines() throws {
        let session = NetworkSession(config: NetworkConfig(name: "Libera", host: "h", nick: "me"), log: store)
        session.handle(.registered(nick: "me"))
        session.handle(.received(IRCMessage(parsing: ":bob!b@h PRIVMSG me :remember me")!))
        let feed = TranscriptFeed(store: store, scope: .nick("bob"))
        XCTAssertEqual(feed.lines.map(\.text), ["remember me"])
        XCTAssertNotNil(session.buffer(named: "bob")?.lines.last?.logID)
    }
}
