import AVFoundation
import XCTest
@testable import Irctell

final class NickGenderTests: XCTestCase {
    func testGuesses() {
        XCTAssertEqual(NickGender.guess("MissAnna"), .female)
        XCTAssertEqual(NickGender.guess("slave_wife"), .female)
        XCTAssertEqual(NickGender.guess("Domlook4subf"), .female, "an f at the end, though it says dom")
        XCTAssertEqual(NickGender.guess("TexanMaster"), .male)
        XCTAssertEqual(NickGender.guess("Christopher"), .male, "a man, not a woman for the her in it")
        XCTAssertEqual(NickGender.guess("Steve"), .male)
        XCTAssertEqual(NickGender.guess("x7k"), .unknown)
    }
}

@MainActor
final class SpeechTests: XCTestCase {
    private var directory: URL!
    private var settings: SettingsStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        settings = SettingsStore(fileURL: directory.appending(path: "settings.plist"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOnlyEnglishVoicesThatSpeakLikeAPerson() {
        for voice in Voices.english {
            XCTAssertTrue(voice.language.hasPrefix("en"), voice.name)
            XCTAssertFalse(["Whisper", "Organ", "Bells", "Zarvox"].contains(voice.name))
            XCTAssertFalse(voice.voiceTraits.contains(.isNoveltyVoice), voice.name)
        }
    }

    func testEachNickKeepsItsVoice() throws {
        try XCTSkipIf(Voices.english.isEmpty, "no English voice installed")
        let voice = try XCTUnwrap(Voices.voice(for: "Alice", engine: .apple, settings: settings))
        XCTAssertEqual(Voices.voice(for: "ALICE", engine: .apple, settings: settings), voice, "kept")
        XCTAssertNil(Voices.chosen(for: "alice", settings: settings), "given, not chosen")
        if case .apple(let apple) = voice {
            XCTAssertEqual(apple.quality, Voices.bestEnglish.first?.quality, "only the best quality installed")
        }

        let other = try XCTUnwrap(Voices.english.first { VoiceRef.apple($0) != voice })
        Voices.choose(other.identifier, for: "alice", settings: settings)
        XCTAssertEqual(Voices.voice(for: "Alice", engine: .apple, settings: settings), .apple(other), "chosen by hand")
        Voices.choose("kokoro:bf_emma", for: "alice", settings: settings)
        XCTAssertEqual(Voices.voice(for: "Alice", engine: .apple, settings: settings)?.id, "kokoro:bf_emma",
                       "a chosen natural voice, whichever engine is set")
    }

    func testNaturalVoicesByLook() throws {
        let women = Voices.pool(for: .female, engine: .kokoro)
        let men = Voices.pool(for: .male, engine: .kokoro)
        XCTAssertFalse(women.isEmpty)
        XCTAssertTrue(women.allSatisfy { if case .kokoro(let v) = $0 { v.isFemale } else { false } })
        XCTAssertTrue(men.allSatisfy { if case .kokoro(let v) = $0 { !v.isFemale } else { false } })
        XCTAssertFalse(men.contains(.kokoro(Voices.kokoroNarrator)), "the narrator's voice is its own")
        let voice = Voices.voice(for: "MissAnna", engine: .kokoro, settings: settings)
        XCTAssertNotNil(voice.flatMap { women.contains($0) ? $0 : nil })
        XCTAssertEqual(VoiceRef(id: "kokoro:af_heart"), .kokoro(KokoroVoice.named("af_heart")!))
    }

    func testWhoInTheNarratorsVoiceWhatInTheirsWithPausesBeforeKeys() throws {
        let narrator = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let theirs = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-GB"))
        let line = ChatLine(time: .now, kind: .message, sender: "bot",
                            text: "\u{03}04Name:\u{03} Bob \u{03}04Age:\u{03} 30 \u{03}04Site:\u{03} https://example.org/x")
        let parts = try XCTUnwrap(Speaker.parts(of: line, place: "#info", narrator: .apple(narrator)) { _ in .apple(theirs) })
        guard case .apple(let intro) = parts[0], case .apple(let text) = parts[1] else { return XCTFail("Apple parts") }
        XCTAssertEqual(intro.speechString, "bot in #info")
        XCTAssertEqual(intro.voice?.identifier, narrator.identifier)
        XCTAssertEqual(text.voice?.identifier, theirs.identifier)

        let segments = Speaker.speakableSegments(line.text)
        let ssml = Speaker.ssml(segments)
        XCTAssertEqual(ssml.components(separatedBy: "<break").count - 1, 2, "before every key but the first")
        XCTAssertTrue(ssml.hasPrefix("<speak>Name: Bob <break"))
        XCTAssertTrue(ssml.contains("a link to example.org"))
        XCTAssertEqual(Speaker.chunks(segments), ["Name: Bob", "Age: 30", "Site: a link to example.org"])

        let natural = try XCTUnwrap(Speaker.parts(of: line, place: nil, narrator: .kokoro(Voices.kokoroNarrator)) { _ in
            .kokoro(KokoroVoice.named("bf_emma")!)
        })
        guard case .kokoro(_, let introVoice, _) = natural[0], case .kokoro(_, let textVoice, _) = natural[1] else {
            return XCTFail("Kokoro parts")
        }
        XCTAssertEqual(introVoice, Voices.kokoroNarrator)
        XCTAssertEqual(textVoice.name, "bf_emma")
        XCTAssertNil(Speaker.parts(of: ChatLine(time: .now, kind: .message, sender: "x", text: "\u{02}\u{02}"),
                                   place: nil, narrator: nil) { _ in nil })
    }

    func testNicksAreSaidAsNames() {
        XCTAssertEqual(Speaker.spokenNick("Anna{MTB}"), "Anna")
        XCTAssertEqual(Speaker.spokenNick("Bob(G)"), "Bob")
        XCTAssertEqual(Speaker.spokenNick("[Anna]{MTB}"), "Anna")
        XCTAssertEqual(Speaker.spokenNick("^_Texan_Master_^"), "Texan Master")
        XCTAssertEqual(Speaker.spokenNick("peter|away"), "peter")
        XCTAssertEqual(Speaker.spokenNick("Kate[work]"), "Kate")
        XCTAssertEqual(Speaker.spokenNick("joe23"), "joe23")
        XCTAssertEqual(Speaker.spokenNick("^^"), "^^")
        let line = ChatLine(time: .now, kind: .message, sender: "{x}Anna(G)", text: "hi")
        guard case .apple(let intro)? = Speaker.parts(of: line, place: "#c", narrator: nil, voiceFor: { _ in nil })?.first
        else { return XCTFail("Apple parts") }
        XCTAssertEqual(intro.speechString, "Anna in #c")
    }

    func testLaughsAndFacesAreFound() {
        func sounds(_ text: String) -> [Reaction] { Reaction.pieces(of: text).compactMap(\.reaction) }
        XCTAssertEqual(sounds("rotfl that was good"), [.bigLaugh])
        XCTAssertEqual(sounds("LOL"), [.laugh])
        XCTAssertEqual(sounds("lolol hahaha :D"), [.laugh], "the same twice in a row is heard once")
        XCTAssertEqual(sounds("nice :) see you :-("), [.giggle, .sad])
        XCTAssertEqual(sounds("sure ;)"), [.giggle])
        XCTAssertEqual(sounds("oh no :'("), [.sad])
        XCTAssertEqual(sounds("🤣"), [.bigLaugh])
        XCTAssertEqual(sounds("great 🙂."), [.giggle])
        XCTAssertEqual(sounds("lolly and hello, see http://x.org/a:(b) and f(x)"), [], "not inside words or links")
        XCTAssertEqual(Reaction.pieces(of: "well lol, ok"), [.text("well "), .sound(.laugh, "lol"), .text(", ok")])
        XCTAssertEqual(Reaction.pieces(of: ":)"), [.sound(.giggle, ":)")])
    }

    func testLaughsAreHeardNotRead() throws {
        let laugh = URL(filePath: "/tmp/laugh.m4a")
        let line = ChatLine(time: .now, kind: .message, sender: "bob", text: "that was funny lol")
        let parts = try XCTUnwrap(Speaker.parts(of: line, place: nil, narrator: nil, voiceFor: { _ in nil },
                                                soundFor: { $0 == .laugh ? laugh : nil }))
        XCTAssertEqual(parts.count, 3, "who, the text, the laugh")
        guard case .apple(let text) = parts[1], case .sound(let url, _) = parts[2] else { return XCTFail("parts") }
        XCTAssertEqual(text.speechString.trimmingCharacters(in: .whitespaces), "that was funny")
        XCTAssertEqual(url, laugh)

        let alone = ChatLine(time: .now, kind: .message, sender: "bob", text: ":(")
        let unheard = try XCTUnwrap(Speaker.parts(of: alone, place: nil, narrator: nil, voiceFor: { _ in nil }))
        guard case .apple(let face) = unheard[1] else { return XCTFail("without a sound the face is read") }
        XCTAssertEqual(face.speechString, ":(")
    }

    func testAbbreviationsAreSaidInFull() {
        let list = Abbreviations.samples
        XCTAssertEqual(Abbreviations.expand("WTF is this, brb", with: list), "what the fuck is this, be right back")
        XCTAssertEqual(Abbreviations.expand("tl;dr: w/o it, idk", with: list),
                       "too long, didn't read: without it, I don't know")
        XCTAssertEqual(Abbreviations.expand("brbx, abrb, the U.S. and u.s.a", with: list), "brbx, abrb, the U.S. and u.s.a",
                       "only whole words")
        XCTAssertEqual(Abbreviations.expand("u r late", with: list), "you are late")
        XCTAssertEqual(Abbreviations.expand("lmfao", with: list + [Abbreviation(short: "lmfao", spoken: "big laugh")]),
                       "big laugh", "the longest that fits")
        XCTAssertEqual(Abbreviations.expand("anything", with: []), "anything")

        let line = ChatLine(time: .now, kind: .message, sender: "bob", text: "omg lol")
        let laugh = URL(filePath: "/tmp/laugh.m4a")
        let parts = Speaker.parts(of: line, place: nil, announcing: false, narrator: nil, voiceFor: { _ in nil },
                                  soundFor: { $0 == .laugh ? laugh : nil },
                                  expand: { Abbreviations.expand($0, with: list) })
        guard case .apple(let text)? = parts?.first, case .sound? = parts?.last else { return XCTFail("parts") }
        XCTAssertEqual(text.speechString.trimmingCharacters(in: .whitespaces), "oh my god", "lol is the laugh's")
    }

    func testDotsArePauses() {
        XCTAssertEqual(Speaker.pausedPieces("well... I guess … so"), ["well", "I guess", "so"])
        XCTAssertEqual(Speaker.pausedPieces("no pause. here"), ["no pause. here"])
        XCTAssertTrue(Speaker.ssml([("hmm... ok", false)]).contains(#"hmm <break time="500ms"/> ok"#))
    }

    func testALineGoingOnIsNotAnnouncedAgain() {
        let channel = UUID(), other = UUID(), start = Date.now
        let said = Speaker.Said(buffer: channel, sender: "bob", time: start)
        func line(_ sender: String, after seconds: TimeInterval) -> ChatLine {
            ChatLine(time: start.addingTimeInterval(seconds), kind: .message, sender: sender, text: "more")
        }
        XCTAssertTrue(Speaker.continues(said, line: line("Bob", after: 5), buffer: channel))
        XCTAssertFalse(Speaker.continues(said, line: line("bob", after: 5), buffer: other), "another conversation")
        XCTAssertFalse(Speaker.continues(said, line: line("alice", after: 5), buffer: channel), "someone else")
        XCTAssertFalse(Speaker.continues(said, line: line("bob", after: 600), buffer: channel), "much later")
        XCTAssertFalse(Speaker.continues(nil, line: line("bob", after: 5), buffer: channel))
    }
}

@MainActor
final class PeopleTests: XCTestCase {
    func testGroupsOfNicks() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(fileURL: directory.appending(path: "settings.plist"))
        XCTAssertEqual(People.aliases(of: "Bob", settings: settings), ["bob"])

        People.setAliases(["Bob_away", "robert"], of: "Bob", settings: settings)
        XCTAssertEqual(People.aliases(of: "ROBERT", settings: settings), ["bob", "bob_away", "robert"], "from any of them")

        People.setAliases(["robert"], of: "carol", settings: settings)
        XCTAssertEqual(People.aliases(of: "bob", settings: settings), ["bob", "bob_away"], "a nick is one person's")
        XCTAssertEqual(People.aliases(of: "carol", settings: settings), ["carol", "robert"])

        People.setAliases([], of: "bob", settings: settings)
        XCTAssertEqual(People.aliases(of: "bob_away", settings: settings), ["bob_away"])
    }
}

@MainActor
final class ReplySuggesterTests: XCTestCase {
    func testTheAnswerIsCleanedAndTheLanguageTold() {
        XCTAssertEqual(ReplySuggester.cleaned("\"sure, why not\"\nAnd another line", me: "peter"), "sure, why not")
        XCTAssertEqual(ReplySuggester.cleaned("<peter> on my way", me: "peter"), "on my way")
        XCTAssertEqual(ReplySuggester.cleaned("Peter: „igen”", me: "peter"), "„igen”")
        XCTAssertNil(ReplySuggester.cleaned("  \n", me: "peter"))
        func said(_ text: String) -> ChatLine { ChatLine(time: .now, kind: .message, sender: "x", text: text) }
        XCTAssertEqual(ReplySuggester.language(of: [said("szia, láttad a tegnapi meccset? szerintem a bíró elrontotta")]),
                       "Hungarian")
        XCTAssertEqual(ReplySuggester.language(of: [said("hat jemand eine Ahnung, warum mein Build so langsam ist?")]),
                       "German")
        XCTAssertEqual(ReplySuggester.transcriptLine(
            ChatLine(time: .now, kind: .action, sender: "amy", text: "\u{02}waves\u{02}")), "* amy waves")
    }
}

@MainActor
final class CommaPauseTests: XCTestCase {
    func testACommaIsAPauseButNotInANumber() {
        XCTAssertEqual(Speaker.commaPieces("Hello, how are you, Bob?"), ["Hello,", "how are you,", "Bob?"])
        XCTAssertEqual(Speaker.commaPieces("ok,so what"), ["ok,", "so what"], "without a space too")
        XCTAssertEqual(Speaker.commaPieces("1,000 apples, please"), ["1,000 apples,", "please"])
        XCTAssertEqual(Speaker.commaPieces("no comma here"), ["no comma here"])
        XCTAssertEqual(Speaker.commaPieces("trailing,"), ["trailing,"])

        let ssml = Speaker.ssml([("Hello, 1,000 friends", false)])
        XCTAssertEqual(ssml, #"<speak>Hello, <break time="250ms"/>  1,000 friends</speak>"#)
        XCTAssertNotNil(AVSpeechUtterance(ssmlRepresentation: ssml), "Apple's voices take it")
    }
}

@MainActor
final class InterjectionTests: XCTestCase {
    private func duration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func testEverySoundIsThereAndShort() throws {
        for interjection in Interjection.allCases {
            let sounds = interjection.sounds
            XCTAssertFalse(sounds.isEmpty, "\(interjection) has sounds")
            for url in sounds {
                let seconds = try duration(url)
                XCTAssertGreaterThanOrEqual(seconds, 0.2, url.lastPathComponent)
                XCTAssertLessThanOrEqual(seconds, 0.55, url.lastPathComponent)
            }
        }
        for reaction in Reaction.allCases {
            for url in reaction.sounds {
                XCTAssertLessThanOrEqual(try duration(url), 0.45, "\(url.lastPathComponent): short now")
            }
        }
    }

    func testHowOftenIsRandomWithinTheChance() {
        XCTAssertEqual(Interjection.plan(before: 0, after: 0).before, false)
        for _ in 0..<50 {
            let always = Interjection.plan(before: 100, after: 100)
            XCTAssertTrue(always.before && always.after)
            XCTAssertFalse(Interjection.plan(before: 0, after: 0).after)
        }
        var rolls = [0.2, 0.7].makeIterator()
        let plan = Interjection.plan(before: 50, after: 50) { rolls.next()! }
        XCTAssertTrue(plan.before, "0.2 is within 50%")
        XCTAssertFalse(plan.after, "0.7 is not: before and after decided apart")

        let many = (0..<2_000).filter { _ in Interjection.plan(before: 50, after: 0).before }.count
        XCTAssertGreaterThan(many, 850)
        XCTAssertLessThan(many, 1_150, "about half, at random")
    }

    func testTheRulesWhenThereIsNoModel() {
        XCTAssertTrue([.aww, .sigh].contains(Interjection.byRules("I'm so sorry, my cat died").interjection))
        XCTAssertTrue([.hmm, .huh].contains(Interjection.byRules("are you sure about that?").interjection))
        XCTAssertEqual(Interjection.byRules("ouch, that must hurt"), InterjectionPick(.ouch, fit: .good))
        XCTAssertTrue([.wow, .ooh].contains(Interjection.byRules("that is amazing!!").interjection))
        XCTAssertEqual(Interjection.byRules("the build is at noon").fit, .weak, "only a guess")
    }

    func testHowWellItFitsBendsTheChance() {
        XCTAssertEqual(InterjectionFit.strong.chance(50), 0.707, accuracy: 0.001, "more likely")
        XCTAssertEqual(InterjectionFit.good.chance(50), 0.5, accuracy: 0.001, "as set")
        XCTAssertEqual(InterjectionFit.weak.chance(50), 0.25, accuracy: 0.001, "less likely")
        XCTAssertEqual(InterjectionFit.none.chance(50), 0, "never")
        for fit in [InterjectionFit.weak, .good, .strong] {
            XCTAssertEqual(fit.chance(100), 1, "Always stays always")
            XCTAssertEqual(fit.chance(0), 0, "Never stays never")
        }
        XCTAssertEqual(InterjectionFit.none.chance(100), 0, "no sound fits: none, even at Always")
        XCTAssertEqual(InterjectionPick(nil, fit: .strong).fit, .none, "no sound has no fit")

        let strong = (0..<2_000).filter { _ in Interjection.plan(before: 50, after: 0, fit: .strong).before }.count
        let weak = (0..<2_000).filter { _ in Interjection.plan(before: 50, after: 0, fit: .weak).before }.count
        XCTAssertGreaterThan(strong, 1_300)
        XCTAssertLessThan(weak, 650)
    }

    /// The real model, from inside the app; run by hand with
    /// TEST_RUNNER_IRCTELL_REAL_MODEL=1.
    func testTheModelPicksASound() async throws {
        guard ProcessInfo.processInfo.environment["IRCTELL_REAL_MODEL"] != nil else {
            throw XCTSkip("set IRCTELL_REAL_MODEL to try the model")
        }
        for line in ["my exam went terribly, I failed", "look, I finally finished the marathon!", "what do you mean by that?",
                     "the server crashed at 3am and nobody noticed", "I'm getting married next month!",
                     "brb, coffee", "my landlord raised the rent again", "check out this cat video",
                     "ok", "the new release is tagged v2.3", "anyone here use vim?"] {
            let start = ContinuousClock.now
            let picked = await InterjectionChooser.askModel(line)
            print("TIME \(ContinuousClock.now - start)")
            print("INTERJECTION \(line) -> \(picked?.interjection?.rawValue ?? "none"), \(picked?.fit.rawValue ?? "no answer")")
            XCTAssertNotNil(picked, "an answer")
        }
    }
}

@MainActor
final class SpellingTests: XCTestCase {
    func testOnlySmallCorrectionsAreTaken() {
        XCTAssertEqual(LinePreparer.distance("kitten", "sitting"), 3)
        XCTAssertEqual(LinePreparer.accepted("my dog died yesterday", for: "my dgo died yesterdy"),
                       "my dog died yesterday", "typos fixed")
        XCTAssertEqual(LinePreparer.accepted("I am sorry to hear that your dog passed away", for: "my dgo died"),
                       "my dgo died", "rewritten, not corrected: the line as written")
        XCTAssertEqual(LinePreparer.accepted("", for: "teh"), "teh")
        XCTAssertEqual(LinePreparer.accepted("Completely different words here", for: "the build is broken"),
                       "the build is broken")
        XCTAssertFalse(LinePreparer.isWorthCorrecting(":)"))
        XCTAssertFalse(LinePreparer.isWorthCorrecting("https://example.org/teh"))
        XCTAssertTrue(LinePreparer.isWorthCorrecting("teh cat"))
    }

    /// The real model, from inside the app; run by hand with
    /// TEST_RUNNER_IRCTELL_REAL_MODEL=1.
    func testTheModelCorrectsSpelling() async throws {
        guard ProcessInfo.processInfo.environment["IRCTELL_REAL_MODEL"] != nil else {
            throw XCTSkip("set IRCTELL_REAL_MODEL to try the model")
        }
        for line in ["teh build is borken agian lol", "my dgo died yesterdy", "brb, cofee",
                     "anyone knwo how to configre nginx?", "this is already correct", "wow thats amazng!!"] {
            for sound in [false, true] {
                let start = ContinuousClock.now
                let prepared = await LinePreparer.prepare(line, correct: true, pickSound: sound, intelligence: true)
                let took = ContinuousClock.now - start
                print("SPELL \(sound ? "+sound" : "      ") \(took) | \(line) -> \(prepared.text)"
                      + (sound ? " [\(prepared.pick?.interjection?.rawValue ?? "none"), \(prepared.pick?.fit.rawValue ?? "-")]" : ""))
            }
        }
    }
}
