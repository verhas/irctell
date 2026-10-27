import AVFoundation
import Observation

/// Reads messages aloud, one after another: who and where in a narrator's
/// voice, then what they wrote in a voice of their own -- Apple's voices, or
/// Kokoro's natural ones. Its own queue, not the synthesizer's, so the
/// message being read can be skipped without dropping the ones after it.
@MainActor @Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = Speaker()

    /// A busy channel can outpace speech; past this many waiting, new lines
    /// are left out until it catches up.
    static let maxWaiting = 8

    /// The conversation whose message is being read now.
    private(set) var speakingBuffer: UUID?

    static let mutedKey = "speech.muted"

    /// Nothing is read aloud, and notifications make no sound; each
    /// conversation keeps its loudspeaker setting for when this goes off.
    var isMuted: Bool {
        didSet {
            SettingsStore.shared.set(isMuted, forKey: Speaker.mutedKey)
            if isMuted { stopAll() }
        }
    }

    /// A piece of text and whether it is the key of a "Key: value" line --
    /// printed red -- which gets a pause before it.
    typealias Segment = (text: String, isKey: Bool)

    /// One thing said, in one voice.
    enum Part {
        case apple(AVSpeechUtterance)
        case kokoro(segments: [Segment], voice: KokoroVoice, pauseAfter: Double)
        /// A laugh or a sigh, from a file.
        case sound(URL, pauseAfter: Double)
    }

    /// A message to read: who and where, then the text.
    private struct Message {
        let id = UUID()
        var buffer: UUID
        var parts: [Part]
        /// False while its sound before or after is still being picked: the
        /// queue waits for it, so messages keep their order.
        var isReady = true
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var waiting: [Message] = []
    @ObservationIgnored private var reading: Message?
    /// What is being said: an Apple utterance, by its identity, or Kokoro's
    /// audio, by a token of its own.
    private enum Saying: Hashable, Sendable {
        case utterance(ObjectIdentifier)
        case kokoro(UUID)
        case sound(UUID)
    }

    @ObservationIgnored private var current: Saying?
    @ObservationIgnored private var skipping = false
    /// Who wrote the message last put in the queue, where, and when.
    struct Said: Equatable {
        var buffer: UUID
        var sender: String
        var time: Date
    }
    @ObservationIgnored private var lastSaid: Said?
    /// A line from the same person in the same conversation within this is
    /// the same message going on -- pasted, or split for being long -- and
    /// is read without saying again who and where.
    static let continuation: TimeInterval = 120
    /// The voice of a nick, and the narrator's; replaceable for tests.
    @ObservationIgnored var voiceFor: (String) -> VoiceRef? = { Voices.voice(for: $0) }
    @ObservationIgnored var narrator: () -> VoiceRef? = { Voices.narrator(engine: .current) }

    @ObservationIgnored private var kokoro: Task<KokoroEngine?, Never>?
    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var audioReady = false
    @ObservationIgnored private let preview = AVSpeechSynthesizer()
    /// The laugh or sigh being played, and what it is in the queue.
    @ObservationIgnored private var soundPlayer: AVAudioPlayer?
    @ObservationIgnored private var soundToken: Saying?
    @ObservationIgnored private var soundPause: Task<Void, Never>?

    /// Unit tests run inside the app: they must never be heard on the
    /// user's speakers, whatever they switch on.
    private let isSilent = IrctellHome.isRunningTests

    override init() {
        isMuted = SettingsStore.shared.bool(forKey: Speaker.mutedKey)
        super.init()
        synthesizer.delegate = self
    }

    /// `place` names the conversation when it is not the one on screen;
    /// without `announcing`, who wrote it is not said.
    func say(_ line: ChatLine, place: String?, announcing: Bool = true, buffer: UUID) {
        guard !isMuted, !isSilent, waiting.count < Speaker.maxWaiting else { return }
        let continues = Speaker.continues(lastSaid, line: line, buffer: buffer)
        guard let parts = Speaker.parts(of: line, place: place, announcing: announcing && !continues,
                                        narrator: narrator(), voiceFor: voiceFor,
                                        soundFor: { Speaker.reactionSound($0) },
                                        expand: { Abbreviations.shared.expand($0) })
        else { return }
        lastSaid = line.sender.map { Said(buffer: buffer, sender: $0.lowercased(), time: line.time) }
        let settings = SettingsStore.shared
        let before = settings.object(forKey: Interjection.beforeKey) as? Int ?? 0
        let after = settings.object(forKey: Interjection.afterKey) as? Int ?? 0
        let pickSound = line.isActivity && (before > 0 || after > 0)
        let correct = line.isActivity && settings.bool(forKey: LinePreparer.correctKey, default: true)
        guard pickSound || correct else {
            waiting.append(Message(buffer: buffer, parts: parts))
            speakNext()
            return
        }
        // In the queue at once, in its place, while Apple Intelligence
        // corrects its spelling and picks a sound, and how well that fits
        // decides how likely it is heard.
        let message = Message(buffer: buffer, parts: parts, isReady: false)
        waiting.append(message)
        let text = IRCFormatting.strip(line.text)
        let announced = announcing && !continues
        let intelligence = settings.bool(forKey: Interjection.intelligenceKey, default: true)
        let speaking = announcing && !continues
        Task {
            let prepared = await LinePreparer.prepare(text, correct: correct, pickSound: pickSound,
                                                      intelligence: intelligence)
            // Corrected: said as corrected.
            var corrected: [Part]?
            if prepared.text != text {
                var fixed = line
                fixed.text = prepared.text
                corrected = Speaker.parts(of: fixed, place: place, announcing: speaking, narrator: narrator(),
                                          voiceFor: voiceFor, soundFor: { Speaker.reactionSound($0) },
                                          expand: { Abbreviations.shared.expand($0) })
            }
            let pick = prepared.pick ?? .nothing
            let plan = pickSound ? Interjection.plan(before: before, after: after, fit: pick.fit) : (false, false)
            if pickSound {
                AppLog.debug("speech", "sound \(pick.interjection?.rawValue ?? "none"), fit \(pick.fit.rawValue): "
                    + "\(plan.0 ? "before" : "")\(plan.0 && plan.1 ? " and " : "")\(plan.1 ? "after" : "")"
                    + "\(plan.0 || plan.1 ? "" : "not played")")
            }
            addInterjection(pick.interjection, to: message.id, before: plan.0, after: plan.1,
                            afterAnnouncement: announced, replacing: corrected)
        }
    }

    /// Puts the picked sound before the message's text -- after the narrator
    /// naming the channel -- and after it, as planned; then it may be said.
    private func addInterjection(_ interjection: Interjection?, to id: UUID, before: Bool, after: Bool,
                                 afterAnnouncement: Bool, replacing corrected: [Part]? = nil) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        if let corrected { waiting[index].parts = corrected }
        if let interjection {
            // Two different sounds of the kind, when there are two.
            var sounds = interjection.sounds.shuffled()
            if before, let url = sounds.popLast() ?? interjection.sounds.randomElement() {
                let position = afterAnnouncement && waiting[index].parts.count > 1 ? 1 : 0
                waiting[index].parts.insert(.sound(url, pauseAfter: 0.12), at: position)
            }
            if after, let url = sounds.popLast() ?? interjection.sounds.randomElement() {
                waiting[index].parts.append(.sound(url, pauseAfter: 0.3))
            }
        }
        waiting[index].isReady = true
        speakNext()
    }

    /// Whether the line goes on from the one before: the same person, the
    /// same conversation, a moment later.
    static func continues(_ previous: Said?, line: ChatLine, buffer: UUID) -> Bool {
        guard let previous, let sender = line.sender else { return false }
        return previous.buffer == buffer && previous.sender == sender.lowercased()
            && line.time.timeIntervalSince(previous.time) < continuation
    }

    /// Who asked for lines to be read: what goes in the queue for them.
    static let selectionBuffer = UUID()

    /// Reads lines the user picked, their own too, all of them: what was
    /// picked before and not read yet goes. The conversation is on screen,
    /// so who wrote what is not said: each nick's voice tells.
    func read(_ lines: [ChatLine]) {
        guard !isMuted, !isSilent else { return }
        stop(buffer: Speaker.selectionBuffer)
        for line in lines where line.isActivity {
            guard let parts = Speaker.parts(of: line, place: nil, announcing: false, narrator: narrator(),
                                            voiceFor: voiceFor, soundFor: { Speaker.reactionSound($0) },
                                            expand: { Abbreviations.shared.expand($0) })
            else { continue }
            waiting.append(Message(buffer: Speaker.selectionBuffer, parts: parts))
        }
        speakNext()
    }

    /// Whether a message is being read, for the Skip button.
    var isSpeaking: Bool { speakingBuffer != nil }

    /// Stops the message being read, and goes on with the next.
    func skip() {
        guard let current else { return }
        skipping = true
        switch current {
        case .utterance:
            synthesizer.stopSpeaking(at: .immediate)
        case .kokoro:
            player.stop()
            finished(current)
        case .sound:
            soundPlayer?.stop()
            soundPause?.cancel()
            finished(current)
        }
    }

    /// The conversation's loudspeaker went off: its messages are dropped.
    func stop(buffer: UUID) {
        waiting.removeAll { $0.buffer == buffer }
        if speakingBuffer == buffer { skip() }
    }

    private func stopAll() {
        waiting.removeAll()
        skip()
    }

    /// For the voice picker: says the text in the voice now, past the queue.
    func listen(to voice: VoiceRef, saying text: String) {
        guard !isSilent else { return }
        switch voice {
        case .apple(let apple):
            preview.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = apple
            preview.speak(utterance)
        case .kokoro(let kokoroVoice):
            Task {
                guard let engine = await kokoroEngine() else { return }
                let samples = await Task.detached { engine.generate(text, voice: kokoroVoice) }.value
                play(samples, token: nil)
            }
        }
    }

    /// The model was downloaded or removed: loaded afresh when next needed.
    func reloadKokoro() {
        kokoro = nil
    }

    // MARK: - The queue

    private func speakNext() {
        guard current == nil else { return }
        if reading == nil || reading?.parts.isEmpty == true {
            guard !waiting.isEmpty else {
                reading = nil
                speakingBuffer = nil
                return
            }
            // The next one waits for its sound to be picked.
            guard waiting[0].isReady else {
                reading = nil
                return
            }
            reading = waiting.removeFirst()
        }
        guard let part = reading?.parts.removeFirst() else { return }
        speakingBuffer = reading?.buffer
        switch part {
        case .apple(let utterance):
            current = .utterance(ObjectIdentifier(utterance))
            synthesizer.speak(utterance)
        case .kokoro(let segments, let voice, let pause):
            let token = Saying.kokoro(UUID())
            current = token
            Task { await sayWithKokoro(segments, voice: voice, pauseAfter: pause, token: token) }
        case .sound(let url, let pause):
            let token = Saying.sound(UUID())
            current = token
            play(sound: url, pauseAfter: pause, token: token)
        }
    }

    // MARK: - Sounds

    private func play(sound url: URL, pauseAfter: Double, token: Saying) {
        guard let sound = try? AVAudioPlayer(contentsOf: url) else {
            AppLog.error("speech", "cannot play \(url.lastPathComponent)")
            return finished(token)
        }
        sound.delegate = self
        soundPlayer = sound
        soundToken = token
        soundPauseAfter = pauseAfter
        guard sound.play() else { return finished(token) }
    }

    /// The pause after the sound playing, before what comes next.
    @ObservationIgnored private var soundPauseAfter = 0.0

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedPlayer = ObjectIdentifier(player)
        Task { @MainActor in
            guard let playing = self.soundPlayer, ObjectIdentifier(playing) == finishedPlayer,
                  let token = soundToken else { return }
            soundPlayer = nil
            soundToken = nil
            let pause = soundPauseAfter
            soundPause = Task {
                try? await Task.sleep(for: .seconds(pause))
                if !Task.isCancelled { finished(token) }
            }
        }
    }

    private func finished(_ id: Saying) {
        guard id == current else { return }
        current = nil
        if skipping {
            skipping = false
            reading = nil
        }
        speakNext()
    }

    // MARK: - Kokoro

    /// The engine, loaded once, off the main thread: loading takes a moment.
    private func kokoroEngine() async -> KokoroEngine? {
        if kokoro == nil {
            kokoro = Task.detached { KokoroEngine() }
        }
        return await kokoro?.value
    }

    private func sayWithKokoro(_ segments: [Segment], voice: KokoroVoice, pauseAfter: Double,
                               token: Saying) async {
        guard let engine = await kokoroEngine() else {
            finished(token)
            return
        }
        let samples = await Task.detached {
            Speaker.render(segments, voice: voice, pauseAfter: pauseAfter, with: engine)
        }.value
        guard current == token else { return } // skipped while it was being made
        play(samples, token: token)
    }

    /// The audio of the segments: a piece per key with what follows it, and
    /// a pause before each key but the first.
    nonisolated static func render(_ segments: [Segment], voice: KokoroVoice, pauseAfter: Double,
                                   with engine: KokoroEngine) -> [Float] {
        let rate = Double(KokoroEngine.sampleRate)
        var samples: [Float] = []
        for (index, chunk) in chunks(segments).enumerated() {
            if index > 0 { samples += Array(repeating: 0, count: Int(0.6 * rate)) }
            for (part, piece) in pausedPieces(chunk).enumerated() {
                if part > 0 { samples += Array(repeating: 0, count: Int(ellipsisPause * rate)) }
                for (clause, words) in commaPieces(piece).enumerated() {
                    if clause > 0 { samples += Array(repeating: 0, count: Int(commaPause * rate)) }
                    samples += engine.generate(words, voice: voice)
                }
            }
        }
        samples += Array(repeating: 0, count: Int(pauseAfter * rate))
        return samples
    }

    /// How long "..." keeps silent.
    nonisolated static let ellipsisPause = 0.5
    /// And a comma: the voices' own pause is too short to hear.
    nonisolated static let commaPause = 0.25

    /// Whether the comma at `index` is a pause: not one between digits, as
    /// in 1,000.
    nonisolated private static func isPause(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "," else { return false }
        let before = index > 0 ? characters[index - 1] : " "
        let after = index + 1 < characters.count ? characters[index + 1] : " "
        return !(before.isNumber && after.isNumber)
    }

    /// The text split after its commas, each piece keeping its comma, so the
    /// voice says it as the end of a clause.
    nonisolated static func commaPieces(_ text: String) -> [String] {
        let characters = Array(text)
        var pieces: [String] = []
        var current = ""
        for index in characters.indices {
            current.append(characters[index])
            if isPause(characters, at: index) {
                pieces.append(current)
                current = ""
            }
        }
        pieces.append(current)
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "," }
    }

    /// For Apple's voices: a break after each comma that is a pause.
    nonisolated static func withCommaBreaks(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        for index in characters.indices {
            result.append(characters[index])
            if isPause(characters, at: index) { result += #" <break time="\#(Int(commaPause * 1000))ms"/> "# }
        }
        return result
    }
    nonisolated private static var ellipsis: Regex<Substring> { /\s*(?:\.{3,}|…)\s*/ }

    /// The text split at its "..." and "…", where a pause goes.
    nonisolated static func pausedPieces(_ text: String) -> [String] {
        text.split(separator: ellipsis).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The text split where the pauses go: before every key but the first.
    nonisolated static func chunks(_ segments: [Segment]) -> [String] {
        var chunks: [String] = []
        for (index, segment) in segments.enumerated() {
            if (segment.isKey && index > 0) || chunks.isEmpty {
                chunks.append(segment.text)
            } else {
                chunks[chunks.count - 1] += segment.text
            }
        }
        return chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func play(_ samples: [Float], token: Saying?) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(KokoroEngine.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            if let token { finished(token) }
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        if !audioReady {
            audio.attach(player)
            audio.connect(player, to: audio.mainMixerNode, format: format)
            audioReady = true
        }
        if !audio.isRunning {
            do {
                try audio.start()
            } catch {
                AppLog.error("speech", "no audio: \(error)")
                if let token { finished(token) }
                return
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let token else { return }
            Task { @MainActor in self?.finished(token) }
        }
        if !player.isPlaying { player.play() }
    }

    // MARK: - What is said

    /// The announcement and the text, in their voices, with sounds for the
    /// laughs and sad faces in it; nil for nothing to read.
    static func parts(of line: ChatLine, place: String?, announcing: Bool = true, narrator: VoiceRef?,
                      voiceFor: (String) -> VoiceRef?,
                      soundFor: (Reaction) -> URL? = { _ in nil },
                      expand: (String) -> String = { $0 }) -> [Part]? {
        var items: [BodyItem] = []
        var speech: [Segment] = []
        func endSpeech() {
            if speech.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                items.append(.speech(speech))
            }
            speech = []
        }
        for segment in speakableSegments(line.text) {
            for piece in Reaction.pieces(of: segment.text) {
                switch piece {
                case .text(let text):
                    speech.append((expand(text), segment.isKey))
                case .sound(let reaction, let text):
                    if let url = soundFor(reaction) {
                        endSpeech()
                        items.append(.sound(url))
                    } else {
                        speech.append((expand(text), segment.isKey))
                    }
                }
            }
        }
        endSpeech()
        guard !items.isEmpty else { return nil }

        let voice = line.sender.flatMap(voiceFor) ?? narrator
        var body: [Part] = []
        for (index, item) in items.enumerated() {
            let pause = index == items.count - 1 ? 0.3 : 0.1
            switch item {
            case .speech(let segments): body.append(part(segments, voice: voice, pauseAfter: pause))
            case .sound(let url): body.append(.sound(url, pauseAfter: pause))
            }
        }
        guard announcing else { return body }
        let who = line.sender.map(spokenNick) ?? "Someone"
        let source = place.map { "\(who) in \($0)" } ?? who
        let announcement = line.kind == .notice ? "Notice from \(source)" : source
        return [part([(announcement, false)], voice: narrator, pauseAfter: 0.15)] + body
    }

    /// What a message is made of: text to say, and sounds.
    private enum BodyItem {
        case speech([Segment])
        case sound(URL)
    }

    /// A sound for the reaction, when they are switched on.
    static func reactionSound(_ reaction: Reaction) -> URL? {
        guard SettingsStore.shared.bool(forKey: Reaction.enabledKey, default: true) else { return nil }
        return reaction.randomSound
    }

    private static func part(_ segments: [Segment], voice: VoiceRef?, pauseAfter: Double) -> Part {
        if case .kokoro(let kokoroVoice) = voice {
            return .kokoro(segments: segments, voice: kokoroVoice, pauseAfter: pauseAfter)
        }
        let utterance = AVSpeechUtterance(ssmlRepresentation: ssml(segments)) ?? AVSpeechUtterance(string: plain(segments))
        if case .apple(let apple) = voice { utterance.voice = apple }
        utterance.postUtteranceDelay = pauseAfter
        return .apple(utterance)
    }

    /// A nick as a name, said: "[Anna]{MTB}" is "Anna", "texan_master|away"
    /// "texan master". Brackets and what is in them, anything after a "|",
    /// and the marks around it go; underscores and the like are spaces.
    static func spokenNick(_ nick: String) -> String {
        let groups = /\[([^\]]*)\]|\{([^}]*)\}|\(([^)]*)\)|<([^>]*)>/
        func words(_ text: Substring) -> String {
            text.replacing(/[_\-.^`\\]+/, with: " ").split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let main = nick.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let spoken = words(main.replacing(groups, with: " ")[...])
        if !spoken.isEmpty { return spoken }
        // All of it in brackets: the first is the name.
        if let first = main.firstMatch(of: groups) {
            let inner = first.output.1 ?? first.output.2 ?? first.output.3 ?? first.output.4 ?? ""
            let name = words(inner)
            if !name.isEmpty { return name }
        }
        return nick
    }

    /// Pieces of the text: the keys of "Key: value" lines -- printed red --
    /// marked, links as "a link to example.org", at most a few sentences.
    static func speakableSegments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var length = 0
        for run in IRCFormatting.runs(text) where length < 400 {
            var piece = run.text
            for url in IRCFormatting.webLinks(in: piece) {
                piece = piece.replacingOccurrences(of: url.absoluteString, with: "a link to \(url.host() ?? "a site")")
            }
            if length + piece.count > 400 { piece = String(piece.prefix(400 - length)) + "…" }
            length += piece.count
            let isKey = [4, 5].contains(run.style.foreground?.index ?? -1)
            if let last = segments.last, last.isKey == isKey {
                segments[segments.count - 1].text += piece
            } else {
                segments.append((piece, isKey))
            }
        }
        return segments
    }

    /// For Apple's voices: a longer pause before each key, but the first.
    static func ssml(_ segments: [Segment]) -> String {
        var body = ""
        for (index, segment) in segments.enumerated() {
            if segment.isKey && index > 0 { body += #"<break time="600ms"/>"# }
            let escaped = segment.text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            body += withCommaBreaks(escaped)
                .replacing(ellipsis, with: #" <break time="\#(Int(ellipsisPause * 1000))ms"/> "#)
        }
        return "<speak>\(body)</speak>"
    }

    static func plain(_ segments: [Segment]) -> String {
        segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text as read, without the pauses.
    static func speakable(_ text: String) -> String {
        plain(speakableSegments(text))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = Saying.utterance(ObjectIdentifier(utterance))
        Task { @MainActor in finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = Saying.utterance(ObjectIdentifier(utterance))
        Task { @MainActor in finished(id) }
    }
}
