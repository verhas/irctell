import Compression
import Foundation
import zlib

/// Zip archives, written and read in the process: deflate from the
/// Compression framework -- its "zlib" is raw deflate, as zip has it -- and
/// zlib's CRC-32. Enough for Irctell's own archives and ordinary zips: no
/// encryption, no Zip64, so up to 4 GB and 65,535 files.
enum Zip {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func crc32(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return crc }
        return UInt32(zlib.crc32(uLong(crc), base.assumingMemoryBound(to: Bytef.self), uInt(bytes.count)))
    }
}

/// Writes a zip file entry by entry, each streamed through deflate: a large
/// file never has to be in memory, nor uncompressed on disk.
final class ZipWriter {
    private struct Entry {
        var name: [UInt8]
        var crc: UInt32 = 0
        var compressed = 0
        var size = 0
        var offset: Int
        var time: UInt16
        var date: UInt16
    }

    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var written = 0
    private var entries: [Entry] = []
    private var current: Entry?
    private var deflater: OutputFilter?
    private var finished = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(1 << 20)
    }

    deinit {
        try? handle.close()
    }

    /// Starts an entry; `name` is its path in the archive, with slashes.
    func begin(_ name: String) throws {
        if current != nil { try end() }
        let (time, date) = ZipWriter.dosTime(.now)
        let entry = Entry(name: Array(name.utf8), offset: written, time: time, date: date)
        // Sizes and checksum follow the data, in a descriptor (flag 3); the
        // name is UTF-8 (flag 11).
        append32(0x0403_4B50)
        append16(20); append16(0x0808); append16(8)
        append16(time); append16(date)
        append32(0); append32(0); append32(0)
        append16(UInt16(entry.name.count)); append16(0)
        append(entry.name)
        current = entry
        deflater = try OutputFilter(.compress, using: .zlib) { [unowned self] data in
            guard let data else { return }
            self.current?.compressed += data.count
            data.withUnsafeBytes { self.append($0) }
        }
    }

    func write(_ data: Data) throws {
        guard current != nil, let deflater else { throw Zip.Failure(message: "no zip entry begun") }
        let crc = data.withUnsafeBytes { Zip.crc32(current?.crc ?? 0, $0) }
        current?.crc = crc
        current?.size += data.count
        try deflater.write(data)
        try flushIfFull()
    }

    func write(_ bytes: [UInt8]) throws {
        try write(Data(bytes))
    }

    /// A whole entry at once.
    func add(_ name: String, data: Data) throws {
        try begin(name)
        try write(data)
        try end()
    }

    /// A file from disk, read and compressed a piece at a time.
    func add(_ name: String, contentsOf url: URL) throws {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        try begin(name)
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try write(chunk)
        }
        try end()
    }

    func end() throws {
        guard let deflater else { return }
        try deflater.finalize()
        self.deflater = nil
        guard let entry = current else { return }
        current = nil
        append32(0x0807_4B50)
        append32(entry.crc)
        try append32(Self.fits(entry.compressed)); try append32(Self.fits(entry.size))
        entries.append(entry)
        try flushIfFull()
    }

    /// The central directory, and the file closed.
    func finish() throws {
        guard !finished else { return }
        try end()
        finished = true
        guard entries.count < 0xFFFF else { throw Zip.Failure(message: "Too many files for a zip archive") }
        let start = written
        for entry in entries {
            append32(0x0201_4B50)
            append16(0x0314) // made on Unix, version 2.0
            append16(20); append16(0x0808); append16(8)
            append16(entry.time); append16(entry.date)
            append32(entry.crc)
            try append32(Self.fits(entry.compressed)); try append32(Self.fits(entry.size))
            append16(UInt16(entry.name.count)); append16(0); append16(0)
            append16(0); append16(0)
            append32(0o100644 << 16) // a plain file, rw-r--r--
            try append32(Self.fits(entry.offset))
            append(entry.name)
        }
        let size = written - start
        append32(0x0605_4B50)
        append16(0); append16(0)
        append16(UInt16(entries.count)); append16(UInt16(entries.count))
        try append32(Self.fits(size)); try append32(Self.fits(start))
        append16(0)
        try flush()
        try handle.close()
    }

    // MARK: - Bytes

    private static func fits(_ value: Int) throws -> UInt32 {
        guard value < 0xFFFF_FFFF else { throw Zip.Failure(message: "The archive is larger than 4 GB") }
        return UInt32(value)
    }

    private func append(_ bytes: [UInt8]) {
        buffer += bytes
        written += bytes.count
    }

    private func append(_ bytes: UnsafeRawBufferPointer) {
        buffer.append(contentsOf: bytes)
        written += bytes.count
    }

    private func append16(_ value: UInt16) {
        append([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private func append32(_ value: UInt32) {
        append([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }

    private func flushIfFull() throws {
        if buffer.count >= 1 << 20 { try flush() }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// The time as zip keeps it: local time, two-second steps, from 1980.
    static func dosTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

/// Reads a zip file: its directory, and its files, inflated as they are
/// written out.
struct ZipReader {
    struct Entry {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressed: Int
        var size: Int
        var offset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    let entries: [Entry]
    private let data: Data

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        entries = try ZipReader.directory(of: data)
    }

    /// Every file, under `folder`; a name leading out of it is refused.
    func extractAll(to folder: URL) throws {
        for entry in entries {
            let parts = entry.name.split(separator: "/")
            guard !entry.name.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty else {
                throw Zip.Failure(message: "The archive has a file outside its folder: \(entry.name)")
            }
            let target = folder.appending(path: entry.name)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try extract(entry, to: target)
        }
    }

    func extract(_ entry: Entry, to target: URL) throws {
        // The local header's name and extra field may differ in length from
        // the directory's.
        let header = entry.offset
        guard header + 30 <= data.count, read32(header) == 0x0403_4B50 else {
            throw Zip.Failure(message: "The archive is damaged at \(entry.name)")
        }
        let start = header + 30 + Int(read16(header + 26)) + Int(read16(header + 28))
        guard start + entry.compressed <= data.count else {
            throw Zip.Failure(message: "The archive is cut short at \(entry.name)")
        }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }
        var crc: UInt32 = 0
        var size = 0
        func take(_ chunk: Data) throws {
            chunk.withUnsafeBytes { crc = Zip.crc32(crc, $0) }
            size += chunk.count
            try out.write(contentsOf: chunk)
        }
        let body = data.subdata(in: start..<start + entry.compressed)
        switch entry.method {
        case 0:
            try take(body)
        case 8:
            let inflater = try OutputFilter(.decompress, using: .zlib) { chunk in
                if let chunk { try take(chunk) }
            }
            var position = 0
            while position < body.count {
                let end = min(position + (1 << 20), body.count)
                try inflater.write(body.subdata(in: position..<end))
                position = end
            }
            try inflater.finalize()
        default:
            throw Zip.Failure(message: "\(entry.name) is compressed in a way Irctell cannot read (method \(entry.method))")
        }
        guard size == entry.size, crc == entry.crc else {
            throw Zip.Failure(message: "\(entry.name) in the archive is damaged: its checksum does not match")
        }
    }

    private static func directory(of data: Data) throws -> [Entry] {
        // The end record is in the last 64 KB, before an optional comment.
        let reader = ZipReader.Bytes(data: data)
        var end = -1
        var position = data.count - 22
        let lowest = max(0, data.count - 22 - 0xFFFF)
        while position >= lowest {
            if reader.read32(position) == 0x0605_4B50 { end = position; break }
            position -= 1
        }
        guard end >= 0 else { throw Zip.Failure(message: "Not a zip archive") }
        let count = Int(reader.read16(end + 10))
        let start = Int(reader.read32(end + 16))
        guard count != 0xFFFF, start != 0xFFFF_FFFF else {
            throw Zip.Failure(message: "The archive is a Zip64 one, larger than Irctell reads")
        }
        var entries: [Entry] = []
        var at = start
        for _ in 0..<count {
            guard at + 46 <= data.count, reader.read32(at) == 0x0201_4B50 else {
                throw Zip.Failure(message: "The archive's directory is damaged")
            }
            let nameLength = Int(reader.read16(at + 28))
            let extra = Int(reader.read16(at + 30)), comment = Int(reader.read16(at + 32))
            guard at + 46 + nameLength <= data.count else { throw Zip.Failure(message: "The archive's directory is damaged") }
            let name = String(decoding: data.subdata(in: at + 46..<at + 46 + nameLength), as: UTF8.self)
            entries.append(Entry(name: name, method: reader.read16(at + 10), crc: reader.read32(at + 16),
                                 compressed: Int(reader.read32(at + 20)), size: Int(reader.read32(at + 24)),
                                 offset: Int(reader.read32(at + 42))))
            at += 46 + nameLength + extra + comment
        }
        return entries
    }

    private func read16(_ at: Int) -> UInt16 { Bytes(data: data).read16(at) }
    private func read32(_ at: Int) -> UInt32 { Bytes(data: data).read32(at) }

    /// Little-endian numbers in the data.
    private struct Bytes {
        let data: Data
        func read16(_ at: Int) -> UInt16 {
            let i = data.startIndex + at
            return UInt16(data[i]) | UInt16(data[i + 1]) << 8
        }
        func read32(_ at: Int) -> UInt32 {
            let i = data.startIndex + at
            return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
        }
    }
}
