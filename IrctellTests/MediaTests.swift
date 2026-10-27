import AppKit
import XCTest
@testable import Irctell

/// Counts the downloads, and answers them from a table.
final class FakeWeb: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<(Data, String?), Error>] = [:]
    private var pages: [String: String] = [:]
    private var counts: [String: Int] = [:]
    private var proxies: [String: SOCKSProxy] = [:]

    func serve(_ url: String, _ answer: Result<(Data, String?), Error>) {
        lock.withLock { answers[url] = answer }
    }

    /// A web page: its link is no picture, and reading it gives the HTML.
    func servePage(_ url: String, _ html: String) {
        lock.withLock {
            answers[url] = .failure(MediaStore.MediaError.notPicture)
            pages[url] = html
        }
    }

    func fetchPage(_ url: URL, limit: Int, proxy: SOCKSProxy? = nil) async throws -> (Data, URL) {
        let html = lock.withLock { () -> String? in
            counts["page " + url.absoluteString, default: 0] += 1
            return pages[url.absoluteString]
        }
        guard let html else { throw MediaStore.MediaError.notPicture }
        return (Data(html.utf8), url)
    }

    func count(_ url: String) -> Int { lock.withLock { counts[url] ?? 0 } }
    /// The proxy the last fetch of the URL went through.
    func proxy(_ url: String) -> SOCKSProxy? { lock.withLock { proxies[url] } }

    func fetch(_ url: URL, limit: Int, proxy: SOCKSProxy? = nil) async throws -> (Data, String?) {
        let answer = lock.withLock { () -> Result<(Data, String?), Error>? in
            counts[url.absoluteString, default: 0] += 1
            proxies[url.absoluteString] = proxy
            return answers[url.absoluteString]
        }
        guard let answer else { throw MediaStore.MediaError.failed }
        return try answer.get()
    }

    static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
}

@MainActor
final class MediaTests: XCTestCase {
    private var directory: URL!
    private var log: LogStore!
    private var web: FakeWeb!
    private var media: MediaStore!
    private var mode = MediaMode.show
    private let network = UUID()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        log = try LogStore(fileURL: directory.appending(path: "logs.sqlite"))
        web = FakeWeb()
        let web = web!
        media = MediaStore(log: log, fetch: { try await web.fetch($0, limit: $1, proxy: $2) },
                           fetchPage: { try await web.fetchPage($0, limit: $1, proxy: $2) })
        media.mode = { [unowned self] _, _, _ in mode }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func say(_ text: String, sender: String = "bob", ignored: Bool = false) -> ChatLine {
        let line = log.append(ChatLine(time: .now, kind: .message, sender: sender, text: text, isIgnored: ignored),
                              networkID: network, networkName: "N", bufferName: "#a", bufferKind: .channel)
        media.process(line, networkID: network, bufferName: "#a", kind: .channel)
        return line
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    func testPicturesAreDownloadedOnceKeptAndShown() async throws {
        web.serve("https://img.example/cat.png", .success((FakeWeb.png(width: 40, height: 30), "image/png")))
        let changed = expectation(forNotification: MediaStore.changed, object: media)
        let first = say("look \u{02}https://img.example/cat.png\u{02} nice")
        await fulfillment(of: [changed], timeout: 2)

        let items = media.items(for: first)
        XCTAssertEqual(items.map(\.width), [40])
        XCTAssertEqual(items.first?.height, 30)
        XCTAssertEqual(items.first?.collapsed, false)
        XCTAssertTrue(log.media("https://img.example/cat.png")?.isPicture ?? false, "kept in the log")

        let again = say("same again https://img.example/cat.png", sender: "me")
        XCTAssertEqual(media.items(for: again).count, 1, "from the log, at once")
        XCTAssertEqual(web.count("https://img.example/cat.png"), 1, "downloaded once")

        media.setCollapsed(true, line: try XCTUnwrap(first.logID), url: "https://img.example/cat.png")
        XCTAssertEqual(media.items(for: first).first?.collapsed, true)
        XCTAssertEqual(media.items(for: again).first?.collapsed, false, "each line on its own")
    }

    func testOtherLinksAreRememberedAsNotPictures() async throws {
        web.serve("https://example.org/page", .failure(MediaStore.MediaError.notPicture))
        let line = say("read https://example.org/page")
        try await settle()
        XCTAssertTrue(media.items(for: line).isEmpty)
        _ = say("again https://example.org/page")
        try await settle()
        XCTAssertEqual(web.count("https://example.org/page"), 1, "not fetched again")

        _ = say("down https://down.example/x.jpg")
        try await settle()
        _ = say("down https://down.example/x.jpg")
        try await settle()
        XCTAssertEqual(web.count("https://down.example/x.jpg"), 2, "a failed download is tried again")
    }

    func testModesAndIgnores() async throws {
        web.serve("https://img.example/a.png", .success((FakeWeb.png(width: 10, height: 10), "image/png")))
        mode = .off
        _ = say("https://img.example/a.png")
        _ = say("https://img.example/a.png", ignored: true)
        try await settle()
        XCTAssertEqual(web.count("https://img.example/a.png"), 0)

        mode = .collapsed
        let line = say("https://img.example/a.png")
        try await settle()
        XCTAssertEqual(media.items(for: line).first?.collapsed, true, "for what may not be safe to see")
    }

    func testDownloadingOnRequestAndResizing() async throws {
        mode = .off
        let line = say("an old one https://img.example/old.png")
        let id = try XCTUnwrap(line.logID)
        XCTAssertEqual(media.state(of: "https://img.example/old.png", line: id).stored, false)

        web.serve("https://img.example/old.png", .failure(MediaStore.MediaError.notPicture))
        let refused = await media.download(URL(string: "https://img.example/old.png")!, forLine: id)
        XCTAssertEqual(refused, "It is not a picture.")

        web.serve("https://img.example/old.png", .success((FakeWeb.png(width: 60, height: 30), "image/png")))
        let problem = await media.download(URL(string: "https://img.example/old.png")!, forLine: id)
        XCTAssertNil(problem, "asked for: fetched again, whatever the mode or the earlier answer")
        XCTAssertEqual(media.state(of: "https://img.example/old.png", line: id).shownHere, true)

        media.setWidth(120, line: id, url: "https://img.example/old.png")
        let item = try XCTUnwrap(media.items(for: line).first)
        XCTAssertEqual(item.displayWidth, 120)
        let rendered = TranscriptView.render(item, line: id, width: 40)
        var attachment: NSTextAttachment?
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            attachment = attachment ?? value as? NSTextAttachment
        }
        XCTAssertEqual(attachment?.bounds.size, CGSize(width: 120, height: 60), "the dragged size, proportions kept")
    }

    func testOnATorNetworkPicturesComeOnlyWhenAskedForAndThroughTor() async throws {
        let tor = SOCKSProxy(host: "127.0.0.1", port: 9050, username: "irctell-x", password: "irctell")
        media.proxy = { [network] id in id == network ? tor : nil }
        mode = .off // what a network with a proxy gets
        web.serve("https://img.example/secret.png", .success((FakeWeb.png(width: 10, height: 10), "image/png")))
        let line = say("https://img.example/secret.png")
        try await settle()
        XCTAssertEqual(web.count("https://img.example/secret.png"), 0, "not fetched by itself")

        let problem = await media.download(URL(string: "https://img.example/secret.png")!, forLine: try XCTUnwrap(line.logID))
        XCTAssertNil(problem)
        XCTAssertEqual(web.proxy("https://img.example/secret.png"), tor, "asked for: fetched through Tor")
        XCTAssertEqual(media.items(for: line).count, 1)
    }

    func testThePictureAPageIsAboutIsFound() throws {
        let base = URL(string: "https://site.example/posts/7")!
        let shared = """
            <html><head><meta property="og:image" content="https://cdn.example/share/photo-7.jpg?w=1200&amp;h=630">
            <meta name="twitter:image" content="/twitter/7.jpg"></head><body>
            <img src="/static/logo.png" width="300" height="300"><img src="/tiny.gif" width="1" height="1">
            <img src="/a.jpg"></body></html>
            """
        let found = PagePicture.candidates(in: shared, base: base).map(\.url.absoluteString)
        XCTAssertEqual(found.first, "https://cdn.example/share/photo-7.jpg?w=1200&h=630", "the preview picture first, decoded")
        XCTAssertEqual(found.dropFirst().first, "https://site.example/twitter/7.jpg", "relative to the page")
        XCTAssertFalse(found.contains { $0.contains("logo") || $0.contains("tiny") }, "no logos, no tracking pixels")

        let gallery = """
            <meta property='og:image' content='https://site.example/brand/site-logo.png'>
            <img data-src="https://site.example/thumb.jpg" width="120" height="120">
            <img srcset="https://site.example/big-480.jpg 480w, https://site.example/big-1080.jpg 1080w" width="800" height="600">
            """
        XCTAssertEqual(PagePicture.candidates(in: gallery, base: base).first?.url.absoluteString,
                       "https://site.example/big-1080.jpg", "a large picture beats the site's logo; the widest of a srcset")
        XCTAssertTrue(PagePicture.candidates(in: "<p>no pictures</p>", base: base).isEmpty)
    }

    func testAPageLinkGetsItsPictureWhenAskedFor() async throws {
        mode = .off
        web.servePage("https://site.example/post", """
            <meta property="og:image" content="https://cdn.example/small.png">
            <img src="https://cdn.example/large.png">
            """)
        web.serve("https://cdn.example/small.png", .success((FakeWeb.png(width: 50, height: 50), "image/png")))
        web.serve("https://cdn.example/large.png", .success((FakeWeb.png(width: 400, height: 300), "image/png")))
        let line = say("look https://site.example/post")
        let id = try XCTUnwrap(line.logID)

        let problem = await media.download(URL(string: "https://site.example/post")!, forLine: id)
        XCTAssertNil(problem)
        XCTAssertEqual(media.items(for: line).map(\.width), [400], "a picture too small is passed over for a large one")
        XCTAssertTrue(log.media("https://site.example/post")?.isPicture ?? false, "kept under the link the line has")

        web.servePage("https://site.example/empty", "<p>words</p>")
        let other = say("https://site.example/empty")
        let none = await media.download(URL(string: "https://site.example/empty")!, forLine: try XCTUnwrap(other.logID))
        XCTAssertEqual(none, "No picture was found on that page.")
    }

    func testAHistorysPicturesComeInTheBackgroundWithinTheBandwidth() async throws {
        mode = .off
        let waits = Waits()
        media.pause = { await waits.add($0) }
        media.historyGap = .milliseconds(10)
        media.historyBytesPerSecond = { 1024 }
        let picture = FakeWeb.png(width: 200, height: 200)
        web.serve("https://img.example/1.png", .success((picture, "image/png")))
        web.serve("https://img.example/2.png", .success((picture, "image/png")))
        web.servePage("https://site.example/p", #"<meta property="og:image" content="https://img.example/3.png">"#)
        web.serve("https://img.example/3.png", .success((picture, "image/png")))
        let lines = [say("https://img.example/1.png and https://site.example/p"), say("plain words"),
                     say("again https://img.example/1.png"), say("https://img.example/2.png https://gone.example/x.png")]
        let scope = LogStore.Scope.buffer(network: network, key: LogStore.key(for: "#a", kind: .channel))

        var done: MediaStore.HistoryProgress?
        media.downloadHistory(scope, pages: false, collapsed: true) { if $0.finished { done = $0 } }
        XCTAssertNotNil(media.historyProgress(scope), "going on")
        try await waitFor { done != nil }
        XCTAssertNil(media.historyProgress(scope))
        XCTAssertEqual(done?.downloaded, 2)
        XCTAssertEqual(done?.notPictures, 1, "the page, not read")
        XCTAssertEqual(done?.failed, 1)
        XCTAssertEqual(web.count("https://img.example/1.png"), 1, "a link met twice is fetched once")
        XCTAssertEqual(web.count("page https://site.example/p"), 0)
        XCTAssertEqual(media.items(for: lines[2]).first?.collapsed, true, "as the conversation shows pictures")
        XCTAssertEqual(media.items(for: lines[3]).count, 1)
        let pauses = await waits.all
        let slowest = pauses.max() ?? .zero
        XCTAssertGreaterThan(slowest, .milliseconds(Int(Double(picture.count) / 1024 * 1000) - 50),
                             "a picture's bytes take their time at 1 KB a second")
        XCTAssertGreaterThanOrEqual(pauses.count, 3, "a pause after every download")

        done = nil
        media.downloadHistory(scope, pages: true, collapsed: false) { if $0.finished { done = $0 } }
        try await waitFor { done != nil }
        XCTAssertEqual(done?.downloaded, 1, "the page's picture, now")
        XCTAssertEqual(done?.alreadyThere, 0, "the others were shown already")
        XCTAssertEqual(media.items(for: lines[0]).count, 2)
        XCTAssertEqual(web.count("https://img.example/1.png"), 1, "what the log has is not fetched again")
    }

    func testAHistoryDownloadCanBeStopped() async throws {
        mode = .off
        media.pause = { _ in try? await Task.sleep(for: .seconds(30)) }
        for index in 0..<5 {
            web.serve("https://img.example/\(index).png", .success((FakeWeb.png(width: 10, height: 10), "image/png")))
            _ = say("https://img.example/\(index).png")
        }
        let scope = LogStore.Scope.buffer(network: network, key: LogStore.key(for: "#a", kind: .channel))
        var done: MediaStore.HistoryProgress?
        media.downloadHistory(scope, pages: false, collapsed: false) { if $0.finished { done = $0 } }
        try await waitFor { (self.media.historyProgress(scope)?.checked ?? 0) >= 1 }
        media.stopHistory(scope)
        try await waitFor { done != nil }
        XCTAssertEqual(done?.stopped, true)
        XCTAssertEqual(done?.downloaded, 1, "stopped in the pause after the first")
    }

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "in time")
    }

    func testRenderedCollapsedOrOpen() throws {
        let image = try XCTUnwrap(NSImage(data: FakeWeb.png(width: 800, height: 400)))
        var item = MediaItem(url: "https://img.example/big.png", image: image, width: 800, height: 400, collapsed: false)
        let open = TranscriptView.render(item, line: 1, width: 400)
        XCTAssertTrue(open.string.hasPrefix("▾ Hide picture · img.example · 800×400"))
        var attachment: NSTextAttachment?
        open.enumerateAttribute(.attachment, in: NSRange(location: 0, length: open.length)) { value, _, _ in
            attachment = attachment ?? value as? NSTextAttachment
        }
        XCTAssertEqual(attachment?.bounds.width, 400, "fitted to the width")
        XCTAssertEqual(attachment?.bounds.height, 200)

        item.collapsed = true
        let closed = TranscriptView.render(item, line: 1, width: 400)
        XCTAssertTrue(closed.string.hasPrefix("▸ Show picture"))
        XCTAssertFalse(closed.string.contains("\u{FFFC}"), "no picture while collapsed")
    }
}

/// The pauses a history download made.
private actor Waits {
    private(set) var all: [Duration] = []
    func add(_ wait: Duration) { all.append(wait) }
}
