import XCTest
@testable import Fix4me

final class SectionerTests: XCTestCase {
    private func units(_ text: String, _ level: CorrectionLevel = .polish) -> [String] {
        Sectioner.units(in: text, level: level).map { (text as NSString).substring(with: $0) }
    }
    private func kinds(_ text: String) -> [Sectioner.Kind?] { Sectioner.classify(text.components(separatedBy: "\n")) }
    private let a = "첫째 문단은 마흔 글자가 넘도록 충분히 길게 써서 이웃과 합쳐지지 않게 만든 글입니다."
    private let b = "둘째 문단도 마찬가지로 마흔 글자가 넘도록 길게 써서 따로 떨어지게 만든 글입니다."

    // MARK: 예문

    func testShortChatIsOneUnit() {
        for t in ["안녕하세요.\n\n내일 10시 괜찮으세요?\n\n감사합니다.", "넵 확인했습니다\n바로 볼게요", "ok, thanks!"] {
            for level in CorrectionLevel.allCases { XCTAssertEqual(units(t, level), [t]) }
        }
    }

    func testBlankLineSplitsLongParagraphs() { XCTAssertEqual(units(a + "\n\n" + b), [a, b]) }

    func testSingleNewlineStaysInParagraph() { XCTAssertEqual(units(a + "\n짧은 줄\n\n" + b), [a + "\n짧은 줄", b]) }

    func testTwoBlankLinesSplitEvenShortText() { XCTAssertEqual(units("짧은 글\n\n\n다른 글"), ["짧은 글", "다른 글"]) }

    func testDividersSplitAndAreNotSent() {
        for d in ["---", "***", "===", "___", "─────", "* * *", "・・・"] {
            XCTAssertEqual(units("짧은 글\n\(d)\n다른 글"), ["짧은 글", "다른 글"], d)
        }
    }

    func testMarkdownHeadingJoinsItsBody() {
        XCTAssertEqual(units("# 개요\n\n\(a)\n\n## 결론\n\(b)"), ["# 개요\n\n" + a, "## 결론\n" + b])
    }

    func testLongHeadingStillJoinsBodyAfterBlankLine() {
        // 40자가 넘는 제목: 짧은 조각 합치기로는 붙지 않으므로 제목 규칙이 있어야 한다
        let h = "# 이 제목은 마흔 글자를 넘기려고 일부러 길게 늘여서 쓴 아주 긴 제목이라 합치기 대상이 아님"
        XCTAssertGreaterThan(h.count, Sectioner.minLength)
        XCTAssertEqual(units(h + "\n\n" + a), [h + "\n\n" + a])
    }

    func testSymbolAndBracketHeadings() {
        XCTAssertEqual(units("■ 일정\n내일 오전\n\n■ 장소\n본사 3층"), ["■ 일정\n내일 오전", "■ 장소\n본사 3층"])
        XCTAssertEqual(units("【議題】\n予算について\n\n【次回】\n来週"), ["【議題】\n予算について", "【次回】\n来週"])
    }

    func testRepeatedSymbolIsListNotHeading() {
        XCTAssertEqual(kinds("● 사과\n● 배\n● 감"), [.list, .list, .list])
        XCTAssertEqual(kinds("본문\n\n■ 일정\n내일"), [.text, nil, .heading, .text])
    }

    func testNumberedHeadingVersusList() {
        XCTAssertEqual(kinds("1. 개요\n본문입니다.\n\n2. 결론\n끝입니다."), [.heading, .text, nil, .heading, .text])
        XCTAssertEqual(kinds("1. 우유 사기\n2. 빵 사기"), [.list, .list])
        XCTAssertEqual(kinds("1. 오늘은 회의가 있습니다.\n본문"), [.list, .text])
        XCTAssertEqual(kinds("10.5 는 숫자입니다"), [.text])
    }

    func testListIsOneUnitWithContinuationLines() {
        let list = "- 첫 항목은 조금 길게 써서 길이를 채웁니다\n  이어지는 설명 줄\n- 둘째 항목도 길게 써서 채웁니다"
        XCTAssertEqual(units(a + "\n\n" + list), [a, list])
        XCTAssertEqual(kinds("- [ ] 할 일\n- [x] 끝"), [.list, .list])
    }

    func testProtectedPartsAreNeverSent() {
        let t = """
        설명입니다.
        ```swift
        let x = "않 됨"

        let y = 2
        ```
        이어지는 글입니다.
        > 남이 쓴 글 않 고침
        | 표 | 값 |
        https://example.com/a
        마지막 글입니다.
        --
        홍길동
        AIB
        """
        for level in CorrectionLevel.allCases {
            XCTAssertEqual(units(t, level), ["설명입니다.", "이어지는 글입니다.", "마지막 글입니다."])
        }
    }

    func testUnclosedCodeProtectsTheRest() { XCTAssertEqual(units("글입니다.\n```\nlet a\n본문처럼 보여도"), ["글입니다."]) }

    func testLinePerParagraphHabit() {
        let t = [a + a, b + b, a + b].joined(separator: "\n")
        XCTAssertEqual(units(t, .proofread), t.components(separatedBy: "\n"))   // 교정은 줄마다
        XCTAssertEqual(units(t, .polish), [t])                                  // 다듬기는 한 섹션
    }

    func testHardWrappedEmailStaysTogether() {
        let t = """
        I wanted to follow up on our conversation from last week about the new
        onboarding flow, because several people on the team have told me that they
        are confused about which of the steps are required and which ones they can
        skip. Could you send me the latest version of the document when you have
        a minute?
        """
        XCTAssertEqual(Sectioner.habit(t.components(separatedBy: "\n"), hasBlankBetween: false), .hardWrapped)
        for level in CorrectionLevel.allCases { XCTAssertEqual(units(t, level), [t]) }
    }

    func testEvenLengthSentencesAreNotHardWrapped() {
        // 길이가 비슷해도 줄마다 문장이 끝나면 잘린 글이 아니다
        let lines = (0..<5).map { "이 줄은 \($0)번째이고 길이가 서로 비슷하지만 문장으로 제대로 끝나는 줄입니다." }
        XCTAssertEqual(Sectioner.habit(lines, hasBlankBetween: false), .linePerParagraph)
    }

    func testJapaneseMail() {
        let body = "先日お送りいただいた見積書の件ですが、内容を確認いたしましたので、いくつか質問させていただきたく存じます。"
        XCTAssertEqual(units("お世話になっております。\n\n\(body)\n\nよろしくお願いいたします。"),
                       ["お世話になっております。\n\n\(body)\n\nよろしくお願いいたします。"])
    }

    func testLongTextSplitsAtSentences() {
        for s in ["이 문장은 길이를 채우려고 쓴 문장입니다. ", "This sentence is here only to add length. ", "この文章は長さを足すために書きました。"] {
            let t = String(repeating: s, count: 40).trimmingCharacters(in: .whitespaces)
            let u = units(t)
            XCTAssertGreaterThan(u.count, 1)
            for piece in u {
                XCTAssertLessThanOrEqual(piece.utf16.count, Sectioner.maxLength)
                XCTAssertTrue(".。".contains(piece.last!), String(piece.suffix(12)))   // 문장 중간에서 자르지 않는다
            }
        }
    }

    func testOneVeryLongSentenceIsKept() {
        let t = String(repeating: "가나다라마 ", count: 150) + "끝"
        XCTAssertEqual(units(t), [t])
    }

    // MARK: 문맥

    func testContextIsNearestHeadingAndPreviousBlockOnly() {
        let t = "# 제목\n\n\(a)\n\n\(b)\n\n세 번째 문단입니다."
        let r = (t as NSString).range(of: "세 번째")
        XCTAssertEqual(Sectioner.context(before: r, in: t), "# 제목\n" + b)
        XCTAssertEqual(Sectioner.context(before: NSRange(location: 0, length: 3), in: t), "")
    }

    func testContextSkipsProtectedPartsAndIsBounded() {
        let t = "앞 글입니다.\n```\nsecret\n```\n대상"
        XCTAssertEqual(Sectioner.context(before: (t as NSString).range(of: "대상"), in: t), "앞 글입니다.")
        let long = String(repeating: "😀", count: 400) + "\n\n대상"
        let c = Sectioner.context(before: (long as NSString).range(of: "대상"), in: long)
        XCTAssertLessThanOrEqual(c.utf16.count, 302)
        XCTAssertTrue(c.allSatisfy { $0 == "😀" })
    }

    // MARK: 어떤 글이든 지켜야 하는 것

    func testInvariantsOnRandomText() {
        var rng = SystemRandomNumberGenerator()
        let pieces = [a, b, "짧은 줄", "# 제목", "■ 항목", "1. 개요", "2) 둘째", "- 목록", "  이어짐", "---", "```", "> 인용", "| a | b |",
                      "https://a.b/c", "", "", "", "--", "😀 이모지.", "Hello there, this is a line.", "長い文章です。", "\t탭", String(repeating: "긴 문장입니다. ", count: 60)]
        for _ in 0..<1500 {
            let t = (0..<Int.random(in: 0...14, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined(separator: "\n")
            let ns = t as NSString
            let blocks = Sectioner.blocks(in: t)
            for level in CorrectionLevel.allCases {
                let u = Sectioner.units(in: t, level: level)
                for (x, y) in zip(u, u.dropFirst()) { XCTAssertLessThanOrEqual(NSMaxRange(x), y.location) }   // 순서·겹침 없음
                for r in u {
                    XCTAssertTrue(r.length > 0 && NSMaxRange(r) <= ns.length)
                    for block in blocks where NSIntersectionRange(block.range, r).length > 0 {
                        XCTAssertFalse(block.kind.isProtected, t)                                              // 보호 구역을 담지 않는다
// 강한 경계에서 시작하는 덩어리가 단위 중간에 끼면 경계를 넘은 것
                        if block.boundary == .strong { XCTAssertLessThanOrEqual(block.range.location, r.location, t) }
                    }
                }
                // 보호 구역이 아닌 글자는 하나도 빠지지 않는다
                var covered = IndexSet()
                for r in u { covered.insert(integersIn: r.location..<NSMaxRange(r)) }
                for block in blocks where !block.kind.isProtected {
                    for i in block.range.location..<NSMaxRange(block.range) where !covered.contains(i) {
                        let c = ns.character(at: i)
                        XCTAssertTrue(c == 0x20 || c == 0x09 || c == 0x0A, "빠진 글자: \(t)")
                    }
                }
            }
        }
    }
}
