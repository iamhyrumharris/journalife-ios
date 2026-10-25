import Foundation
import Testing
@testable import JournalCore

@Suite("Zip")
struct ZipTests {
    @Test func crcMatchesKnownValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func writeThenRead() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).zip")
        let fileURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).bin")
        let big = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try big.write(to: fileURL)

        let writer = try ZipWriter(url: url)
        try writer.addData(Data("hello".utf8), path: "a.txt")
        try writer.addFile(at: fileURL, path: "Media/ab/file.bin")
        try writer.addData(Data(), path: "empty.txt")
        try writer.finish()

        let reader = try ZipReader(url: url)
        #expect(reader.entries.map(\.path) == ["a.txt", "Media/ab/file.bin", "empty.txt"])
        #expect(try reader.data(for: #require(reader.entry("a.txt"))) == Data("hello".utf8))
        #expect(try reader.data(for: #require(reader.entry("empty.txt"))).isEmpty)

        let out = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).bin")
        try reader.extract(#require(reader.entry("Media/ab/file.bin")), to: out)
        #expect(try Data(contentsOf: out) == big)
    }

    @Test func rejectsNonZip() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).zip")
        try Data("not a zip file at all, just some text".utf8).write(to: url)
        #expect(throws: ZipError.self) { try ZipReader(url: url) }
    }
}
