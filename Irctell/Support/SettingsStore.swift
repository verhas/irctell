import Foundation
import Observation
import SwiftUI

/// The settings and remembered state, as one binary property list, written
/// on every change.
@MainActor @Observable
final class SettingsStore {
    static let shared = SettingsStore(fileURL: IrctellHome.settingsFile,
                                      migratingFrom: IrctellHome.isDefault ? .standard : nil)

    @ObservationIgnored let fileURL: URL
    private var values: [String: Any]

    /// Keys earlier versions kept in the app's user defaults.
    private static let legacyKeys = [
        "identity.nick", "identity.alternateNicks", "identity.username", "identity.realName",
        "openNetworks", "openBuffers", "addedKnownNetworks", "showsMemberList",
    ]

    /// Reads the file; when there is none yet, takes over what `legacy`
    /// holds, once.
    init(fileURL: URL, migratingFrom legacy: UserDefaults? = nil) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            values = stored
        } else {
            values = [:]
            if let legacy {
                for key in SettingsStore.legacyKeys {
                    if let value = legacy.object(forKey: key) { values[key] = value }
                }
                if !values.isEmpty { save() }
            }
        }
    }

    func object(forKey key: String) -> Any? { values[key] }
    /// Every setting, for export.
    var allValues: [String: Any] { values }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func bool(forKey key: String, default fallback: Bool = false) -> Bool { values[key] as? Bool ?? fallback }

    /// Takes property list values only; nil removes the key.
    func set(_ value: Any?, forKey key: String) {
        values[key] = value
        save()
    }

    func binding(_ key: String, default fallback: String = "") -> Binding<String> {
        Binding(get: { self.string(forKey: key) ?? fallback }, set: { self.set($0, forKey: key) })
    }

    func binding(_ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { self.bool(forKey: key, default: fallback) }, set: { self.set($0, forKey: key) })
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.error("settings", "could not save settings: \(error)")
        }
    }

    // MARK: - Codable values, stored as property list objects

    /// A Codable value as dictionaries and arrays, so it stays readable with
    /// `plutil -p` rather than being an opaque blob.
    static func plistObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? PropertyListEncoder().encode(value) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: Any) -> T? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }
}
