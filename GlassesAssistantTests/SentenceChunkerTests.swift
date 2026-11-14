import XCTest

@testable import GlassesAssistant

final class SentenceChunkerTests: XCTestCase {
    func testEmitsSentencesAsTheyComplete() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("The weather today is "), [])
        XCTAssertEqual(chunker.append("sunny and warm. Tomorrow"), ["The weather today is sunny and warm."])
        XCTAssertEqual(chunker.append(" looks rainy!"), [])
        XCTAssertEqual(chunker.flush(), "Tomorrow looks rainy!")
    }

    func testDoesNotSplitDecimalsOrShortFragments() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("It is 3.5 km. Dr. Smith said so. "), ["It is 3.5 km.", "Dr. Smith said so."])
    }

    func testStripsMarkdown() {
        XCTAssertEqual(SentenceChunker.clean("**Bold** and `code`"), "Bold and code")
        XCTAssertNil(SentenceChunker.clean(" ** "))
    }
}
