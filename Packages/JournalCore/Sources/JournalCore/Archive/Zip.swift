import Foundation

// DECISION: a small built-in ZIP writer and reader instead of a third-party package.
// Archives use the "stored" method (no compression): photos and videos are already
// compressed, so deflate would cost time and save almost nothing. Every entry carries
// ZIP64 fields so archives larger than 4 GB work. The files open in Finder and `unzip`.

enum ZipError: Error, LocalizedError {
    case notAZip
    case unsupportedMethod(UInt16)
    case corrupt(String)
    case unsafePath(String)
    case sizeChanged(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: "This file is not a journal archive."
        case .unsupportedMethod: "This archive uses compression this app can't read."
        case .corrupt(let detail): "The archive is damaged (\(detail))."
        case .unsafePath(let path): "The archive contains an unsafe path: \(path)."
        case .sizeChanged(let path): "\(path) changed while it was being exported."
        }
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            table.withUnsafeBufferPointer { t in
                for byte in buffer {
                    c = t[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
                }
            }
        }
        return ~c
    }

    static func checksum(_ data: Data) -> UInt32 { update(0, data) }
}

private struct ByteWriter {
    var data = Data()
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { data.append(d) }
}

private struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    mutating func u16() throws -> UInt16 { UInt16(truncatingIfNeeded: try read(2)) }
    mutating func u32() throws -> UInt32 { UInt32(truncatingIfNeeded: try read(4)) }
    mutating func u64() throws -> UInt64 { try read(8) }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw ZipError.corrupt("short read") }
        let start = data.startIndex + offset
        offset += count
        return data.subdata(in: start..<(start + count))
    }

    private mutating func read(_ count: Int) throws -> UInt64 {
        guard offset + count <= data.count else { throw ZipError.corrupt("short read") }
        var value: UInt64 = 0
        for i in 0..<count {
            value |= UInt64(data[data.startIndex + offset + i]) << (8 * UInt64(i))
        }
        offset += count
        return value
    }
}

private func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
    let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let year: Int = max((parts.year ?? 1980) - 1980, 0)
    let hour: Int = parts.hour ?? 0, minute: Int = parts.minute ?? 0, second: Int = parts.second ?? 0
    let month: Int = parts.month ?? 1, dayOfMonth: Int = parts.day ?? 1
    let time = UInt16((hour << 11) | (minute << 5) | (second / 2))
    let day = UInt16((year << 9) | (month << 5) | dayOfMonth)
    return (time, day)
}

/// Writes a ZIP file entry by entry, streaming file contents from disk.
final class ZipWriter {
    private struct CentralRecord {
        let path: Data
        let crc: UInt32
        let size: UInt64
        let offset: UInt64
        let time: UInt16
        let date: UInt16
    }

    private let handle: FileHandle
    private var records: [CentralRecord] = []
    private var offset: UInt64 = 0
    private let stamp = dosDateTime(.now)
    private static let chunkSize = 1 << 20

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
    }

    func addData(_ data: Data, path: String) throws {
        let headerOffset = offset
        try writeLocalHeader(path: path, crc: CRC32.checksum(data), size: UInt64(data.count))
        try write(data)
        records.append(CentralRecord(path: Data(path.utf8), crc: CRC32.checksum(data), size: UInt64(data.count), offset: headerOffset, time: stamp.time, date: stamp.date))
    }

    func addFile(at source: URL, path: String) throws {
        let size = UInt64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let headerOffset = offset
        try writeLocalHeader(path: path, crc: 0, size: size)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var crc: UInt32 = 0
        var copied: UInt64 = 0
        while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            crc = CRC32.update(crc, chunk)
            copied += UInt64(chunk.count)
            try write(chunk)
        }
        guard copied == size else { throw ZipError.sizeChanged(path) }
        // Patch the CRC into the local header now that it is known (offset 14 in the header).
        try handle.seek(toOffset: headerOffset + 14)
        var patch = ByteWriter()
        patch.u32(crc)
        try handle.write(contentsOf: patch.data)
        try handle.seekToEnd()
        records.append(CentralRecord(path: Data(path.utf8), crc: crc, size: size, offset: headerOffset, time: stamp.time, date: stamp.date))
    }

    func finish() throws {
        let centralStart = offset
        for record in records {
            var w = ByteWriter()
            w.u32(0x0201_4B50)
            w.u16(45) // version made by
            w.u16(45) // version needed (ZIP64)
            w.u16(0x0800) // UTF-8 names
            w.u16(0) // stored
            w.u16(record.time)
            w.u16(record.date)
            w.u32(record.crc)
            w.u32(0xFFFF_FFFF)
            w.u32(0xFFFF_FFFF)
            w.u16(UInt16(record.path.count))
            w.u16(28) // extra length
            w.u16(0) // comment length
            w.u16(0) // disk number
            w.u16(0) // internal attributes
            w.u32(0) // external attributes
            w.u32(0xFFFF_FFFF)
            w.bytes(record.path)
            w.u16(0x0001)
            w.u16(24)
            w.u64(record.size)
            w.u64(record.size)
            w.u64(record.offset)
            try write(w.data)
        }
        let centralSize = offset - centralStart
        let zip64Start = offset
        let count = UInt64(records.count)

        var end = ByteWriter()
        end.u32(0x0606_4B50)
        end.u64(44)
        end.u16(45)
        end.u16(45)
        end.u32(0)
        end.u32(0)
        end.u64(count)
        end.u64(count)
        end.u64(centralSize)
        end.u64(centralStart)
        // ZIP64 end of central directory locator
        end.u32(0x0706_4B50)
        end.u32(0)
        end.u64(zip64Start)
        end.u32(1)
        // Classic end of central directory
        end.u32(0x0605_4B50)
        end.u16(0)
        end.u16(0)
        end.u16(count < 0xFFFF ? UInt16(count) : 0xFFFF)
        end.u16(count < 0xFFFF ? UInt16(count) : 0xFFFF)
        end.u32(centralSize < 0xFFFF_FFFF ? UInt32(centralSize) : 0xFFFF_FFFF)
        end.u32(centralStart < 0xFFFF_FFFF ? UInt32(centralStart) : 0xFFFF_FFFF)
        end.u16(0)
        try write(end.data)
        try handle.close()
    }

    private func writeLocalHeader(path: String, crc: UInt32, size: UInt64) throws {
        let name = Data(path.utf8)
        var w = ByteWriter()
        w.u32(0x0403_4B50)
        w.u16(45)
        w.u16(0x0800)
        w.u16(0)
        w.u16(stamp.time)
        w.u16(stamp.date)
        w.u32(crc)
        w.u32(0xFFFF_FFFF)
        w.u32(0xFFFF_FFFF)
        w.u16(UInt16(name.count))
        w.u16(20)
        w.bytes(name)
        w.u16(0x0001)
        w.u16(16)
        w.u64(size)
        w.u64(size)
        try write(w.data)
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }
}

/// Reads stored (uncompressed) ZIP files, including ZIP64.
final class ZipReader {
    struct Entry {
        let path: String
        let crc: UInt32
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    private let handle: FileHandle
    private(set) var entries: [Entry] = []

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        try readCentralDirectory()
    }

    deinit { try? handle.close() }

    func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    func data(for entry: Entry) throws -> Data {
        guard entry.method == 0 else { throw ZipError.unsupportedMethod(entry.method) }
        try handle.seek(toOffset: try dataOffset(for: entry))
        let data = try handle.read(upToCount: Int(entry.uncompressedSize)) ?? Data()
        guard UInt64(data.count) == entry.uncompressedSize else { throw ZipError.corrupt("truncated \(entry.path)") }
        guard CRC32.checksum(data) == entry.crc else { throw ZipError.corrupt("checksum \(entry.path)") }
        return data
    }

    func extract(_ entry: Entry, to destination: URL) throws {
        guard entry.method == 0 else { throw ZipError.unsupportedMethod(entry.method) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        try handle.seek(toOffset: try dataOffset(for: entry))
        var remaining = entry.uncompressedSize
        var crc: UInt32 = 0
        while remaining > 0 {
            let count = Int(min(remaining, 1 << 20))
            guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                throw ZipError.corrupt("truncated \(entry.path)")
            }
            crc = CRC32.update(crc, chunk)
            try output.write(contentsOf: chunk)
            remaining -= UInt64(count)
        }
        guard crc == entry.crc else { throw ZipError.corrupt("checksum \(entry.path)") }
    }

    private func dataOffset(for entry: Entry) throws -> UInt64 {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30 else { throw ZipError.corrupt("local header") }
        var r = ByteReader(header)
        guard try r.u32() == 0x0403_4B50 else { throw ZipError.corrupt("local header signature") }
        r.offset = 26
        let nameLength = UInt64(try r.u16())
        let extraLength = UInt64(try r.u16())
        return entry.localHeaderOffset + 30 + nameLength + extraLength
    }

    private func readCentralDirectory() throws {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ZipError.notAZip }
        let tailLength = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailLength)
        guard let tail = try handle.read(upToCount: Int(tailLength)) else { throw ZipError.notAZip }

        // Find the end of central directory record, scanning backwards.
        var eocd: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail[tail.startIndex + index] == 0x50, tail[tail.startIndex + index + 1] == 0x4B,
               tail[tail.startIndex + index + 2] == 0x05, tail[tail.startIndex + index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else { throw ZipError.notAZip }
        var r = ByteReader(tail, offset: eocd + 10)
        var count = UInt64(try r.u16())
        var centralSize = UInt64(try r.u32())
        var centralOffset = UInt64(try r.u32())

        // A ZIP64 locator sits right before the classic record.
        if eocd >= 20 {
            var locator = ByteReader(tail, offset: eocd - 20)
            if try locator.u32() == 0x0706_4B50 {
                _ = try locator.u32()
                let zip64Offset = try locator.u64()
                try handle.seek(toOffset: zip64Offset)
                guard let record = try handle.read(upToCount: 56), record.count == 56 else { throw ZipError.corrupt("zip64 record") }
                var z = ByteReader(record)
                guard try z.u32() == 0x0606_4B50 else { throw ZipError.corrupt("zip64 signature") }
                z.offset = 32
                count = try z.u64()
                centralSize = try z.u64()
                centralOffset = try z.u64()
            }
        }

        try handle.seek(toOffset: centralOffset)
        guard let central = try handle.read(upToCount: Int(centralSize)), UInt64(central.count) == centralSize else {
            throw ZipError.corrupt("central directory")
        }
        var c = ByteReader(central)
        var result: [Entry] = []
        result.reserveCapacity(Int(min(count, 100_000)))
        for _ in 0..<count {
            guard try c.u32() == 0x0201_4B50 else { throw ZipError.corrupt("central signature") }
            _ = try c.u16() // made by
            _ = try c.u16() // needed
            _ = try c.u16() // flags
            let method = try c.u16()
            _ = try c.u16() // time
            _ = try c.u16() // date
            let crc = try c.u32()
            var compressed = UInt64(try c.u32())
            var uncompressed = UInt64(try c.u32())
            let nameLength = Int(try c.u16())
            let extraLength = Int(try c.u16())
            let commentLength = Int(try c.u16())
            _ = try c.u16() // disk
            _ = try c.u16() // internal
            _ = try c.u32() // external
            var localOffset = UInt64(try c.u32())
            let nameData = try c.bytes(nameLength)
            let extra = try c.bytes(extraLength)
            _ = try c.bytes(commentLength)

            var e = ByteReader(extra)
            while e.offset + 4 <= extra.count {
                let headerID = try e.u16()
                let size = Int(try e.u16())
                let end = e.offset + size
                if headerID == 0x0001 {
                    if uncompressed == 0xFFFF_FFFF { uncompressed = try e.u64() }
                    if compressed == 0xFFFF_FFFF { compressed = try e.u64() }
                    if localOffset == 0xFFFF_FFFF { localOffset = try e.u64() }
                }
                e.offset = end
            }

            guard let path = String(data: nameData, encoding: .utf8) else { throw ZipError.corrupt("file name") }
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") { throw ZipError.unsafePath(path) }
            result.append(Entry(path: path, crc: crc, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: localOffset))
        }
        entries = result
    }
}
