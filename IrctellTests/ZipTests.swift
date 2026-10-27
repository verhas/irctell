import XCTest
@testable import Irctell

final class ZipTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    /// Text that compresses, and noise that does not, in pieces.
    private func bigData() -> Data {
        var data = Data()
        for index in 0..<60_000 { data.append(Data("{\"time\":\"\(index)\",\"text\":\"hello ünïcødé 🎉\"}\n".utf8)) }
        var random = SystemRandomNumberGenerator()
        data.append(Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255, using: &random) }))
        return data
    }

    func testWhatIsWrittenIsReadBackAndByTheSystemsUnzip() throws {
        let zip = folder.appending(path: "out.zip")
        let big = bigData()
        let writer = try ZipWriter(url: zip)
        try writer.add("manifest.json", data: Data("{\"format\":\"irctell-archive\"}".utf8))
        try writer.begin("lines/Libera.Chat/#alpha.jsonl")
        var position = 0
        while position < big.count {
            let end = min(position + 300_000, big.count)
            try writer.write(big.subdata(in: position..<end))
            position = end
        }
        try writer.end()
        try writer.add("empty.txt", data: Data())
        try writer.finish()

        let (status, output) = try run("/usr/bin/unzip", ["-t", zip.path])
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("No errors detected"), output)

        let reader = try ZipReader(url: zip)
        XCTAssertEqual(reader.entries.map(\.name), ["manifest.json", "lines/Libera.Chat/#alpha.jsonl", "empty.txt"])
        let out = folder.appending(path: "out")
        try reader.extractAll(to: out)
        XCTAssertEqual(try Data(contentsOf: out.appending(path: "lines/Libera.Chat/#alpha.jsonl")), big)
        XCTAssertEqual(try Data(contentsOf: out.appending(path: "empty.txt")), Data())
    }

    func testAZipMadeByTheSystemIsRead() throws {
        // As exports were written before: by ditto.
        let source = folder.appending(path: "archive")
        try FileManager.default.createDirectory(at: source.appending(path: "settings"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appending(path: "manifest.json"))
        try bigData().write(to: source.appending(path: "settings/big.bin"))
        let zip = folder.appending(path: "ditto.zip")
        let (status, output) = try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", source.path, zip.path])
        XCTAssertEqual(status, 0, output)

        let out = folder.appending(path: "read")
        try ZipReader(url: zip).extractAll(to: out)
        XCTAssertEqual(try Data(contentsOf: out.appending(path: "manifest.json")), Data("{}".utf8))
        XCTAssertEqual(try Data(contentsOf: out.appending(path: "settings/big.bin")),
                       try Data(contentsOf: source.appending(path: "settings/big.bin")))
    }

    func testDamageAndEscapingNamesAreRefused() throws {
        let zip = folder.appending(path: "bad.zip")
        let writer = try ZipWriter(url: zip)
        try writer.add("a.txt", data: Data(repeating: 65, count: 10_000))
        try writer.finish()
        var bytes = try Data(contentsOf: zip)
        bytes[60] ^= 0xFF // inside the compressed data
        try bytes.write(to: zip)
        XCTAssertThrowsError(try ZipReader(url: zip).extractAll(to: folder.appending(path: "x")))

        let escaping = folder.appending(path: "escape.zip")
        let sneaky = try ZipWriter(url: escaping)
        try sneaky.add("../outside.txt", data: Data("no".utf8))
        try sneaky.finish()
        XCTAssertThrowsError(try ZipReader(url: escaping).extractAll(to: folder.appending(path: "y")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "outside.txt").path))

        try Data("not a zip at all".utf8).write(to: zip)
        XCTAssertThrowsError(try ZipReader(url: zip))
    }
}
