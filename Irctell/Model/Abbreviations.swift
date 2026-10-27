import Foundation

/// An abbreviation, and how it is said when a message is read aloud: "wtf"
/// is "what the fuck", not "W T F".
struct Abbreviation: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var short: String
    var spoken: String
}

/// The abbreviations read out in full: the user's, or until they have any,
/// the ones IRC usually uses.
@MainActor
final class Abbreviations {
    static let shared = Abbreviations()

    static let key = "speech.abbreviations"

    private let settings: SettingsStore
    private var compiled: (list: [Abbreviation], expression: NSRegularExpression?, spoken: [String: String])?

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    var list: [Abbreviation] {
        get {
            guard let object = settings.object(forKey: Abbreviations.key),
                  let list = SettingsStore.decode([Abbreviation].self, from: object) else {
                return Abbreviations.samples
            }
            return list
        }
        set { settings.set(SettingsStore.plistObject(newValue), forKey: Abbreviations.key) }
    }

    /// The text with every abbreviation in it written out, ignoring case.
    /// Only whole words count: "brb" is one, "brbx" and "u.s." are not.
    func expand(_ text: String) -> String {
        Abbreviations.expand(text, with: list, cache: &compiled)
    }

    static func expand(_ text: String, with list: [Abbreviation]) -> String {
        var cache: (list: [Abbreviation], expression: NSRegularExpression?, spoken: [String: String])?
        return expand(text, with: list, cache: &cache)
    }

    private static func expand(_ text: String, with list: [Abbreviation],
                               cache: inout (list: [Abbreviation], expression: NSRegularExpression?,
                                             spoken: [String: String])?) -> String {
        if cache?.list != list {
            let usable = list.filter { !$0.short.trimmingCharacters(in: .whitespaces).isEmpty }
            // Longest first, so "lmfao" is not taken for "lmao" and more.
            let alternatives = usable.map { NSRegularExpression.escapedPattern(for: $0.short.trimmingCharacters(in: .whitespaces)) }
                .sorted { $0.count > $1.count }
            let pattern = #"(?<![\w'])(?<!\w[./])("# + alternatives.joined(separator: "|") + #")(?![\w'])(?![./]\w)"#
            let spoken = Dictionary(usable.map { ($0.short.trimmingCharacters(in: .whitespaces).lowercased(), $0.spoken) },
                                    uniquingKeysWith: { first, _ in first })
            cache = (list, alternatives.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                     spoken)
        }
        guard let expression = cache?.expression, let spoken = cache?.spoken else { return text }
        let ns = text as NSString
        var result = ""
        var position = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: position, length: match.range.location - position))
            let found = ns.substring(with: match.range)
            result += spoken[found.lowercased()] ?? found
            position = NSMaxRange(match.range)
        }
        return result + ns.substring(from: position)
    }

    /// What the list starts with; also brought back with Restore Samples.
    static let samples: [Abbreviation] = [
        ("wtf", "what the fuck"), ("wth", "what the hell"), ("omg", "oh my god"), ("omfg", "oh my fucking god"),
        ("ffs", "for fuck's sake"), ("stfu", "shut the fuck up"), ("fml", "fuck my life"),
        ("afk", "away from keyboard"), ("brb", "be right back"), ("bbl", "be back later"), ("bbs", "be back soon"),
        ("bbiab", "be back in a bit"), ("gtg", "got to go"), ("g2g", "got to go"), ("ttyl", "talk to you later"),
        ("cya", "see you"), ("cu", "see you"), ("gn", "good night"), ("gm", "good morning"), ("wb", "welcome back"),
        ("btw", "by the way"), ("imo", "in my opinion"), ("imho", "in my humble opinion"),
        ("iirc", "if I recall correctly"), ("afaik", "as far as I know"), ("afaict", "as far as I can tell"),
        ("fwiw", "for what it's worth"), ("fyi", "for your information"), ("iow", "in other words"),
        ("otoh", "on the other hand"), ("tbh", "to be honest"), ("tbf", "to be fair"), ("idk", "I don't know"),
        ("idc", "I don't care"), ("ikr", "I know, right"), ("irl", "in real life"), ("jk", "just kidding"),
        ("nvm", "never mind"), ("np", "no problem"), ("yw", "you're welcome"), ("ty", "thank you"),
        ("tyvm", "thank you very much"), ("thx", "thanks"), ("tia", "thanks in advance"), ("pls", "please"),
        ("plz", "please"), ("sry", "sorry"), ("srsly", "seriously"), ("smh", "shaking my head"),
        ("lmk", "let me know"), ("hth", "hope this helps"), ("ymmv", "your mileage may vary"),
        ("wfm", "works for me"), ("rtfm", "read the fucking manual"), ("tl;dr", "too long, didn't read"),
        ("tldr", "too long, didn't read"), ("ianal", "I am not a lawyer"), ("eta", "estimated time of arrival"),
        ("asap", "as soon as possible"), ("aka", "also known as"), ("gg", "good game"), ("gl", "good luck"),
        ("hf", "have fun"), ("ppl", "people"), ("msg", "message"), ("w/", "with"), ("w/o", "without"),
        ("b/c", "because"), ("bc", "because"), ("u", "you"), ("ur", "your"), ("r", "are"),
        ("lol", "laughing out loud"), ("lmao", "laughing my ass off"), ("rofl", "rolling on the floor laughing"),
        ("rotfl", "rolling on the floor laughing"),
    ].map { Abbreviation(short: $0.0, spoken: $0.1) }
}
