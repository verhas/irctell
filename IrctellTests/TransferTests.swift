import XCTest
@testable import Irctell

@MainActor
final class TransferTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A Mac of its own: networks, settings and log in a folder.
    private func makeModel(_ name: String) -> AppModel {
        let home = directory.appending(path: name)
        return AppModel(store: NetworkStore(fileURL: home.appending(path: "networks.plist"), usesKeychain: false),
                        settings: SettingsStore(fileURL: home.appending(path: "settings.plist")),
                        log: try? LogStore(fileURL: home.appending(path: "logs.sqlite")))
    }

    /// Libera, in the networks every new list starts with.
    private func libera(_ model: AppModel) -> NetworkConfig {
        model.networks.first { $0.host == "irc.libera.chat" }!
    }

    private func line(_ seconds: Double, _ sender: String?, _ text: String, kind: ChatLine.Kind = .message) -> ChatLine {
        ChatLine(time: Date(timeIntervalSince1970: seconds), kind: kind, sender: sender, text: text)
    }

    private func log(_ model: AppModel, _ lines: [ChatLine], buffer: String = "#alpha",
                     kind: ChatBuffer.Kind = .channel) throws {
        let network = libera(model)
        for line in lines {
            model.log?.append(line, networkID: network.id, networkName: network.name, bufferName: buffer, bufferKind: kind)
        }
    }

    private func export(_ model: AppModel, parts: Set<ArchivePart> = Set(ArchivePart.allCases)) throws -> LogArchive.Unpacked {
        let zip = directory.appending(path: "export-\(UUID().uuidString).zip")
        _ = try LogArchive.export(model.exportInput(parts: parts), to: zip) { _ in }
        return try LogArchive.unpack(zip)
    }

    private func texts(_ model: AppModel, buffer: String = "#alpha") throws -> [String] {
        let network = libera(model)
        return model.log?.lines(in: .buffer(network: network.id, key: buffer), oldestFirst: true, limit: 100)
            .map(\.text) ?? []
    }

    func testAnExportComesBackOnAnotherMacAsItWas() async throws {
        let old = makeModel("old")
        var hello = line(1_760_000_000.123, "alice", "hi \u{02}there\u{02} \"quoted\" \\ back\nslash 🎉")
        hello.isHighlight = true
        var mine = line(1_760_000_060.5, "me", "/me waves", kind: .action)
        mine.isSelf = true
        try log(old, [hello, mine])
        try log(old, [line(1_760_000_030, "bob", "psst")], buffer: "bob", kind: .query)
        let picture = try XCTUnwrap(old.log?.append(line(1_760_000_090, "alice", "look https://x.org/a.png"),
                                                   networkID: libera(old).id, networkName: "Libera.Chat",
                                                   bufferName: "#alpha", bufferKind: .channel).logID)
        old.log?.saveMedia(.init(url: "https://x.org/a.png", mime: "image/png", width: 2, height: 1,
                                 data: Data([1, 2, 3])))
        old.log?.linkMedia(line: picture, url: "https://x.org/a.png", collapsed: true)
        old.settings.set(["needle"], forKey: "highlight.words")
        old.settings.set("Kokoro", forKey: "speech.engine")
        old.settings.set([libera(old).id.uuidString: ["#alpha": "collapsed"]], forKey: "media.modes")

        let archive = try export(old)
        defer { archive.cleanUp() }
        XCTAssertEqual(archive.available[.messages], 4)
        XCTAssertEqual(archive.available[.pictures], 1)
        XCTAssertNotNil(archive.available[.highlights])
        XCTAssertNil(archive.available[.sounds], "no sounds: not offered")
        let file = try XCTUnwrap(archive.conversations.first { $0.buffer == "#alpha" }?.file)
        XCTAssertEqual(file, "lines/Libera.Chat/#alpha.jsonl")
        let first = try String(contentsOf: XCTUnwrap(archive.file(file)), encoding: .utf8).split(separator: "\n")[0]
        XCTAssertTrue(first.hasPrefix(#"{"time":"2025-10-09T08:53:20.123Z","kind":"message","sender":"alice""#), String(first))

        let new = makeModel("new")
        XCTAssertNotEqual(libera(new).id, libera(old).id, "the same network, under another ID")
        let result = try await new.importArchive(archive, parts: Set(archive.available.keys)) { _ in }
        XCTAssertEqual(result.linesAdded, 4)
        XCTAssertEqual(result.picturesAdded, 1)
        XCTAssertTrue(result.networksAdded.isEmpty, "Libera was matched by its server")

        let lines = try XCTUnwrap(new.log?.lines(in: .buffer(network: libera(new).id, key: "#alpha"), oldestFirst: true,
                                                 limit: 10))
        XCTAssertEqual(lines.map(\.text), [hello.text, mine.text, "look https://x.org/a.png"])
        XCTAssertEqual(lines[0].time.timeIntervalSince1970, 1_760_000_000.123, accuracy: 0.0005)
        XCTAssertEqual(lines[0].sender, "alice")
        XCTAssertTrue(lines[0].isHighlight)
        XCTAssertEqual(lines[1].kind, .action)
        XCTAssertTrue(lines[1].isSelf)
        XCTAssertEqual(try texts(new, buffer: "bob"), ["psst"])
        let shown = try XCTUnwrap(new.log?.lineMedia(XCTUnwrap(lines[2].logID)))
        XCTAssertEqual(shown.map(\.url), ["https://x.org/a.png"])
        XCTAssertEqual(shown.first?.collapsed, true)
        XCTAssertEqual(new.log?.media("https://x.org/a.png")?.data, Data([1, 2, 3]))

        XCTAssertEqual(new.settings.stringArray(forKey: "highlight.words"), ["needle"])
        XCTAssertEqual(new.settings.string(forKey: "speech.engine"), "Kokoro")
        XCTAssertNotNil(new.settings.dictionary(forKey: "media.modes")?[libera(new).id.uuidString],
                        "the network's ID in a setting is the one it has here")

        let again = try await new.importArchive(archive, parts: [.messages]) { _ in }
        XCTAssertEqual(again.linesAdded, 0)
        XCTAssertEqual(again.linesAlreadyThere, 4, "importing twice changes nothing")
    }

    func testOnlyTheChosenPartsAreExportedAndImported() async throws {
        let old = makeModel("old")
        try log(old, [line(100, "a", "one")])
        old.settings.set(["needle"], forKey: "highlight.words")
        old.settings.set("Kokoro", forKey: "speech.engine")
        let archive = try export(old, parts: [.speech, .highlights])
        defer { archive.cleanUp() }
        XCTAssertEqual(Set(archive.available.keys), [.speech, .highlights])

        let new = makeModel("new")
        _ = try await new.importArchive(archive, parts: [.speech]) { _ in }
        XCTAssertEqual(new.settings.string(forKey: "speech.engine"), "Kokoro")
        XCTAssertNil(new.settings.object(forKey: "highlight.words"), "not ticked on import")
        XCTAssertEqual(try texts(new), [])
    }

    func testLinesBetweenTheOnesThereAreNumberedInTimeOrder() async throws {
        let source = makeModel("source")
        try log(source, [line(20, "a", "twenty"), line(40, "a", "forty")])
        let archive = try export(source, parts: [.messages])
        defer { archive.cleanUp() }

        let target = makeModel("target")
        try log(target, [line(10, "b", "ten"), line(30, "b", "thirty")])
        let picture = try XCTUnwrap(target.log?.append(line(50, "b", "fifty"), networkID: libera(target).id,
                                                      networkName: "Libera.Chat", bufferName: "#alpha",
                                                      bufferKind: .channel).logID)
        target.log?.linkMedia(line: picture, url: "https://x.org/b.png", collapsed: false)
        target.open(libera(target).id, select: false, connect: false)
        let session = try XCTUnwrap(target.session(for: libera(target).id))
        let buffer = session.openBuffer(named: "#alpha", kind: .channel, select: false)
        buffer.clear(upTo: picture)

        let result = try await target.importArchive(archive, parts: [.messages]) { _ in }
        XCTAssertEqual(result.linesAdded, 2)
        XCTAssertEqual(try texts(target), ["ten", "twenty", "thirty", "forty", "fifty"])
        let rows = try XCTUnwrap(target.log?.lines(in: .buffer(network: libera(target).id, key: "#alpha"),
                                                   oldestFirst: true, limit: 10))
        XCTAssertEqual(rows.compactMap(\.logID), rows.compactMap(\.logID).sorted(), "rows in time order")
        let fifty = try XCTUnwrap(rows.last?.logID)
        XCTAssertEqual(buffer.clearedUpTo, fifty, "Clear still hides up to the same line")
        XCTAssertEqual(target.log?.lineMedia(fifty).map(\.url), ["https://x.org/b.png"], "its picture went with it")

        // Search and new lines work on the table made again.
        XCTAssertEqual(target.log?.lines(in: .buffer(network: libera(target).id, key: "#alpha"), matching: "twenty",
                                         limit: 10).map(\.text), ["twenty"])
        try log(target, [line(60, "b", "sixty")])
        XCTAssertEqual(target.log?.lines(in: .buffer(network: libera(target).id, key: "#alpha"), matching: "sixty",
                                         limit: 10).map(\.text), ["sixty"])
        XCTAssertEqual(target.log?.nicks(startingWith: "a", limit: 5), ["a"], "imported nicks complete")
    }

    func testTheSameLineTwiceComesOverTwiceOnce() async throws {
        let source = makeModel("source")
        try log(source, [line(1, "a", "again"), line(1, "a", "again"), line(2, "a", "other")])
        let archive = try export(source, parts: [.messages])
        defer { archive.cleanUp() }
        let target = makeModel("target")
        try log(target, [line(1, "a", "again")])
        let first = try await target.importArchive(archive, parts: [.messages]) { _ in }
        XCTAssertEqual(first.linesAdded, 2, "the second copy and the other line")
        XCTAssertEqual(try texts(target), ["again", "again", "other"])
        let second = try await target.importArchive(archive, parts: [.messages]) { _ in }
        XCTAssertEqual(second.linesAdded, 0)
    }

    func testOlderLinesGoBeforeWithoutNumberingAgain() async throws {
        let source = makeModel("source")
        try log(source, [line(1, "a", "one"), line(2, "a", "two")])
        let archive = try export(source, parts: [.messages])
        defer { archive.cleanUp() }
        let target = makeModel("target")
        try log(target, [line(10, "b", "ten")])
        let result = try await target.importArchive(archive, parts: [.messages]) { _ in }
        XCTAssertTrue(result.renumbered.isEmpty)
        XCTAssertEqual(try texts(target), ["one", "two", "ten"])
    }

    func testLinesWrittenDuringAnImportWaitForIt() throws {
        let model = makeModel("m")
        model.log?.holdWrites()
        try log(model, [line(5, "a", "meanwhile")])
        XCTAssertEqual(try texts(model), [])
        model.log?.resumeWrites()
        XCTAssertEqual(try texts(model), ["meanwhile"])
        XCTAssertEqual(model.log?.revision.value, 1)
    }

    func testNetworkIDsInSettingsAreTranslated() {
        let old = UUID(), new = UUID(), same = UUID()
        let value: [String: Any] = [old.uuidString: ["network": old.uuidString, "other": same.uuidString],
                                    "list": [old.uuidString.lowercased(), "text"]]
        let replaced = AppModel.replacingIDs(in: value, [old: new, same: same]) as? [String: Any]
        let inner = replaced?[new.uuidString] as? [String: String]
        XCTAssertEqual(inner?["network"], new.uuidString)
        XCTAssertEqual(inner?["other"], same.uuidString)
        XCTAssertEqual(replaced?["list"] as? [String], [new.uuidString, "text"])
    }

    func testTimesAndNames() {
        for seconds in [0, 1_760_000_000.123, -86_400.5, 1_760_000_000.9996] {
            let text = LogArchive.formatTime(seconds)
            XCTAssertEqual(LogArchive.parseTime(text) ?? .nan, (seconds * 1000).rounded() / 1000, accuracy: 0.0001, text)
        }
        XCTAssertEqual(LogArchive.formatTime(-0.5), "1969-12-31T23:59:59.500Z")
        XCTAssertEqual(LogArchive.parseTime("2026-10-15T15:21:59+02:00"), LogArchive.parseTime("2026-10-15T13:21:59.000Z"))
        XCTAssertEqual(LogArchive.safeName("../a/b:c"), "_._a_b_c")
        XCTAssertEqual(ArchivePart.part(forSetting: "highlight.words"), .highlights)
        XCTAssertEqual(ArchivePart.part(forSetting: "identity.nick"), .general)
        XCTAssertNil(ArchivePart.part(forSetting: "openBuffers"))
    }

    func testABackupIsACheckedCopyRestoredAtTheNextLaunch() throws {
        let model = makeModel("m")
        try log(model, [line(1, "a", "kept")])
        let source = try XCTUnwrap(model.log?.fileURL)
        let backup = directory.appending(path: "backup.sqlite")
        try LogStore.backUp(source, to: backup)
        XCTAssertNil(LogStore.checkBackup(backup))
        try Data("not a database".utf8).write(to: directory.appending(path: "junk.sqlite"))
        XCTAssertNotNil(LogStore.checkBackup(directory.appending(path: "junk.sqlite")))

        let other = directory.appending(path: "other/logs.sqlite")
        _ = try LogStore(fileURL: other)
        try LogStore.restoreAtNextLaunch(backup)
        LogStore.restorePendingBackup(log: other)
        let restored = try LogStore(fileURL: other)
        XCTAssertEqual(restored.lines(in: .buffer(network: libera(model).id, key: "#alpha"), limit: 5).map(\.text),
                       ["kept"])
        let kept = try FileManager.default.contentsOfDirectory(atPath: other.deletingLastPathComponent().path)
        XCTAssertTrue(kept.contains { $0.hasPrefix("logs.sqlite.before-restore-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: LogStore.pendingRestoreFile.path))
    }
}

/// Times export and import on a copy of a real log; run by hand with
/// TEST_RUNNER_IRCTELL_PERF_LOG=<a copy of logs.sqlite>.
@MainActor
final class TransferPerformanceTests: XCTestCase {
    func testARealLog() async throws {
        guard let path = ProcessInfo.processInfo.environment["IRCTELL_PERF_LOG"] else {
            throw XCTSkip("set IRCTELL_PERF_LOG to a copy of a log")
        }
        executionTimeAllowance = 3600
        let work = URL(filePath: path).deletingLastPathComponent().appending(path: "perf")
        let zip = work.appending(path: "export.zip")
        // IRCTELL_PERF_REUSE: the export of an earlier run, for timing the import only.
        let reuse = ProcessInfo.processInfo.environment["IRCTELL_PERF_REUSE"] != nil
            && FileManager.default.fileExists(atPath: zip.path)
        for file in (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
            where !(reuse && file == zip) {
            try? FileManager.default.removeItem(at: file)
        }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        func model(_ name: String, log: URL) throws -> AppModel {
            AppModel(store: NetworkStore(fileURL: work.appending(path: "\(name).plist"), usesKeychain: false),
                     settings: SettingsStore(fileURL: work.appending(path: "\(name)-settings.plist")),
                     log: try LogStore(fileURL: log))
        }
        func timed<T>(_ what: String, _ body: () async throws -> T) async rethrows -> T {
            let start = Date.now
            let result = try await body()
            print("PERF \(what): \(String(format: "%.1f", Date.now.timeIntervalSince(start))) s")
            return result
        }
        if !reuse {
            let source = try model("source", log: URL(filePath: path))
            let input = source.exportInput(parts: [.messages, .pictures])
            let manifest = try await timed("export") {
                try await Task.detached { try LogArchive.export(input, to: zip) { _ in } }.value
            }
            print("PERF lines \(manifest.contents["messages"] ?? 0), zip \(TransferView.fileSize(zip))")
        }
        let archive = try await timed("unpack") { try await Task.detached { try LogArchive.unpack(zip) }.value }
        defer { archive.cleanUp() }
        print("PERF unpacked \(archive.conversations.reduce(0) { $0 + $1.lines }) lines in \(archive.conversations.count) conversations")
        if ProcessInfo.processInfo.environment["IRCTELL_PERF_EXPORT_ONLY"] != nil { return }

        let empty = try model("empty", log: work.appending(path: "empty.sqlite"))
        let first = try await timed("import into an empty log") {
            try await empty.importArchive(archive, parts: [.messages, .pictures]) { print("PERF progress", $0) }
        }
        print("PERF added \(first.linesAdded), renumbered \(first.renumbered.count)")
        let again = try await timed("import again") {
            try await empty.importArchive(archive, parts: [.messages]) { _ in }
        }
        XCTAssertEqual(again.linesAdded, 0)
        print("PERF already there \(again.linesAlreadyThere)")

        // A line in the middle of the log's time: everything is numbered again.
        let middle = try model("middle", log: work.appending(path: "middle.sqlite"))
        let network = try XCTUnwrap(middle.networks.first)
        middle.log?.append(ChatLine(time: Date(timeIntervalSince1970: 1_700_000_000), kind: .message, sender: "x",
                                    text: "middle"), networkID: network.id, networkName: network.name,
                           bufferName: "#foxtrot", bufferKind: .channel)
        middle.log?.append(ChatLine(time: .now, kind: .message, sender: "x", text: "now"), networkID: network.id,
                           networkName: network.name, bufferName: "#foxtrot", bufferKind: .channel)
        let renumbered = try await timed("import between lines there") {
            try await middle.importArchive(archive, parts: [.messages]) { _ in }
        }
        print("PERF added \(renumbered.linesAdded)")
    }
}
