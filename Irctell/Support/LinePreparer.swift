import Foundation
import FoundationModels

/// A line made ready to be read aloud: its spelling corrected by Apple
/// Intelligence, on this Mac, so the voice does not stumble over typos, and
/// the sound to go with it picked -- in one request when both are wanted.
/// Only what is heard changes: the transcript and the log keep the line as
/// it was written.
enum LinePreparer {
    static let correctKey = "speech.correctSpelling"
    /// Writing out the line takes the model longer than naming a sound.
    static let timeLimit: Duration = .seconds(5)

    struct Prepared: Equatable, Sendable {
        var text: String
        var pick: InterjectionPick?
    }

    static func prepare(_ text: String, correct: Bool, pickSound: Bool, intelligence: Bool) async -> Prepared {
        let worthCorrecting = correct && intelligence && isWorthCorrecting(text)
            && SystemLanguageModel.default.availability == .available
        guard worthCorrecting else {
            let pick = pickSound ? await InterjectionChooser.choose(for: text, intelligence: intelligence) : nil
            return Prepared(text: text, pick: pick)
        }
        let asked = Task { await askModel(text, pickSound: pickSound) }
        let timer = Task {
            try? await Task.sleep(for: timeLimit)
            asked.cancel()
        }
        let answer = await asked.value
        timer.cancel()
        guard let answer else {
            // Too slow, or declined: the line as written, the sound by rules.
            return Prepared(text: text, pick: pickSound ? Interjection.byRules(text) : nil)
        }
        let corrected = accepted(answer.corrected, for: text)
        if corrected != text {
            AppLog.debug("speech", "spelling corrected: \(distance(text, corrected)) characters changed")
        }
        return Prepared(text: corrected, pick: pickSound ? answer.pick ?? Interjection.byRules(text) : nil)
    }

    /// Lines with words in them: not a smiley, a link or a number alone.
    static func isWorthCorrecting(_ text: String) -> Bool {
        let words = text.split(separator: " ").filter { word in
            !word.contains("://") && word.contains { $0.isLetter }
        }
        return words.joined().count >= 3
    }

    /// The correction, or the line as written when the model changed too
    /// much -- rewording rather than spelling -- or gave nothing.
    static func accepted(_ corrected: String, for original: String) -> String {
        let candidate = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate != original else { return original }
        let ratio = Double(candidate.count) / Double(max(original.count, 1))
        guard (0.75...1.35).contains(ratio) else { return original }
        let changed = Double(distance(original, candidate)) / Double(max(original.count, candidate.count))
        return changed <= 0.3 ? candidate : original
    }

    /// How many characters must change to turn one into the other.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - The model

    struct Answer: Sendable {
        var corrected: String
        var pick: InterjectionPick?
    }

    static let correctionRules = """
        Correct the spelling of the chat line: typos, misspelled words, doubled or missing letters. \
        Change nothing else: keep every word, the slang, abbreviations like lol or brb, emoticons, \
        nicks, links, numbers, the punctuation and the language as they are. Do not rephrase, add or \
        remove anything. A line with nothing to correct is given back as it is.
        """

    static func askModel(_ text: String, pickSound: Bool) async -> Answer? {
        do {
            if pickSound {
                let session = LanguageModelSession(model: ReplySuggester.model, instructions: """
                    Two things for each chat line. First: \(correctionRules)

                    Second, the sound: \(InterjectionChooser.instructions)

                    Examples of the corrected line:
                    "my dgo died yesterdy" -> "my dog died yesterday"
                    "teh build is borken again lol" -> "the build is broken again lol"
                    "brb, cofee" -> "brb, coffee"
                    """)
                let response = try await session.respond(to: "The line: \(text)", generating: SpokenLineAnswer.self,
                                                         options: GenerationOptions(temperature: 0.2))
                let answer = response.content
                let interjection = answer.sound == .none ? nil : Interjection(rawValue: answer.sound.rawValue)
                return Answer(corrected: answer.corrected,
                              pick: InterjectionPick(interjection, fit: InterjectionFit(rawValue: answer.fit.rawValue) ?? .none))
            }
            let session = LanguageModelSession(model: ReplySuggester.model, instructions: """
                \(correctionRules)

                Examples:
                "my dgo died yesterdy" -> "my dog died yesterday"
                "teh build is borken again lol" -> "the build is broken again lol"
                "brb, cofee" -> "brb, coffee"
                """)
            let response = try await session.respond(to: "The line: \(text)", generating: CorrectedLine.self,
                                                     options: GenerationOptions(temperature: 0.2))
            return Answer(corrected: response.content.corrected, pick: nil)
        } catch {
            if !(error is CancellationError) {
                AppLog.debug("speech", "line not corrected: \(String(describing: error))")
            }
            return nil
        }
    }
}

@Generable
struct CorrectedLine {
    @Guide(description: "The chat line with only its spelling corrected")
    var corrected: String
}

@Generable
struct SpokenLineAnswer {
    @Guide(description: "The chat line with only its spelling corrected")
    var corrected: String
    @Guide(description: "The sound a listener would make, or none")
    var sound: InterjectionChoice
    @Guide(description: "How naturally a listener would make that sound here: strong when the line clearly calls for it, good when it suits, weak when it barely does, none when no sound belongs")
    var fit: InterjectionFitChoice
}
