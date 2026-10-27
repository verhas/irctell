import AVFoundation

/// A guess from the nick alone, for picking a voice that fits.
enum NickGender: Equatable {
    case female, male, unknown

    /// Words and names that suggest a woman or a man somewhere in the nick:
    /// "MissAnna", "slave_wife", "TexanMaster". Feminine forms are checked
    /// first: "domme" holds "dom", "woman" holds "man".
    private static let femaleWords = [
        "domme", "mistress", "goddess", "queen", "princess", "lady", "woman", "women", "girl", "gurl", "grrl",
        "wife", "miss", "mrs", "madam", "maam", "fem", "babe", "mama", "mommy",
        "sister", "daughter", "bride", "slut", "whore", "bitch", "kitten", "angel", "diva", "vixen",
        "anna", "anne", "kathy", "kate", "lisa", "maria", "mary", "sarah", "sara", "emma", "julia", "jenny",
        "jessica", "laura", "linda", "nicole", "natalie", "nina", "olivia", "sophie", "sophia", "susan",
        "amanda", "amy", "alice", "eva", "ella", "lucy", "lily", "rose", "jane", "helen", "claire",
        "charlene", "charlotte", "michelle", "melissa", "monica", "rachel", "rebecca", "tina", "vera",
        "zsuzsa", "kati", "eszter", "anita", "agnes", "judit", "kriszta", "petra", "reka", "dora", "lilla",
    ]
    private static let maleWords = [
        "master", "sir", "king", "lord", "daddy", "dad", "husband", "guy", "boy", "man", "men", "male", "mr",
        "dom", "bull", "stud", "prince", "god", "bro", "dude", "hubby",
        "john", "james", "robert", "michael", "david", "richard", "thomas", "mark", "paul", "peter", "steve",
        "kevin", "brian", "george", "edward", "frank", "jack", "joe", "mike", "tom", "tony", "dave", "rob",
        "bob", "bill", "jim", "andrew", "chris", "dan", "matt", "nick", "alex", "adam", "ben", "sam",
        "laszlo", "istvan", "janos", "zoltan", "gabor", "attila", "tamas", "peti", "zsolt", "balazs",
    ]

    static func guess(_ nick: String) -> NickGender {
        let lowered = nick.lowercased()
        if femaleWords.contains(where: { lowered.contains($0) }) { return .female }
        // "Domlook4subf", "sub_f": an f at the end says it, also after "dom".
        let letters = lowered.filter(\.isLetter)
        if letters.hasSuffix("f") && !letters.hasSuffix("ff") { return .female }
        if maleWords.contains(where: { lowered.contains($0) }) { return .male }
        return .unknown
    }
}

/// Which voices messages are read in.
enum SpeechEngine: String, CaseIterable, Sendable {
    /// The voices of macOS.
    case apple
    /// Kokoro, run on the Mac: natural voices, downloaded once.
    case kokoro

    static let key = "speech.engine"

    var title: String {
        switch self {
        case .apple: "Apple voices"
        case .kokoro: "Natural voices (Kokoro)"
        }
    }

    /// The one chosen, when it can be used: Kokoro once its model is there.
    @MainActor static var current: SpeechEngine {
        let chosen = SettingsStore.shared.string(forKey: key).flatMap(SpeechEngine.init(rawValue:)) ?? .apple
        return chosen == .kokoro && !KokoroEngine.isInstalled ? .apple : chosen
    }
}

/// A voice of either engine.
enum VoiceRef: Hashable {
    case apple(AVSpeechSynthesisVoice)
    case kokoro(KokoroVoice)

    /// How it is kept in the settings: Apple's identifier, or "kokoro:af_heart".
    var id: String {
        switch self {
        case .apple(let voice): voice.identifier
        case .kokoro(let voice): "kokoro:\(voice.name)"
        }
    }

    init?(id: String) {
        if id.hasPrefix("kokoro:") {
            guard let voice = KokoroVoice.named(String(id.dropFirst("kokoro:".count))) else { return nil }
            self = .kokoro(voice)
        } else {
            guard let voice = AVSpeechSynthesisVoice(identifier: id) else { return nil }
            self = .apple(voice)
        }
    }

    var name: String {
        switch self {
        case .apple(let voice): voice.name
        case .kokoro(let voice): voice.title
        }
    }
}

/// The voices messages are read in: one per nick, kept once given.
@MainActor
enum Voices {
    /// Voices chosen by hand, by the lowercased nick: either engine's.
    static let chosenKey = "speech.chosenVoices"
    /// Voices given by themselves, per engine, with the set of voices they
    /// were given from: when that changes -- better voices downloaded -- they
    /// are given anew.
    static let automaticKey = "speech.automaticVoices"

    /// Reads who wrote and where, with Kokoro.
    static let kokoroNarrator = KokoroVoice.named("am_michael")!

    /// Novelty voices that are no voice to listen to; they are also marked
    /// as novelty where the system says so.
    private static let novelty: Set<String> = [
        "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News", "Jester", "Organ",
        "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox",
    ]

    /// English voices that speak like a person, the best quality first.
    static var english: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                voice.language.hasPrefix("en") && !novelty.contains(voice.name)
                    && !voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice)
            }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    /// The English voices of the best quality installed: the Premium and
    /// Enhanced ones once there are any, which sound far less robotic.
    static var bestEnglish: [AVSpeechSynthesisVoice] {
        let voices = english
        guard let best = voices.map(\.quality.rawValue).max() else { return [] }
        return voices.filter { $0.quality.rawValue == best }
    }

    /// Every voice, for choosing one by hand: by language, then name.
    static var all: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    /// The voice the system is set to speak in, for saying who wrote and where.
    /// Read from the speech preferences: AVFoundation offers only a default
    /// by language, and the Mac's language need not be English.
    static var systemDefault: AVSpeechSynthesisVoice? {
        let prefs = UserDefaults(suiteName: "com.apple.speech.voice.prefs")
        if let name = prefs?.string(forKey: "SelectedVoiceName"),
           let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == name }) {
            return voice
        }
        return bestEnglish.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Who wrote and where is said in this.
    static func narrator(engine: SpeechEngine) -> VoiceRef? {
        switch engine {
        case .apple: systemDefault.map(VoiceRef.apple)
        case .kokoro: .kokoro(kokoroNarrator)
        }
    }

    /// The nick's voice: the one chosen for it, or one given now and kept --
    /// a woman's for a nick that looks like a woman's, a man's for a man's.
    /// There are fewer voices than nicks: many share one.
    static func voice(for nick: String, engine: SpeechEngine = .current,
                      settings: SettingsStore = .shared) -> VoiceRef? {
        let key = nick.lowercased()
        if let id = chosen(for: nick, settings: settings), let voice = VoiceRef(id: id) {
            return voice
        }
        let pool = pool(for: NickGender.guess(nick), engine: engine)
        guard !pool.isEmpty else { return nil }
        let signature = String(stableHash(pool.map(\.id).sorted().joined(separator: ",")))
        var all = settings.dictionary(forKey: automaticKey) ?? [:]
        var given = all[engine.rawValue] as? [String: String] ?? [:]
        if given["*"] != signature { given = ["*": signature] }
        if let id = given[key], let voice = VoiceRef(id: id), pool.contains(voice) {
            return voice
        }
        let voice = pool[Int(stableHash(key) % UInt32(pool.count))]
        given[key] = voice.id
        all[engine.rawValue] = given
        settings.set(all, forKey: automaticKey)
        return voice
    }

    /// The voices a nick of this look is given from.
    static func pool(for gender: NickGender, engine: SpeechEngine) -> [VoiceRef] {
        switch engine {
        case .apple:
            let voices = bestEnglish
            let wanted: AVSpeechSynthesisVoiceGender? = switch gender {
            case .female: .female
            case .male: .male
            case .unknown: nil
            }
            let fitting = wanted.map { gender in voices.filter { $0.gender == gender } } ?? voices
            return (fitting.isEmpty ? voices : fitting).map(VoiceRef.apple)
        case .kokoro:
            let voices = KokoroVoice.english.filter { $0 != kokoroNarrator }
            let fitting = switch gender {
            case .female: voices.filter(\.isFemale)
            case .male: voices.filter { !$0.isFemale }
            case .unknown: voices
            }
            return fitting.map(VoiceRef.kokoro)
        }
    }

    /// The voice chosen by hand for a nick; nil to have one given again.
    static func choose(_ id: String?, for nick: String, settings: SettingsStore = .shared) {
        var chosen = settings.dictionary(forKey: chosenKey) as? [String: String] ?? [:]
        chosen[nick.lowercased()] = id
        settings.set(chosen, forKey: chosenKey)
    }

    static func chosen(for nick: String, settings: SettingsStore = .shared) -> String? {
        (settings.dictionary(forKey: chosenKey) as? [String: String])?[nick.lowercased()]
    }

    /// The same for a nick every time, unlike Swift's own hashing.
    private static func stableHash(_ text: String) -> UInt32 {
        text.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ UInt32($1) }
    }
}
