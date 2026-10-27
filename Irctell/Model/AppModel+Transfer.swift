import Foundation

/// Export and import of the log and the settings, for backups and moving to
/// another Mac.
extension AppModel {
    /// Where the user's own sounds are.
    static var soundsDirectory: URL { IrctellHome.directory.appending(path: "sounds") }

    /// What an export of these parts needs, read here on the main actor; the
    /// writing is done off it.
    func exportInput(parts: Set<ArchivePart>) -> LogArchive.ExportInput {
        var input = LogArchive.ExportInput(logPath: log?.fileURL.path, parts: parts)
        input.networkNames = Dictionary(networks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        input.networkHosts = Dictionary(networks.map { ($0.id, $0.host) }, uniquingKeysWith: { first, _ in first })
        if parts.contains(.networks) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            input.networks = try? encoder.encode(networks)
            input.networkCount = networks.count
        }
        for (part, values) in settingsByPart() where parts.contains(part) {
            input.settings[part] = try? PropertyListSerialization.data(fromPropertyList: values, format: .xml,
                                                                         options: 0)
            input.settingsCounts[part] = values.count
        }
        input.soundsDirectory = AppModel.soundsDirectory
        return input
    }

    /// The settings, split into the parts of an archive.
    func settingsByPart() -> [ArchivePart: [String: Any]] {
        var parts: [ArchivePart: [String: Any]] = [:]
        for (key, value) in settings.allValues {
            guard let part = ArchivePart.part(forSetting: key) else { continue }
            parts[part, default: [:]][key] = value
        }
        return parts
    }

    /// How many sound files the user added.
    static func soundFileCount() -> Int {
        guard let files = FileManager.default.enumerator(at: soundsDirectory, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return 0 }
        return files.reduce(0) { count, item in
            (try? (item as? URL)?.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? count + 1 : count
        }
    }

    /// Takes the chosen parts of an unpacked archive. Networks are matched
    /// by ID, then by server; the ones not here are added when chosen or
    /// when imported messages came on them. Settings replace the ones of
    /// their part; messages and pictures are added to the log, skipping
    /// what is there already.
    func importArchive(_ archive: LogArchive.Unpacked, parts: Set<ArchivePart>,
                       progress: @escaping @Sendable (String) -> Void) async throws -> ArchiveImportResult {
        var result = ArchiveImportResult()
        let mapping = importNetworks(archive, parts: parts, result: &result)

        for part in ArchivePart.settingsParts where parts.contains(part) {
            guard let values = archive.settings(part) else { continue }
            for (key, value) in values where ArchivePart.part(forSetting: key) == part {
                settings.set(AppModel.replacingIDs(in: value, mapping), forKey: key)
                result.settingsImported += 1
            }
        }

        if parts.contains(.sounds) {
            result.soundsAdded = AppModel.importSounds(from: archive.soundsDirectory)
        }

        let messages = parts.contains(.messages), pictures = parts.contains(.pictures)
        if let log, messages || pictures {
            let path = log.fileURL.path
            let buffers = sessions.flatMap(\.buffers)
            let keep = Set(buffers.compactMap(\.clearedUpTo) + buffers.flatMap { $0.lines.compactMap(\.logID) })
            log.holdWrites()
            let merged: ArchiveImportResult
            do {
                merged = try await Task.detached(priority: .userInitiated) {
                    try LogArchive.importLog(from: archive, into: path, messages: messages, pictures: pictures,
                                             networkIDs: mapping, keep: keep, progress: progress)
                }.value
            } catch {
                log.resumeWrites()
                throw error
            }
            for buffer in buffers { buffer.renumberLogRows(merged.renumbered) }
            log.resumeWrites()
            result.linesAdded = merged.linesAdded
            result.linesAlreadyThere = merged.linesAlreadyThere
            result.picturesAdded = merged.picturesAdded
            result.renumbered = merged.renumbered
        }
        return result
    }

    /// The archive's network IDs, mapped to the ones on this Mac; adds the
    /// missing networks that are wanted.
    private func importNetworks(_ archive: LogArchive.Unpacked, parts: Set<ArchivePart>,
                                result: inout ArchiveImportResult) -> [UUID: UUID] {
        var mapping: [UUID: UUID] = [:]
        let withMessages = parts.contains(.messages) ? Set(archive.conversations.map(\.networkID)) : []
        func match(id: UUID, host: String?, name: String) -> UUID? {
            if network(id) != nil { return id }
            if let host, !host.isEmpty,
               let found = networks.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) {
                return found.id
            }
            return networks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        for network in archive.networks {
            if let found = match(id: network.id, host: network.host, name: network.name) {
                mapping[network.id] = found
            } else if parts.contains(.networks) || withMessages.contains(network.id) {
                var added = network
                added.serverPassword = ""
                added.saslPassword = ""
                added.proxyPassword = ""
                save(added)
                mapping[network.id] = network.id
                result.networksAdded.append(network.name)
            }
        }
        // Messages from networks the archive has no list of: by server.
        for conversation in archive.conversations where mapping[conversation.networkID] == nil {
            if let found = match(id: conversation.networkID, host: conversation.host, name: conversation.network) {
                mapping[conversation.networkID] = found
            } else if let host = conversation.host, !host.isEmpty {
                var added = NetworkConfig(name: conversation.network, host: host)
                added.id = conversation.networkID
                added.connectAtLaunch = false
                save(added)
                mapping[conversation.networkID] = added.id
                result.networksAdded.append(added.name)
            }
        }
        return mapping
    }

    /// The setting with the archive's network IDs, in keys and values,
    /// replaced by the ones they are on this Mac.
    static func replacingIDs(in value: Any, _ mapping: [UUID: UUID]) -> Any {
        let changes = Dictionary(mapping.compactMap { old, new in
            old == new ? nil : (old.uuidString.uppercased(), new.uuidString)
        }, uniquingKeysWith: { first, _ in first })
        guard !changes.isEmpty else { return value }
        func replace(_ value: Any) -> Any {
            switch value {
            case let text as String: changes[text.uppercased()] ?? text
            case let dictionary as [String: Any]:
                Dictionary(dictionary.map { (changes[$0.key.uppercased()] ?? $0.key, replace($0.value)) },
                           uniquingKeysWith: { first, _ in first })
            case let array as [Any]: array.map(replace)
            default: value
            }
        }
        return replace(value)
    }

    /// Copies the sounds in, leaving the ones already here; a different
    /// sound under a name taken gets a name of its own. Returns how many.
    static func importSounds(from source: URL) -> Int {
        let manager = FileManager.default
        guard let files = manager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        let base = source.standardizedFileURL.path
        var added = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
            guard !relative.split(separator: "/").contains("..") else { continue }
            var target = soundsDirectory.appending(path: relative)
            if manager.fileExists(atPath: target.path) {
                if manager.contentsEqual(atPath: target.path, andPath: file.path) { continue }
                let stem = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
                var counter = 2
                repeat {
                    target = target.deletingLastPathComponent().appending(path: "\(stem) \(counter).\(ext)")
                    counter += 1
                } while manager.fileExists(atPath: target.path)
            }
            do {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: file, to: target)
                added += 1
            } catch {
                AppLog.error("transfer", "could not import the sound \(relative): \(error)")
            }
        }
        return added
    }
}
