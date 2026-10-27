import Foundation

/// Nicks the user says are one person's. Only reading the log goes by it: a
/// private chat shows the chats with all of them. The log keeps each nick's
/// lines apart.
@MainActor
enum People {
    /// Groups of lowercased nicks.
    static let key = "people"

    private static func groups(_ settings: SettingsStore) -> [[String]] {
        settings.object(forKey: key) as? [[String]] ?? []
    }

    /// The nick and the others of the same person, lowercased and sorted.
    static func aliases(of nick: String, settings: SettingsStore = .shared) -> [String] {
        let lowered = nick.lowercased()
        let group = groups(settings).first { $0.contains(lowered) } ?? [lowered]
        return group.sorted()
    }

    /// Makes these nicks, and only these, the nick's others. A nick is one
    /// person's only: it leaves any group it was in.
    static func setAliases(_ others: Set<String>, of nick: String, settings: SettingsStore = .shared) {
        let lowered = nick.lowercased()
        let members = Set(others.map { $0.lowercased() }).union([lowered])
        var all = groups(settings).map { $0.filter { !members.contains($0) } }.filter { $0.count > 1 }
        if members.count > 1 { all.append(members.sorted()) }
        settings.set(all, forKey: key)
    }
}
