import XCTest
@testable import Fix4me

final class TextScopeTests: XCTestCase {
    func testSelectionWins() {
        let r = TextScope.target(in: "Hello world", selection: NSRange(location: 6, length: 5))
        XCTAssertEqual(r, NSRange(location: 6, length: 5))
    }

    func testParagraphAroundCursorWithoutNewline() {
        let text = "첫 문단입니다.\n둘째 문단 않 지켜요.\n셋째"
        let cursor = (text as NSString).range(of: "둘째").location + 1
        let r = TextScope.target(in: text, selection: NSRange(location: cursor, length: 0))!
        XCTAssertEqual((text as NSString).substring(with: r), "둘째 문단 않 지켜요.")
    }

    func testCursorAtEnd() {
        let text = "明日の会議わ10時から"
        let r = TextScope.target(in: text, selection: NSRange(location: (text as NSString).length, length: 0))!
        XCTAssertEqual((text as NSString).substring(with: r), text)
    }

    func testBlankParagraphIsNil() {
        XCTAssertNil(TextScope.target(in: "abc\n   \ndef", selection: NSRange(location: 5, length: 0)))
    }
}

final class TextDiffTests: XCTestCase {
    func testChangedSpanIsMinimalUTF16() {
        let old = "이 문제는 금새 해결될 것 같읍니다."
        let new = "이 문제는 금세 해결될 것 같습니다."
        let span = TextDiff.changedSpan(old: old, new: new)!
        let applied = (old as NSString).replacingCharacters(in: span.oldRange, with: span.replacement)
        XCTAssertEqual(applied, new)
        XCTAssertLessThan(span.oldRange.length, (old as NSString).length)
    }

    func testChangedSpanWithEmojiKeepsSurrogates() {
        let old = "😀 I has a apple"
        let new = "😀 I have an apple"
        let span = TextDiff.changedSpan(old: old, new: new)!
        XCTAssertEqual((old as NSString).replacingCharacters(in: span.oldRange, with: span.replacement), new)
    }

    func testNoChange() {
        XCTAssertNil(TextDiff.changedSpan(old: "same", new: "same"))
    }

    func testHunkCount() {
        let hunks = TextDiff.hunks(old: "왠만하면 오늘 안에 끝낼께요.", new: "웬만하면 오늘 안에 끝낼게요.")
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks.first, .init(from: "왠", to: "웬"))
    }
}

final class CorrectionParserTests: XCTestCase {
    func testParsesPlainJSON() throws {
        XCTAssertEqual(try CorrectionParser.parse(#"{"corrected":"I have an apple."}"#), "I have an apple.")
    }

    func testParsesFencedJSONWithNewlines() throws {
        let content = "```json\n{\"corrected\": \"첫 줄\\n둘째 줄\"}\n```"
        XCTAssertEqual(try CorrectionParser.parse(content), "첫 줄\n둘째 줄")
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try CorrectionParser.parse("Sure! Here is the text"))
    }

    func testPlausibility() {
        XCTAssertTrue(CorrectionParser.isPlausible(original: "I has a apple.", corrected: "I have an apple."))
        XCTAssertFalse(CorrectionParser.isPlausible(
            original: "What is the weather today?",
            corrected: "I'm sorry, I can't check live weather, but you can look at a forecast site for details."
        ))
        XCTAssertFalse(CorrectionParser.isPlausible(original: "hello", corrected: ""))
    }
}
