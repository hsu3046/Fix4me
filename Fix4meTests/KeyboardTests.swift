import XCTest
@testable import Fix4me

/// iPhone 입력창 흉내: 문장 단위로 일부만 보여 주고(실측), 변경이 늦게 보이고,
/// 커서가 이모지 가운데에 놓일 수 있다(실측: 그때 글이 깨져 보인다). 위치는 UTF-16.
@MainActor
final class FakeField: KeyboardProxy {
    private var units: [UInt16]
    private var at: Int               // UTF-16 커서
    var selection: Range<Int>?        // 글자(Character) 범위
    var limit = 300
    var lag = 1                       // 몇 번 기다려야 새 상태가 보이는지
    var utf16Offsets = true           // 커서 이동을 UTF-16 으로 세는 앱 (iOS 실측). 아니면 글자로 센다
    var ignoresDelete = false
    var altersInsert = false          // 넣은 글을 앱이 바꿔 버리는 경우 (글자 수 제한 등)
    private var shown: (String, String) = ("", "")
    private var pending = 0

    /// cursor 는 글자 기준
    init(_ s: String, cursor: Int? = nil) {
        units = Array(s.utf16)
        at = String(s.prefix(cursor ?? s.count)).utf16.count
        shown = visible
    }

    var string: String { String(decoding: units, as: UTF16.self) }
    /// 글자 기준 커서 (글자 가운데면 nil)
    var cursor: Int? {
        var n = 0, k = 0
        for c in string { if n == at { return k }; n += String(c).utf16.count; k += 1 }
        return n == at ? k : nil
    }
    private func isEnd(_ u: UInt16) -> Bool { [0x2E, 0x21, 0x3F, 0x3002, 0x0A].contains(u) }
    private var visible: (String, String) {
        // 앞: 앞 문장 하나까지, 뒤: 지금 문장 끝까지 (실측과 비슷하게)
        var start = at, ends = 0
        while start > 0, at - start < limit {
            if start < at, isEnd(units[start - 1]) { ends += 1; if ends == 2 { break } }
            start -= 1
        }
        var end = at
        while end < units.count, end - at < limit { end += 1; if isEnd(units[end - 1]) { break } }
        // 문장 끝에 있으면 뒤가 비어 보인다
        if at > 0, at < units.count, isEnd(units[at - 1]) { end = at }
        return (String(decoding: units[start..<at], as: UTF16.self), String(decoding: units[at..<end], as: UTF16.self))
    }
    private func touched() { pending = lag; if lag == 0 { shown = visible } }
    /// 글자 경계들 (UTF-16)
    private var edges: [Int] { string.reduce(into: [0]) { $0.append($0.last! + String($1).utf16.count) } }

    var before: String { shown.0 }
    var after: String { shown.1 }
    var selected: String { selection.map { String(Array(string)[$0]) } ?? "" }
    func move(by offset: Int) {
        if utf16Offsets {
            at = min(max(0, at + offset), units.count)
        } else {
            let e = edges, k = e.lastIndex { $0 <= at } ?? 0
            at = e[min(max(0, k + offset), e.count - 1)]
        }
        touched()
    }
    func insert(_ text: String) {
        let s = altersInsert ? String(text.dropLast()) : text
        if let r = selection {
            let e = edges
            units.replaceSubrange(e[r.lowerBound]..<e[r.upperBound], with: Array(s.utf16))
            at = e[r.lowerBound] + s.utf16.count
            selection = nil
        } else {
            units.insert(contentsOf: Array(s.utf16), at: at)
            at += s.utf16.count
        }
        touched()
    }
    func deleteBackward() {
        if !ignoresDelete, at > 0 {
            let from = edges.last { $0 < at } ?? 0
            units.removeSubrange(from..<at)
            at = from
        }
        touched()
    }
    func pause() async {
        if pending > 0 { pending -= 1 }
        if pending == 0 { shown = visible }
    }
}

@MainActor
final class KeyboardTests: XCTestCase {
    private func fix(_ f: FakeField, level: CorrectionLevel = .polish, _ change: (String) -> String) async throws -> String {
        let s = KeyboardSession(proxy: f)
        let t = try await s.read()
        let target = try XCTUnwrap(t.target(level: level))
        try await s.apply(target, in: t, corrected: change(target.text))
        return f.string
    }

    func testReadsWholeMessageAndReturnsToTheSamePlace() async throws {
        let text = "안녕하세요. 어제 정한 사항을 않 지키면 문제가 됩니다.\n이번주 금요일 까지 확인 부탁드려요. 감사합니다."
        for cursor in [0, 3, 7, 20, text.count] {
            for lag in [0, 1, 3] {
                let f = FakeField(text, cursor: cursor); f.lag = lag
                let t = try await KeyboardSession(proxy: f).read()
                XCTAssertEqual(t.before + t.after, text, "커서 \(cursor) 지연 \(lag)")
                XCTAssertEqual(f.cursor, cursor, "커서 \(cursor) 지연 \(lag)")
            }
        }
    }

    func testFixesInPlaceFromAnyCursorPosition() async throws {
        let text = "어제 정한 사항을 않 지키면 문제가 됩니다. 확인 부탁드려요."
        for cursor in [0, 12, text.count] {
            let f = FakeField(text, cursor: cursor)
            let out = try await fix(f) { $0.replacingOccurrences(of: "않 ", with: "안 ") }
            XCTAssertEqual(out, text.replacingOccurrences(of: "않 ", with: "안 "), "커서 \(cursor)")
            XCTAssertEqual(f.cursor, text.count, "바꾼 글의 끝에 커서")
        }
    }

    func testInsertionDeletionAndWholeReplacement() async throws {
        for (a, b) in [("I has a apple", "I have an apple"), ("금요일 까지", "금요일까지"), ("처음", "처음!"), ("끝..", "끝."), ("완전히 다름", "Totally new"), ("앞뒤", "새앞뒤")] {
            let f = FakeField(a, cursor: a.count / 2)
            let out = try await fix(f) { _ in b }
            XCTAssertEqual(out, b)
        }
    }

    func testOnlyTheSectionAtTheCursorChanges() async throws {
        let a = "첫째 문단은 마흔 글자가 넘도록 충분히 길게 써서 이웃과 합쳐지지 않게 만든 글입니다."
        let b = "둘째 문단도 마찬가지로 마흔 글자가 넘도록 길게 써서 따로 떨어지게 만든 글입니다."
        let text = a + "\n\n" + b
        let f = FakeField(text, cursor: 5)
        let out = try await fix(f) { $0.replacingOccurrences(of: "글입니다", with: "문장입니다") }
        XCTAssertEqual(out, a.replacingOccurrences(of: "글입니다", with: "문장입니다") + "\n\n" + b)
    }

    func testSelectionIsReplacedExactly() async throws {
        let f = FakeField("앞 않 됨 뒤"); f.selection = 2..<5
        let out = try await fix(f) { _ in "안 됨" }
        XCTAssertEqual(out, "앞 안 됨 뒤")
    }

    func testRepeatedSentencesDoNotLoseThePosition() async throws {
        let text = String(repeating: "같은 문장입니다. ", count: 6) + "끝 않 됨."
        let f = FakeField(text, cursor: 25)
        let out = try await fix(f) { $0.replacingOccurrences(of: "않 ", with: "안 ") }
        XCTAssertEqual(out, text.replacingOccurrences(of: "않 ", with: "안 "))
    }

    func testEmojiTextIsReadAndFixedExactly() async throws {
        let text = "좋아요 😀👍🏽👨‍👩‍👧 정말요. 이건 않 돼요 😀 이번주 봐요."
        let fixed = text.replacingOccurrences(of: "않 ", with: "안 ").replacingOccurrences(of: "이번주", with: "이번 주 🎉")
        for cursor in [0, 6, 14, text.count] {
            let f = FakeField(text, cursor: cursor)
            let t = try await KeyboardSession(proxy: f).read()
            XCTAssertEqual(t.before + t.after, text, "커서 \(cursor)")
            XCTAssertEqual(f.cursor, cursor)
            let out = try await fix(f) { $0.replacingOccurrences(of: "않 ", with: "안 ").replacingOccurrences(of: "이번주", with: "이번 주 🎉") }
            XCTAssertEqual(out, fixed, "커서 \(cursor)")
        }
    }

    /// 커서를 다르게 세는 앱: 못 고칠 수는 있어도 글이 깨지면 안 된다
    func testAppThatCountsDifferentlyIsNeverCorrupted() async throws {
        let text = "좋아요 😀👍🏽👨‍👩‍👧 정말요. 이건 않 돼요 😀 이번주 봐요."
        let fixed = text.replacingOccurrences(of: "않 ", with: "안 ")
        for cursor in 0...text.count {
            let f = FakeField(text, cursor: cursor); f.utf16Offsets = false
            do {
                let session = KeyboardSession(proxy: f)
                let t = try await session.read()
                XCTAssertTrue((t.before + t.after).isEmpty || text.contains(t.before + t.after), "원문에 없는 글을 읽음: \(t.before + t.after)")
                XCTAssertEqual(f.string, text)
                guard let target = t.target(level: .polish) else { continue }   // 고칠 글을 못 읽음 — 안전
                try await session.apply(target, in: t, corrected: target.text.replacingOccurrences(of: "않 ", with: "안 "))
                XCTAssertTrue([text, fixed].contains(f.string), f.string)
            } catch { XCTAssertEqual(f.string, text, "커서 \(cursor) \(error)") }
        }
    }

    func testTextChangedWhileWaitingIsNotOverwritten() async throws {
        let f = FakeField("이건 않 돼요")
        let s = KeyboardSession(proxy: f)
        let t = try await s.read()
        f.insert(" 추가"); f.lag = 0; await f.pause(); await f.pause()
        do { try await s.apply(t.target(level: .polish)!, in: t, corrected: "이건 안 돼요"); XCTFail("막아야 한다") }
        catch { XCTAssertEqual(error as? KeyboardError, .changed) }
        XCTAssertEqual(f.string, "이건 않 돼요 추가")
    }

    func testAppThatIgnoresDeleteDoesNotGetDuplicatedText() async throws {
        let f = FakeField("이건 않 돼요"); f.ignoresDelete = true
        do { _ = try await fix(f) { _ in "이건 안 돼요" }; XCTFail("막아야 한다") }
        catch { XCTAssertEqual(error as? KeyboardError, .mismatch) }
        XCTAssertEqual(f.string, "이건 않 돼요")
    }

    func testAppThatAltersInsertedTextIsReported() async throws {
        let f = FakeField("이건 않 돼요"); f.altersInsert = true
        do { _ = try await fix(f) { $0.replacingOccurrences(of: "않 ", with: "안정 ") }; XCTFail("알리지 않음") }
        catch { XCTAssertEqual(error as? KeyboardError, .mismatch) }
    }

    func testChangedSelectionIsNotOverwritten() async throws {
        let f = FakeField("앞 않 됨 뒤"); f.selection = 2..<5
        let s = KeyboardSession(proxy: f)
        let t = try await s.read()
        let target = try XCTUnwrap(t.target(level: .polish))
        f.selection = 0..<1
        do { try await s.apply(target, in: t, corrected: "안 됨"); XCTFail("덮어씀") }
        catch { XCTAssertEqual(error as? KeyboardError, .changed) }
        XCTAssertEqual(f.string, "앞 않 됨 뒤")
    }

    /// 같은 글자가 이어지면 움직였는지 구별할 수 없다 → 커서를 건드리지 않아야 한다
    func testRunsOfTheSameCharacterDoNotMoveTheCursor() async throws {
        for cursor in 0...10 {
            let f = FakeField(String(repeating: "。", count: 10), cursor: cursor)
            _ = try? await KeyboardSession(proxy: f).read()
            XCTAssertEqual(f.cursor, cursor)
        }
    }

    /// 기다려도 변화가 안 보일 만큼 느린 앱에서도 커서는 제자리로
    func testVerySlowAppKeepsTheCursor() async throws {
        let text = "첫 문장입니다. 둘째 문장입니다. 셋째 문장입니다."
        for cursor in 1..<text.count {
            let f = FakeField(text, cursor: cursor); f.lag = 40
            _ = try? await KeyboardSession(proxy: f).read()
            XCTAssertEqual(f.cursor, cursor); XCTAssertEqual(f.string, text)
        }
    }

    func testBlankFieldHasNoTarget() async throws {
        let t = try await KeyboardSession(proxy: FakeField("  \n ")).read()
        XCTAssertNil(t.target(level: .proofread))
    }

    func testRandomTextsAndCursors() async throws {
        var rng = SystemRandomNumberGenerator()
        let words = ["않 ", "안녕", "문장입니다. ", "\n", "\n\n", "ok ", "会議わ", "。", "A apple ", "! ", "금새 ", "😀", "👨‍👩‍👧 "]
        for _ in 0..<1500 {
            let text = (0..<Int.random(in: 1...18, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined()
            let cursor = Int.random(in: 0...text.count, using: &rng)
            let f = FakeField(text, cursor: cursor); f.lag = Int.random(in: 0...2, using: &rng)
            let s = KeyboardSession(proxy: f)
            let t: KeyboardText
            do { t = try await s.read() } catch { XCTFail("읽기 실패 \(error) 커서 \(cursor) 지연 \(f.lag) \(text.debugDescription)"); return }
            XCTAssertEqual(f.cursor, cursor, text.debugDescription); XCTAssertEqual(f.string, text)
            XCTAssertTrue((t.before + t.after).isEmpty || text.contains(t.before + t.after), "읽은 글이 원문의 일부가 아님: \((t.before + t.after).debugDescription)")
            guard let target = t.target(level: .polish) else { continue }
            let fixed = target.text.replacingOccurrences(of: "않 ", with: "안 ").replacingOccurrences(of: "금새", with: "금세 ")
            do {
                try await s.apply(target, in: t, corrected: fixed)
                let range = (text as NSString).range(of: target.text)
                XCTAssertNotEqual(range.location, NSNotFound)
                // 고친 글은 원문에서 대상 한 곳만 바뀐 것이어야 한다
                let candidates = ranges(of: target.text, in: text).map { (text as NSString).replacingCharacters(in: $0, with: fixed) }
                XCTAssertTrue(candidates.contains(f.string), "원문 \(text.debugDescription) 결과 \(f.string.debugDescription)")
            } catch { XCTAssertEqual(f.string, text, "\(error)") }
        }
    }

    private func ranges(of part: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = [], at = 0
        while at <= ns.length {
            let r = ns.range(of: part, options: .literal, range: NSRange(location: at, length: ns.length - at))
            if r.location == NSNotFound { break }
            out.append(r); at = r.location + 1
        }
        return out
    }
}
