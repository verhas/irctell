import Foundation

/// Where Irctell keeps its files: settings and networks as binary property
/// lists, and the message log -- those of the profile it runs with.
enum IrctellHome {
    /// `~/.irctell`, unless IRCTELL_HOME names another directory -- for a
    /// trial run that leaves the real one alone. Unit tests get a fresh
    /// temporary one, so the app they run in does not touch the user's files
    /// or connect to the user's networks. The main profile is kept here, the
    /// others in its `profiles` folder.
    static let root: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["IRCTELL_HOME"], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        if isRunningTests {
            return FileManager.default.temporaryDirectory.appending(path: "irctell-tests-\(UUID().uuidString)")
        }
        return defaultDirectory
    }()

    /// The profile chosen last, read once: switching restarts the app. Nil
    /// for the main one.
    static let profile: String? = Profiles(root: root).current()

    /// The profile's folder: `root` for the main profile.
    static let directory: URL = profile.map { Profiles(root: root).directory(of: $0) } ?? root

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".irctell")

    /// Only the real main profile takes over what earlier versions kept elsewhere.
    static var isDefault: Bool { directory == defaultDirectory }

    /// Passwords go to the keychain from every profile of the real home; a
    /// trial or test home keeps away from the real keychain entries.
    static var usesKeychain: Bool { root == defaultDirectory }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The profile's folder as the user would type it: `~/.irctell/profiles/work`.
    static var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = directory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The profile's name, as menus and the window show it.
    static var profileName: String { profile ?? Profiles.mainName }

    static var settingsFile: URL { directory.appending(path: "settings.plist") }
    static var networksFile: URL { directory.appending(path: "networks.plist") }
    static var logFile: URL { directory.appending(path: "logs.sqlite") }
    /// What every profile uses alike: the downloaded voices.
    static var sharedDirectory: URL { root }
}

/// The profiles of an Irctell home: the main one in the home itself, every
/// other in `profiles/<name>`, laid out just like it.
struct Profiles {
    static let mainName = "Main"

    let root: URL
    /// Deleting: to the Trash, where Finder's Put Back restores it.
    /// Replaceable for tests, which must not fill the user's Trash.
    var discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    var folder: URL { root.appending(path: "profiles", directoryHint: .isDirectory) }
    /// Holds the name of the profile the next launch uses; none for the main one.
    var currentFile: URL { root.appending(path: "current-profile") }

    func directory(of name: String) -> URL {
        folder.appending(path: name, directoryHint: .isDirectory)
    }

    /// The other profiles, by name; the main one is not among them.
    func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The profile chosen; nil for the main one, and for one no longer there.
    func current() -> String? {
        guard let text = try? String(contentsOf: currentFile, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, Profiles.problem(with: name) == nil else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory(of: name).path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return name
    }

    /// Nil for the main profile.
    func choose(_ name: String?) throws {
        guard let name else {
            if FileManager.default.fileExists(atPath: currentFile.path) {
                try FileManager.default.removeItem(at: currentFile)
            }
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((name + "\n").utf8).write(to: currentFile, options: .atomic)
    }

    /// What is wrong with the name as a profile's; nil when nothing.
    static func problem(with name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The name is empty." }
        if name != name.trimmingCharacters(in: .whitespaces) { return "The name starts or ends with a space." }
        if name.hasPrefix(".") { return "The name starts with a dot." }
        if name.contains(where: { "/:\\".contains($0) || $0.isNewline }) { return "The name has / : or \\ in it." }
        if name.count > 64 { return "The name is longer than 64 characters." }
        if name.localizedCaseInsensitiveCompare(mainName) == .orderedSame { return "“\(mainName)” is the main profile." }
        return nil
    }

    /// A new, empty profile's folder.
    @discardableResult
    func create(_ name: String) throws -> URL {
        if let problem = Profiles.problem(with: name) { throw ProfileError(message: problem) }
        if names().contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            throw ProfileError(message: "There is a profile “\(name)” already.")
        }
        let url = directory(of: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Moves the profile to the Trash. Not the one in use: that has its
    /// files open.
    func delete(_ name: String, inUse: String?) throws {
        guard Profiles.problem(with: name) == nil, names().contains(name) else {
            throw ProfileError(message: "There is no profile “\(name)”.")
        }
        guard name != inUse else { throw ProfileError(message: "“\(name)” is the profile in use.") }
        try discard(directory(of: name))
        if current() == nil, FileManager.default.fileExists(atPath: currentFile.path) {
            try choose(nil)
        }
    }
}

struct ProfileError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
