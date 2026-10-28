import Foundation
import Testing
@testable import JournalCore

@Suite("RichText")
struct RichTextTests {
    @Test func mergesAdjacentRunsWithSameStyle() {
        let text = RichText(runs: [.init(text: "a"), .init(text: "b"), .init(text: "", bold: true), .init(text: "c", bold: true)])
        #expect(text.runs.count == 2)
        #expect(text.plainText == "abc")
    }

    @Test func encodeDecodeRoundTrip() throws {
        let text = RichText(runs: [
            .init(text: "Title\n", bold: true, heading: 1),
            .init(text: "• one\n"),
            .init(text: "struck", strikethrough: true),
            .init(text: " under", underline: true),
            .init(text: " italic", italic: true),
        ])
        #expect(try RichText.decode(from: text.encoded()) == text)
    }

    @Test func plainFallback() {
        #expect(RichText(plain: "").isEmpty)
        #expect(RichText(plain: "hi").plainText == "hi")
    }
}
