import Foundation
import FoundationModels

/// Short sounds heard before or after a line read aloud -- a "hmm", a sigh,
/// an "ooh" -- the kind a listener makes: picked to fit the line, at random
/// how often.
enum Interjection: String, CaseIterable, Sendable {
    case hmm, mhm, huh, ooh, wow, aww, ahh, ugh, sigh, groan, tsk, pfft, ouch

    /// How likely, from 0 to 100, a line gets one before it, and after it:
    /// each line decided at random, the two apart.
    static let beforeKey = "speech.interjections.before"
    static let afterKey = "speech.interjections.after"
    /// Whether Apple Intelligence picks the sound; else simple rules do.
    static let intelligenceKey = "speech.interjections.intelligence"

    /// What it means, for the model and the settings.
    var meaning: String {
        switch self {
        case .hmm: "thinking, doubt, considering"
        case .mhm: "agreeing, listening, yes"
        case .huh: "puzzled, surprised, not understanding"
        case .ooh: "interested, intrigued, impressed"
        case .wow: "amazed, astonished, impressed a lot"
        case .aww: "sympathy, something sad or cute"
        case .ahh: "relief, understanding, satisfaction"
        case .ugh: "annoyed, disgusted, fed up"
        case .sigh: "tired, sad, resigned, bored"
        case .groan: "pain, effort, a bad joke"
        case .tsk: "disapproval, mild scolding"
        case .pfft: "dismissive, scoffing, not impressed"
        case .ouch: "hurt, a harsh remark, a painful story"
        }
    }

    /// Irctell's own, and any the user put in ~/.irctell/sounds/<name>/.
    var sounds: [URL] {
        let bundled = (Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("interjection-\(rawValue)-") }
        let own = (try? FileManager.default.contentsOfDirectory(
            at: IrctellHome.directory.appending(path: "sounds/\(rawValue)"), includingPropertiesForKeys: nil)) ?? []
        let audio = Set(["m4a", "mp3", "wav", "aiff", "aif", "caf", "flac"])
        return bundled + own.filter { audio.contains($0.pathExtension.lowercased()) }
    }

    /// Before and after a line: each at random, the two apart, with the
    /// chances set (0 to 100) bent by how well the sound fits. 50 is about
    /// half of the lines, not exactly every other one.
    static func plan(before: Int, after: Int, fit: InterjectionFit = .good,
                     random: () -> Double = { Double.random(in: 0..<1) }) -> (before: Bool, after: Bool) {
        (random() < fit.chance(before), random() < fit.chance(after))
    }

    /// The sound by simple rules, when Apple Intelligence is off or slow: a
    /// question is thought about, sad words get sympathy, and so on. A word
    /// that tells is a good fit; the guess when none does, a weak one.
    static func byRules(_ text: String) -> InterjectionPick {
        let lower = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        func good(_ choices: Interjection...) -> InterjectionPick { InterjectionPick(choices.randomElement()!, fit: .good) }
        if has(["ouch", "hurt", "pain", "injur"]) { return good(.ouch) }
        if has(["sad", "sorry", "died", "miss you", ":(", "😢", "lost"]) { return good(.aww, .sigh) }
        if has(["tired", "boring", "bored", "monday", "again"]) { return good(.sigh) }
        if has(["ugh", "hate", "annoying", "gross", "stupid"]) { return good(.ugh) }
        if has(["wow", "amazing", "awesome", "incredible", "!!"]) { return good(.wow, .ooh) }
        if has(["cute", "baby", "kitten", "puppy"]) { return good(.aww) }
        if lower.contains("?") { return good(.hmm, .huh) }
        return InterjectionPick([.hmm, .mhm, .ahh, .ooh].randomElement()!, fit: .weak)
    }
}

/// How well a sound fits a line: what bends the chance of hearing it.
enum InterjectionFit: String, Comparable, Sendable {
    case none, weak, good, strong

    static func < (lhs: InterjectionFit, rhs: InterjectionFit) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    static let allCases: [InterjectionFit] = [.none, .weak, .good, .strong]

    /// The chance of the sound, 0 to 1, from the chance set, 0 to 100:
    /// higher when it fits well, lower when weakly, never when not at all.
    /// Never and Always stay what they say.
    func chance(_ percent: Int) -> Double {
        let base = min(max(Double(percent) / 100, 0), 1)
        switch self {
        case .none: return 0
        case .weak: return pow(base, 2)
        case .good: return base
        case .strong: return pow(base, 0.5)
        }
    }
}

/// A sound for a line, and how well it fits.
struct InterjectionPick: Equatable, Sendable {
    var interjection: Interjection?
    var fit: InterjectionFit

    init(_ interjection: Interjection?, fit: InterjectionFit) {
        self.interjection = interjection
        self.fit = interjection == nil ? .none : fit
    }

    static let nothing = InterjectionPick(nil, fit: .none)
}

/// The sound the model picks, or none: a choice it can only make among these.
@Generable
enum InterjectionChoice: String {
    case none, hmm, mhm, huh, ooh, wow, aww, ahh, ugh, sigh, groan, tsk, pfft, ouch
}

@Generable
enum InterjectionFitChoice: String {
    case none, weak, good, strong
}

/// The model's whole answer: the sound, and how well it fits.
@Generable
struct InterjectionAnswer {
    @Guide(description: "The sound a listener would make, or none")
    var sound: InterjectionChoice
    @Guide(description: "How naturally a listener would make that sound here: strong when the line clearly calls for it, good when it suits, weak when it barely does, none when no sound belongs")
    var fit: InterjectionFitChoice
}

/// Picks the sound for a line: Apple Intelligence on this Mac, within a time
/// limit, else the simple rules.
enum InterjectionChooser {
    /// About 2 s per line on an M1 Pro; past this, the rules pick.
    static let timeLimit: Duration = .seconds(3)

    static func choose(for text: String, intelligence: Bool) async -> InterjectionPick {
        guard intelligence, SystemLanguageModel.default.availability == .available else {
            return Interjection.byRules(text)
        }
        let asked = Task { await askModel(text) }
        let timer = Task {
            try? await Task.sleep(for: timeLimit)
            asked.cancel()
        }
        let answer = await asked.value
        timer.cancel()
        // Too slow, or declined: the rules.
        return answer ?? Interjection.byRules(text)
    }

    /// The model's pick and how well it fits; nil when there was no answer.
    static func askModel(_ text: String) async -> InterjectionPick? {
        await InterjectionModel.shared.ask(text)
    }

    static var instructions: String {
        let menu = Interjection.allCases.map { "\($0.rawValue): \($0.meaning)" }.joined(separator: "\n")
        return """
            A chat line is read aloud. Pick the short vocal sound a friendly, sympathetic listener would \
            make on hearing it: the feeling the line calls for in the listener, not in the writer. Bad \
            news calls for sympathy, good news for being impressed, a question for thinking. Then say how \
            well it fits: strong when the line clearly calls for that sound, good when it suits, weak when \
            it barely does. Most everyday lines call for no sound at all: then none. The sounds:
            \(menu)

            Examples:
            "my dog died yesterday" -> aww, strong
            "I failed my driving test again" -> sigh, strong
            "I just got promoted!" -> wow, strong
            "guess what I found in the attic" -> ooh, good
            "should we use postgres or mysql?" -> hmm, good
            "the meeting is at 3" -> mhm, weak
            "I cut my finger cooking" -> ouch, strong
            "he parked on my lawn again" -> ugh, good
            "here is the link to the docs" -> none, none
            "ok" -> none, none
            """
    }
}

/// Asks the model, one line per session: a session kept would answer
/// faster only a little, and its history of earlier lines sways the answers.
actor InterjectionModel {
    static let shared = InterjectionModel()

    func ask(_ text: String) async -> InterjectionPick? {
        let session = LanguageModelSession(model: ReplySuggester.model, instructions: InterjectionChooser.instructions)
        do {
            // The instructions show the answer's form already: the schema
            // left out of the prompt makes it quicker.
            let response = try await session.respond(to: "The line: \(text)", generating: InterjectionAnswer.self,
                                                     includeSchemaInPrompt: false,
                                                     options: GenerationOptions(temperature: 0.4))
            let answer = response.content
            let interjection = answer.sound == .none ? nil : Interjection(rawValue: answer.sound.rawValue)
            return InterjectionPick(interjection, fit: InterjectionFit(rawValue: answer.fit.rawValue) ?? .none)
        } catch {
            if !(error is CancellationError) {
                AppLog.debug("speech", "no sound picked by the model: \(String(describing: error))")
            }
            return nil
        }
    }
}
