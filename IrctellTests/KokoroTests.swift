import XCTest
@testable import Irctell

/// Runs only where the model is: the folder in IRCTELL_KOKORO_MODEL, or the
/// one Irctell downloads.
final class KokoroTests: XCTestCase {
    private func XCTSkipUnless(_ value: URL?, _ message: String) throws -> URL {
        guard let value else { throw XCTSkip(message) }
        return value
    }

    private var directory: URL? {
        if let path = ProcessInfo.processInfo.environment["IRCTELL_KOKORO_MODEL"] {
            return URL(filePath: path)
        }
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".irctell/voices/\(KokoroEngine.modelName)")
        return FileManager.default.fileExists(atPath: installed.path) ? installed : nil
    }

    func testSpeaksWithEachKindOfVoice() throws {
        let directory = try XCTSkipUnless(self.directory, "no Kokoro model here")
        let started = Date.now
        let file = FileManager.default.fileExists(atPath: directory.appending(path: "model.onnx").path)
            ? "model.onnx" : "model.int8.onnx"
        let engine = try XCTUnwrap(KokoroEngine(directory: directory, modelFile: file))
        let loaded = Date.now.timeIntervalSince(started)
        for name in ["af_heart", "bm_george"] {
            let begun = Date.now
            let samples = engine.generate("Hello there, this is a test of the natural voices.",
                                          voice: try XCTUnwrap(KokoroVoice.named(name)))
            let seconds = Double(samples.count) / Double(KokoroEngine.sampleRate)
            print("Kokoro \(name): \(String(format: "%.2f", seconds)) s of speech in "
                  + "\(String(format: "%.2f", Date.now.timeIntervalSince(begun))) s; model loaded in "
                  + "\(String(format: "%.2f", loaded)) s")
            XCTAssertGreaterThan(seconds, 1.5)
            XCTAssertLessThan(seconds, 10)
            XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.05, "not silence")
        }
    }

    /// Timings of the settings, to choose them; only with IRCTELL_KOKORO_BENCH.
    func testSettingsCompared() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["IRCTELL_KOKORO_BENCH"] == nil)
        let directory = try XCTSkipUnless(self.directory, "no Kokoro model here")
        let text = "Welcome back. The meeting moved to Thursday, so we have a little more time to prepare."
        for (file, threads, provider) in [("model.int8.onnx", 2, "cpu"), ("model.int8.onnx", 4, "cpu"),
                                          ("model.int8.onnx", 8, "cpu"), ("model.int8.onnx", 4, "coreml"),
                                          ("model.onnx", 4, "cpu"), ("model.onnx", 8, "cpu"), ("model.onnx", 4, "coreml")]
            where FileManager.default.fileExists(atPath: directory.appending(path: file).path) {
            guard let engine = KokoroEngine(directory: directory, modelFile: file, threads: Int32(threads),
                                            provider: provider) else { continue }
            _ = engine.generate("Warm up.", voice: KokoroVoice.english[3])
            let begun = Date.now
            let samples = engine.generate(text, voice: KokoroVoice.english[3])
            let made = Date.now.timeIntervalSince(begun)
            let seconds = Double(samples.count) / Double(KokoroEngine.sampleRate)
            print("Kokoro bench \(file) threads \(threads) \(provider): \(String(format: "%.2f", made)) s for "
                  + "\(String(format: "%.2f", seconds)) s, \(String(format: "%.2f", seconds / made))x real time")
        }
    }

    func testPausesGoIntoTheAudio() throws {
        let directory = try XCTSkipUnless(self.directory, "no Kokoro model here")
        let file = FileManager.default.fileExists(atPath: directory.appending(path: "model.onnx").path)
            ? "model.onnx" : "model.int8.onnx"
        let engine = try XCTUnwrap(KokoroEngine(directory: directory, modelFile: file))
        let voice = try XCTUnwrap(KokoroVoice.named("bf_emma"))
        let one = Speaker.render([("Name: Bob", false)], voice: voice, pauseAfter: 0, with: engine)
        let split = Speaker.render([("Name:", true), (" Bob ", false), ("Age:", true), (" 30", false)], voice: voice,
                                   pauseAfter: 0, with: engine)
        XCTAssertGreaterThan(split.count, one.count + Int(0.6 * Double(KokoroEngine.sampleRate)),
                             "the second key comes after a pause")
    }

    func testVoiceList() {
        XCTAssertEqual(KokoroVoice.english.count, 28)
        XCTAssertEqual(KokoroVoice.named("af_heart")?.speaker, 3)
        XCTAssertEqual(KokoroVoice.named("bm_lewis")?.speaker, 27)
        XCTAssertTrue(KokoroVoice.named("bf_emma")?.isFemale ?? false)
        XCTAssertFalse(KokoroVoice.named("am_adam")?.isFemale ?? true)
        XCTAssertEqual(KokoroVoice.named("af_heart")?.title, "Heart")
    }
}
