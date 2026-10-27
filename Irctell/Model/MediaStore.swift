import AppKit
import Network
import os
import Foundation

/// How a conversation treats pictures linked in it.
enum MediaMode: String, CaseIterable, Sendable {
    case show
    /// Downloaded, shown only when opened: for what may not be safe to see.
    case collapsed
    /// Not downloaded.
    case off

    var title: String {
        switch self {
        case .show: "Show"
        case .collapsed: "Show Collapsed"
        case .off: "Don't Download"
        }
    }
}

enum MediaSettings {
    static let enabled = "media.enabled"
    static let startCollapsed = "media.startCollapsed"
    static let maxMegabytes = "media.maxMegabytes"
    /// Per conversation, by network and buffer key.
    static let modes = "media.modes"
    static let defaultMaxMegabytes = 10
    /// How fast a conversation's history is downloaded, in KB a second.
    static let historySpeed = "media.historyKilobytesPerSecond"
    static let defaultHistorySpeed = 200
}

/// A picture under a message.
struct MediaItem {
    var url: String
    var image: NSImage
    var width: Int
    var height: Int
    var collapsed: Bool
    /// As the user resized it; nil to fit the window.
    var displayWidth: Double?
}

/// Downloads the pictures linked in messages, keeps them in the log
/// database, and tells the transcripts when one is ready or opened or
/// closed.
@MainActor
final class MediaStore {
    /// Posted with the line's log row as `line` in the user info.
    static let changed = Notification.Name("IrctellMediaChanged")

    /// Gets the bytes of a picture, at most `limit` of them, with its type;
    /// through the proxy when there is one.
    typealias Fetch = @Sendable (URL, Int, SOCKSProxy?) async throws -> (Data, String?)
    /// Gets a web page, at most `limit` bytes of it, with the address it
    /// ended up at; throws `notPicture` for what is not HTML.
    typealias FetchPage = @Sendable (URL, Int, SOCKSProxy?) async throws -> (Data, URL)

    /// At most this many pictures per message.
    static let picturesPerLine = 4

    private let log: LogStore
    private let fetch: Fetch
    private let fetchPage: FetchPage
    /// The mode of a conversation: network, buffer key, kind.
    var mode: (UUID, String, ChatBuffer.Kind) -> MediaMode = { _, _, _ in .show }
    var maxBytes: () -> Int = { MediaSettings.defaultMaxMegabytes << 20 }
    /// The proxy a network goes through, which its pictures go through too.
    var proxy: (UUID) -> SOCKSProxy? = { _ in nil }
    /// The lines waiting for each download, and whether each starts closed.
    private var waiting: [String: [(line: Int64, collapsed: Bool)]] = [:]
    private let images = NSCache<NSString, NSImage>()

    /// The history's downloads: bytes a second, and the least time between two.
    var historyBytesPerSecond: () -> Int = { MediaSettings.defaultHistorySpeed << 10 }
    var historyGap: Duration = .seconds(1)
    /// How the history's download waits; tests count the waits instead.
    var pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The history downloads going on, by conversation.
    private var histories: [LogStore.Scope: HistoryProgress] = [:]

    init(log: LogStore, fetch: @escaping Fetch = MediaStore.download,
         fetchPage: @escaping FetchPage = MediaStore.downloadPage) {
        self.log = log
        self.fetch = fetch
        self.fetchPage = fetchPage
    }

    /// Looks for picture links in a line just written to the log.
    func process(_ line: ChatLine, networkID: UUID, bufferName: String, kind: ChatBuffer.Kind) {
        guard line.isActivity, !line.isIgnored, let id = line.logID else { return }
        let mode = mode(networkID, LogStore.key(for: bufferName, kind: kind), kind)
        guard mode != .off else { return }
        for url in IRCFormatting.webLinks(in: line.text).prefix(MediaStore.picturesPerLine) {
            let key = url.absoluteString
            let collapsed = mode == .collapsed
            if let record = log.media(key) {
                guard record.isPicture else { continue }
                log.linkMedia(line: id, url: key, collapsed: collapsed)
                post(id)
            } else if waiting[key] != nil {
                waiting[key]?.append((id, collapsed))
            } else {
                waiting[key] = [(id, collapsed)]
                Task { await download(url) }
            }
        }
    }

    private func download(_ url: URL) async {
        let key = url.absoluteString
        var record: LogStore.MediaRecord?
        do {
            // Only for networks without a proxy: theirs are not fetched by
            // themselves.
            let (data, mime) = try await fetch(url, maxBytes(), nil)
            if let image = NSImage(data: data), image.isValid {
                let pixels = image.representations.first
                record = LogStore.MediaRecord(url: key, mime: mime,
                                              width: pixels?.pixelsWide ?? Int(image.size.width),
                                              height: pixels?.pixelsHigh ?? Int(image.size.height), data: data)
                images.setObject(image, forKey: key as NSString)
            } else {
                record = LogStore.MediaRecord(url: key, mime: mime, width: 0, height: 0, data: nil)
            }
        } catch MediaError.notPicture, MediaError.tooLarge {
            // Remembered, so the link is not fetched again.
            record = LogStore.MediaRecord(url: key, mime: nil, width: 0, height: 0, data: nil)
        } catch {
            // Could not get there now: tried again when it is linked again.
        }
        if let record { log.saveMedia(record) }
        for entry in waiting.removeValue(forKey: key) ?? [] where record?.isPicture == true {
            log.linkMedia(line: entry.line, url: key, collapsed: entry.collapsed)
            post(entry.line)
        }
    }

    /// The pictures under a line, as they are now.
    func items(for line: ChatLine) -> [MediaItem] {
        guard let id = line.logID, line.text.contains("http") else { return [] }
        return log.lineMedia(id).compactMap { entry in
            guard let image = image(for: entry.url) else { return nil }
            let pixels = image.representations.first
            return MediaItem(url: entry.url, image: image, width: pixels?.pixelsWide ?? Int(image.size.width),
                             height: pixels?.pixelsHigh ?? Int(image.size.height), collapsed: entry.collapsed,
                             displayWidth: entry.width)
        }
    }

    func setWidth(_ width: Double, line id: Int64, url: String) {
        log.setMediaWidth(line: id, url: url, width: width)
        post(id)
    }

    /// Whether the picture is in the log, and whether under this line.
    func state(of url: String, line id: Int64?) -> (stored: Bool, shownHere: Bool) {
        let stored = log.media(url)?.isPicture == true
        let here = id.map { log.lineMedia($0).contains { $0.url == url } } ?? false
        return (stored, here)
    }

    /// Asked for from a link's menu: downloads it whatever the settings, and
    /// also when it failed or was no picture before -- the site may have been
    /// down, or the line came from an imported log. A link to a web page gets
    /// the picture the page is about. Returns why it failed.
    func download(_ url: URL, forLine id: Int64) async -> String? {
        let key = url.absoluteString
        if log.media(key)?.isPicture == true {
            log.linkMedia(line: id, url: key, collapsed: false)
            post(id)
            return nil
        }
        let proxy = log.networkID(ofLine: id).flatMap(proxy)
        let outcome = await picture(at: url, proxy: proxy, lookInPages: true).outcome
        keep(outcome, for: url)
        switch outcome {
        case .picture:
            log.linkMedia(line: id, url: key, collapsed: false)
            post(id)
            return nil
        case .notPicture: return "It is not a picture."
        case .noPictureOnPage: return "No picture was found on that page."
        case .tooLarge: return "It is larger than the limit in Settings › Pictures."
        case .failed(let problem): return problem
        }
    }

    /// What getting a link came to.
    enum Outcome {
        case picture(LogStore.MediaRecord)
        case notPicture, noPictureOnPage, tooLarge
        case failed(String)
    }

    /// The picture a link is, or -- `lookInPages` -- the one on the page it
    /// is; and the bytes read for it, for keeping to a bandwidth.
    private func picture(at url: URL, proxy: SOCKSProxy?, lookInPages: Bool) async -> (outcome: Outcome, bytes: Int) {
        do {
            let (data, mime) = try await fetch(url, maxBytes(), proxy)
            guard let record = record(url.absoluteString, data, mime) else { return (.notPicture, data.count) }
            return (.picture(record), data.count)
        } catch MediaError.notPicture {
            guard lookInPages else { return (.notPicture, 0) }
            return await pictureOnPage(url, proxy: proxy)
        } catch MediaError.tooLarge {
            return (.tooLarge, 0)
        } catch {
            return (.failed(error.localizedDescription), 0)
        }
    }

    /// Reads the page and tries its likeliest pictures, a few at most: the
    /// first large enough is taken, else the first that is a picture at all.
    private func pictureOnPage(_ url: URL, proxy: SOCKSProxy?) async -> (outcome: Outcome, bytes: Int) {
        guard let (html, address) = try? await fetchPage(url, PagePicture.pageLimit, proxy) else {
            return (.notPicture, 0)
        }
        var bytes = html.count
        var small: LogStore.MediaRecord?
        for candidate in PagePicture.candidates(in: String(decoding: html, as: UTF8.self), base: address).prefix(3) {
            guard let (data, mime) = try? await fetch(candidate.url, maxBytes(), proxy) else { continue }
            bytes += data.count
            // Kept under the page's address: that is what the line links to.
            guard let record = record(url.absoluteString, data, mime) else { continue }
            if min(record.width, record.height) >= PagePicture.minimumSide { return (.picture(record), bytes) }
            if small == nil { small = record }
        }
        return (small.map { .picture($0) } ?? .noPictureOnPage, bytes)
    }

    private func record(_ key: String, _ data: Data, _ mime: String?) -> LogStore.MediaRecord? {
        guard let image = NSImage(data: data), image.isValid else { return nil }
        let pixels = image.representations.first
        images.setObject(image, forKey: key as NSString)
        return LogStore.MediaRecord(url: key, mime: mime, width: pixels?.pixelsWide ?? Int(image.size.width),
                                    height: pixels?.pixelsHigh ?? Int(image.size.height), data: data)
    }

    /// Writes down what a link came to, so it is not fetched again for
    /// nothing; a failure is not, as the site may be back later.
    private func keep(_ outcome: Outcome, for url: URL) {
        let key = url.absoluteString
        switch outcome {
        case .picture(let record): log.saveMedia(record)
        case .notPicture, .tooLarge: log.saveMedia(LogStore.MediaRecord(url: key, mime: nil, width: 0, height: 0, data: nil))
        case .noPictureOnPage:
            log.saveMedia(LogStore.MediaRecord(url: key, mime: PagePicture.noPictureMarker, width: 0, height: 0, data: nil))
        case .failed: break
        }
    }

    // MARK: - A conversation's history

    /// How a history's download is going.
    struct HistoryProgress: Equatable, Sendable {
        /// Links looked at, of those found so far.
        var checked = 0
        var links = 0
        /// Pictures new to the log, and ones it had that are now shown.
        var downloaded = 0
        var alreadyThere = 0
        var notPictures = 0
        var failed = 0
        var bytes = 0
        var finished = false
        var stopped = false
    }

    private var historyTasks: [LogStore.Scope: Task<Void, Never>] = [:]

    func historyProgress(_ scope: LogStore.Scope) -> HistoryProgress? { histories[scope] }

    /// Downloads the pictures linked in a conversation's whole history, in
    /// the background: one link at a time, and slowly enough to stay within
    /// the bandwidth set, with a pause between two however small. `pages`:
    /// links to web pages get the picture the page is about. `report` is
    /// told after each link, and once at the end.
    func downloadHistory(_ scope: LogStore.Scope, pages: Bool, collapsed: Bool,
                         report: @escaping (HistoryProgress) -> Void = { _ in }) {
        guard historyTasks[scope] == nil else { return }
        histories[scope] = HistoryProgress()
        AppLog.info("pictures", "downloading the pictures of a conversation's history\(pages ? ", web pages too" : "")")
        historyTasks[scope] = Task { [weak self] in
            await self?.runHistory(scope, pages: pages, collapsed: collapsed, report: report)
        }
    }

    func stopHistory(_ scope: LogStore.Scope) {
        historyTasks[scope]?.cancel()
    }

    private func runHistory(_ scope: LogStore.Scope, pages: Bool, collapsed: Bool,
                            report: @escaping (HistoryProgress) -> Void) async {
        var progress = HistoryProgress()
        /// Links met before in this run, and whether each was a picture.
        var seen: [String: Bool] = [:]
        var after: Int64?
        defer {
            progress.finished = true
            progress.stopped = Task.isCancelled
            histories[scope] = nil
            historyTasks[scope] = nil
            AppLog.info("pictures", "history download \(progress.stopped ? "stopped" : "done"): \(progress.downloaded) new, "
                        + "\(progress.alreadyThere) already there, \(progress.notPictures) not pictures, \(progress.failed) failed")
            report(progress)
        }
        while !Task.isCancelled {
            let batch = log.linkLines(in: scope, after: after, limit: 500)
            guard let last = batch.last else { return }
            after = last.id
            for line in batch {
                let urls = Array(IRCFormatting.webLinks(in: line.text).prefix(MediaStore.picturesPerLine))
                progress.links += urls.count
                for url in urls {
                    if Task.isCancelled { return }
                    let wait = await take(url, line: line.id, pages: pages, collapsed: collapsed,
                                          seen: &seen, progress: &progress)
                    if Task.isCancelled { return }
                    progress.checked += 1
                    histories[scope] = progress
                    report(progress)
                    if let wait, wait > .zero { await pause(wait) }
                }
            }
        }
    }

    /// One link of a history: shown, if the log has its picture; else
    /// fetched. Returns how long to wait before the next fetch, after one.
    private func take(_ url: URL, line: Int64, pages: Bool, collapsed: Bool,
                      seen: inout [String: Bool], progress: inout HistoryProgress) async -> Duration? {
        let key = url.absoluteString
        if let picture = seen[key] {
            if picture { show(key, line: line, collapsed: collapsed) }
            return nil
        }
        if let known = log.media(key) {
            if known.isPicture {
                seen[key] = true
                if show(key, line: line, collapsed: collapsed) { progress.alreadyThere += 1 }
                return nil
            }
            // Not a picture; a page is read, once, when asked to.
            if !pages || known.mime == PagePicture.noPictureMarker {
                seen[key] = false
                progress.notPictures += 1
                return nil
            }
        }
        let started = ContinuousClock.now
        let proxy = log.networkID(ofLine: line).flatMap(proxy)
        let (outcome, bytes) = await picture(at: url, proxy: proxy, lookInPages: pages)
        if Task.isCancelled { return nil }
        keep(outcome, for: url)
        progress.bytes += bytes
        switch outcome {
        case .picture:
            seen[key] = true
            progress.downloaded += 1
            show(key, line: line, collapsed: collapsed)
        case .notPicture, .noPictureOnPage, .tooLarge:
            seen[key] = false
            progress.notPictures += 1
        case .failed:
            progress.failed += 1
        }
        // As long as the bytes take at the speed set, and at least the gap.
        let rate = max(historyBytesPerSecond(), 1024)
        let budget = Duration.seconds(Double(bytes) / Double(rate))
        return max(budget, historyGap) - (ContinuousClock.now - started)
    }

    /// Shows a stored picture under a line, unless it is there; whether it
    /// was not.
    @discardableResult
    private func show(_ url: String, line id: Int64, collapsed: Bool) -> Bool {
        guard !log.lineMedia(id).contains(where: { $0.url == url }) else { return false }
        log.linkMedia(line: id, url: url, collapsed: collapsed)
        post(id)
        return true
    }

    func setCollapsed(_ collapsed: Bool, line id: Int64, url: String) {
        log.setMediaCollapsed(line: id, url: url, collapsed: collapsed)
        post(id)
    }

    private func image(for url: String) -> NSImage? {
        if let cached = images.object(forKey: url as NSString) { return cached }
        guard let data = log.media(url)?.data, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: url as NSString)
        return image
    }

    private func post(_ line: Int64) {
        NotificationCenter.default.post(name: MediaStore.changed, object: self, userInfo: ["line": line])
    }

    // MARK: - Downloading

    enum MediaError: Error {
        case notPicture, tooLarge, failed
    }

    /// No cookies or cache, and a browser's user agent: the site learns the
    /// address, not the client -- the proxy's address, through one.
    nonisolated private static func session(_ proxy: SOCKSProxy?) -> URLSession {
        guard let proxy else { return direct }
        return sessions.withLock { sessions in
            if let session = sessions[proxy] { return session }
            let session = makeSession(proxy: proxy)
            sessions[proxy] = session
            return session
        }
    }

    nonisolated private static let direct = makeSession(proxy: nil)
    nonisolated private static let sessions = OSAllocatedUnfairLock<[SOCKSProxy: URLSession]>(initialState: [:])

    nonisolated private static func makeSession(proxy: SOCKSProxy?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        if let proxy, let port = NWEndpoint.Port(rawValue: proxy.port) {
            var socks = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host), port: port))
            if let username = proxy.username { socks.applyCredential(username: username, password: proxy.password ?? "") }
            // Never around the proxy.
            socks.allowFailover = false
            configuration.proxyConfigurations = [socks]
        }
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
        ]
        return URLSession(configuration: configuration)
    }

    /// The picture at the URL: refused unless the server says it is an image
    /// (not SVG, which is a document), and given up past `limit` bytes.
    nonisolated static func download(_ url: URL, limit: Int, proxy: SOCKSProxy?) async throws -> (Data, String?) {
        let (bytes, response) = try await open(url, accept: "image/*", proxy: proxy)
        let mime = response.mimeType?.lowercased()
        guard let mime, mime.hasPrefix("image/"), !mime.contains("svg") else { throw MediaError.notPicture }
        if response.expectedContentLength > limit { throw MediaError.tooLarge }
        return (try await read(bytes, limit: limit, expected: response.expectedContentLength, cut: false), mime)
    }

    /// A web page: refused unless it is HTML; only its first `limit` bytes,
    /// where what names its picture is.
    nonisolated static func downloadPage(_ url: URL, limit: Int, proxy: SOCKSProxy?) async throws -> (Data, URL) {
        let (bytes, response) = try await open(url, accept: "text/html,application/xhtml+xml", proxy: proxy)
        let mime = response.mimeType?.lowercased() ?? ""
        guard mime.contains("html") else { throw MediaError.notPicture }
        return (try await read(bytes, limit: limit, expected: response.expectedContentLength, cut: true),
                response.url ?? url)
    }

    nonisolated private static func open(_ url: URL, accept: String,
                                         proxy: SOCKSProxy?) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session(proxy).bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MediaError.failed
        }
        return (bytes, http)
    }

    /// The bytes, up to `limit`: past it, the rest is left (`cut`) or it is
    /// too large.
    nonisolated private static func read(_ bytes: URLSession.AsyncBytes, limit: Int, expected: Int64,
                                         cut: Bool) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(max(Int(expected), 0), limit))
        for try await byte in bytes {
            if data.count >= limit {
                if cut { break }
                throw MediaError.tooLarge
            }
            data.append(byte)
        }
        return data
    }
}
