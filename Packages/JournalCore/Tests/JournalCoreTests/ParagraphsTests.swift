import Testing
@testable import JournalCore

@Suite("Paragraphs")
struct ParagraphsTests {
    let text = "First line\nSecond line\n\nFourth"

    @Test func cursorGivesItsParagraph() {
        #expect(Paragraphs.bounds(in: text, from: 14, to: 14) == 11..<22)
        #expect(Paragraphs.bounds(in: text, from: 0, to: 0) == 0..<10)
        #expect(Paragraphs.bounds(in: text, from: 10, to: 10) == 0..<10)
    }

    @Test func selectionWidensToWholeParagraphs() {
        #expect(Paragraphs.bounds(in: text, from: 3, to: 14) == 0..<22)
    }

    @Test func selectionEndingAtNewlineStaysInItsParagraph() {
        #expect(Paragraphs.bounds(in: text, from: 11, to: 23) == 11..<22)
    }

    @Test func emptyParagraphAndTextEnd() {
        #expect(Paragraphs.bounds(in: text, from: 23, to: 23) == 23..<23)
        #expect(Paragraphs.bounds(in: text, from: 30, to: 30) == 24..<30)
        #expect(Paragraphs.bounds(in: "", from: 0, to: 0) == 0..<0)
    }
}
