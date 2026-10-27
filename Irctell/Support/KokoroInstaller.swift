import CryptoKit
import Foundation
import Observation

/// Downloads Kokoro's model into Irctell's home, checks it is the release it
/// should be, and unpacks it; or removes it again.
@MainActor @Observable
final class KokoroInstaller {
    static let shared = KokoroInstaller()

    enum State: Equatable {
        case idle
        /// From 0 to 1.
        case downloading(Double)
        case unpacking
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var isInstalled = KokoroEngine.isInstalled

    var isBusy: Bool {
        switch state {
        case .downloading, .unpacking: true
        default: false
        }
    }

    func install() async {
        guard !isBusy, !KokoroEngine.isInstalled else { return }
        state = .downloading(0)
        do {
            let archive = try await download()
            defer { try? FileManager.default.removeItem(at: archive) }
            state = .unpacking
            try await Task.detached { try KokoroInstaller.verifyAndUnpack(archive) }.value
            isInstalled = KokoroEngine.isInstalled
            state = isInstalled ? .idle : .failed("The download did not hold the model.")
            Speaker.shared.reloadKokoro()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: KokoroEngine.modelDirectory)
        isInstalled = KokoroEngine.isInstalled
        Speaker.shared.reloadKokoro()
    }

    private func download() async throws -> URL {
        let delegate = DownloadDelegate { [weak self] fraction in
            Task { @MainActor in
                if case .downloading = self?.state { self?.state = .downloading(fraction) }
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: KokoroEngine.modelURL).resume()
        }
    }

    /// Off the main thread: the archive is hundreds of megabytes.
    nonisolated private static func verifyAndUnpack(_ archive: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == KokoroEngine.modelSHA256 else { throw InstallError.checksum }

        let voices = KokoroEngine.modelDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["xjf", archive.path, "-C", voices.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw InstallError.unpack }
    }

    enum InstallError: LocalizedError {
        case checksum, unpack

        var errorDescription: String? {
            switch self {
            case .checksum: "The download is not the expected model: it may have been damaged on the way."
            case .unpack: "The model could not be unpacked."
            }
        }
    }
}

/// Reports a download's progress, and hands over the file before URLSession
/// deletes it.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite
            : Int64(KokoroEngine.downloadMegabytes) << 20
        progress(min(Double(totalBytesWritten) / Double(expected), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let kept = FileManager.default.temporaryDirectory.appending(path: "irctell-kokoro-\(UUID().uuidString).tar.bz2")
        do {
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
