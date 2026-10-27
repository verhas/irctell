import Foundation
import SherpaOnnx

/// One of Kokoro's English voices: "af_heart" is an American woman's,
/// "bm_george" a British man's.
struct KokoroVoice: Hashable, Sendable, Identifiable {
    let name: String
    /// The speaker number in the model.
    let speaker: Int32
    var id: String { name }

    var isFemale: Bool { name.dropFirst().first == "f" }
    var isBritish: Bool { name.first == "b" }

    /// "Heart", for the voice picker.
    var title: String {
        let base = name.split(separator: "_").last.map(String.init) ?? name
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    var details: String {
        "\(isBritish ? "British" : "American") English · \(isFemale ? "female" : "male") · natural"
    }

    /// The model's English speakers, in its own order: they are 0 to 27.
    static let english: [KokoroVoice] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
        "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable",
        "bm_george", "bm_lewis",
    ].enumerated().map { KokoroVoice(name: $1, speaker: Int32($0)) }

    static func named(_ name: String) -> KokoroVoice? {
        english.first { $0.name == name }
    }
}

/// Kokoro, an open neural speech model, run on the Mac through sherpa-onnx:
/// voices that sound like people, not machines. The model is downloaded once
/// into Irctell's home; making speech takes a fraction of a second, so it is
/// done off the main thread.
final class KokoroEngine: @unchecked Sendable {
    /// The model release, from sherpa-onnx's model downloads: the full
    /// precision one, which is five times faster than real time on Apple
    /// silicon where the 8-bit one barely keeps up.
    static let modelName = "kokoro-multi-lang-v1_0"
    static let modelURL = URL(string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/\(modelName).tar.bz2")!
    static let modelSHA256 = "c5f7e2d2caf082bc1d20fb70334a61d99d20b484500aad32e7cf84c128ea3298"
    /// About the size of the download, for telling the user.
    static let downloadMegabytes = 350
    static let sampleRate = 24_000

    static var modelDirectory: URL {
        IrctellHome.sharedDirectory.appending(path: "voices/\(modelName)")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.appending(path: "model.onnx").path)
    }

    /// The performance cores: the efficiency ones only slow it down.
    static var defaultThreads: Int32 {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 {
            return min(cores, 8)
        }
        return Int32(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    private let tts: OpaquePointer
    /// One generation at a time: the model is not shared between threads.
    private let lock = NSLock()

    /// Loads the model; nil when it is not there or does not load.
    init?(directory: URL = KokoroEngine.modelDirectory, modelFile: String = "model.onnx",
          threads: Int32? = nil, provider: String = "cpu") {
        let path = { (name: String) in directory.appending(path: name).path }
        guard FileManager.default.fileExists(atPath: path(modelFile)) else { return nil }
        // The library copies the configuration: the strings only have to last
        // through the call.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ text: String) -> UnsafePointer<CChar> {
            let copy = strdup(text)!
            owned.append(copy)
            return UnsafePointer(copy)
        }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = c(path(modelFile))
        config.model.kokoro.voices = c(path("voices.bin"))
        config.model.kokoro.tokens = c(path("tokens.txt"))
        config.model.kokoro.data_dir = c(path("espeak-ng-data"))
        config.model.kokoro.lexicon = c(path("lexicon-us-en.txt"))
        config.model.kokoro.lang = c("en-us")
        config.model.kokoro.length_scale = 1.0
        config.model.num_threads = threads ?? KokoroEngine.defaultThreads
        config.model.provider = c(provider)
        config.max_num_sentences = 1
        guard let tts = SherpaOnnxCreateOfflineTts(&config) else { return nil }
        self.tts = tts
    }

    deinit {
        SherpaOnnxDestroyOfflineTts(tts)
    }

    /// The speech for the text, as 24 kHz mono samples.
    func generate(_ text: String, voice: KokoroVoice, speed: Float = 1.0) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        var generation = SherpaOnnxGenerationConfig()
        generation.sid = voice.speaker
        generation.speed = speed
        generation.silence_scale = 0.2
        guard let audio = text.withCString({ text in
            SherpaOnnxOfflineTtsGenerateWithConfig(tts, text, &generation, nil, nil)
        }) else { return [] }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let count = Int(audio.pointee.n)
        guard count > 0, let samples = audio.pointee.samples else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: count))
    }
}
