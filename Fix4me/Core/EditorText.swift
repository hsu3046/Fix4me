import Foundation

/// 입력창마다 다른 글·위치 표현을 맞추는 순수 함수.
enum EditorText {
    /// 위치를 세는 방식. 웹 편집기(contenteditable)는 글에는 줄바꿈을 넣어 주면서 위치에는 세지 않고,
    /// 반대로 빈 줄은 글에서 빼면서 위치에는 센다 (시험용 Chromium 실측). 그래서 줄마다 어긋난 만큼(extra)을 더한다.
    enum Mapping: Equatable, Sendable {
        case native
        case noNewlines(extra: Int)

        func map(_ range: NSRange, in text: String) -> NSRange {
            guard case let .noNewlines(extra) = self else { return range }
            let ns = text as NSString
            func newlines(before end: Int) -> Int {
                var n = 0
                for i in 0..<min(max(end, 0), ns.length) where ns.character(at: i) == 0x0A { n += 1 }
                return n
            }
            let start = range.location - newlines(before: range.location) + extra
            let end = NSMaxRange(range) - newlines(before: NSMaxRange(range)) + extra
            return NSRange(location: start, length: end - start)
        }
    }

    /// 선택된 글이 원하는 글에서 얼마나 어긋났는지 (옮겨야 할 글자 수). 겹치는 곳을 못 찾으면 nil.
    static func shift(from selected: String, to wanted: String) -> Int? {
        func offset(of part: String, in whole: String) -> Int? {
            let r = (normalizeSpaces(whole) as NSString).range(of: normalizeSpaces(part), options: .literal)
            return r.location == NSNotFound || r.location == 0 ? nil : r.location
        }
        guard selected.count >= 2, wanted.count >= 2 else { return nil }
        if let ahead = offset(of: String(wanted.prefix(8)), in: selected) { return ahead }      // 너무 앞을 잡았다 → 뒤로
        if let ahead = offset(of: String(wanted.prefix(max(2, wanted.count / 2))), in: selected) { return ahead }
        return offset(of: String(selected.prefix(8)), in: wanted).map { -$0 }                    // 너무 뒤를 잡았다 → 앞으로
    }

    private static func normalizeSpaces(_ s: String) -> String { s.replacingOccurrences(of: "\u{00A0}", with: " ") }

    /// 같은 글인지 (표현 차이만 무시): 줄바꿈 문자 종류, 줄바꿈 없는 공백, 맨 끝 줄바꿈
    static func same(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }

    /// 선택해서 읽은 글이 원하던 글인지. 여러 줄이면 앱마다 줄 사이를 다르게 잇기 때문에 줄바꿈 수는 보지 않는다.
    static func isSelection(_ selected: String, of wanted: String) -> Bool {
        func lines(_ s: String) -> [String] { normalize(s).components(separatedBy: "\n").filter { !$0.isEmpty } }
        guard wanted.contains(where: \.isNewline) else { return normalize(selected) == normalize(wanted) }
        return lines(selected) == lines(wanted)
    }

    private static func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        while t.hasSuffix("\n") { t.removeLast() }
        return t
    }

    /// 범위를 품는 온전한 줄(들). 위치가 맞는지 확인할 때 쓴다 — 짧은 글자는 엉뚱한 곳과 우연히 같을 수 있다.
    static func lineRange(around range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        var start = range.location, end = NSMaxRange(range)
        while start > 0, ns.character(at: start - 1) != 0x0A { start -= 1 }
        while end < ns.length, ns.character(at: end) != 0x0A { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// 넣기만 하는 편집(길이 0)은 선택으로 위치를 확인할 수 없다 → 같은 줄의 옆 글자를 품어 바꾸기로 만든다.
    static func anchored(_ edit: TextEdit, in text: String) -> TextEdit {
        guard edit.range.length == 0 else { return edit }
        let ns = text as NSString
        let at = edit.range.location
        if at > 0, ns.character(at: at - 1) != 0x0A {
            let c = ns.rangeOfComposedCharacterSequence(at: at - 1)
            if NSMaxRange(c) == at { return TextEdit(range: c, text: ns.substring(with: c) + edit.text) }
        }
        if at < ns.length, ns.character(at: at) != 0x0A {
            let c = ns.rangeOfComposedCharacterSequence(at: at)
            if c.location == at { return TextEdit(range: c, text: edit.text + ns.substring(with: c)) }
        }
        return edit
    }

    /// 글 조각들(앱이 준 순서)에서 범위에 걸치는 것들의 위치를 합친다. 걸치는 조각이 없으면 nil.
    static func union(of pieces: [(text: String, rect: CGRect)], covering range: NSRange, in text: String) -> CGRect? {
        let ns = text.replacingOccurrences(of: "\u{00A0}", with: " ") as NSString   // 길이가 같은 치환
        var cursor = 0
        var result: CGRect?
        for piece in pieces {
            let wanted = piece.text.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .newlines)
            guard !wanted.isEmpty, cursor < ns.length else { continue }
            let found = ns.range(of: wanted, options: .literal, range: NSRange(location: cursor, length: ns.length - cursor))
            guard found.location != NSNotFound else { continue }
            cursor = NSMaxRange(found)
            if NSIntersectionRange(found, range).length > 0, piece.rect.width > 0, piece.rect.height > 0 {
                result = result.map { $0.union(piece.rect) } ?? piece.rect
            }
        }
        return result
    }
}
