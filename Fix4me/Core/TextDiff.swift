import Foundation

/// 글의 한 구간을 바꾸는 편집 (UTF-16 범위)
struct TextEdit: Equatable, Sendable {
    let range: NSRange
    let text: String
}

/// 원문과 교정문의 차이 계산. 문자(Character, 한글 음절·이모지 단위) 기준.
enum TextDiff {
    struct Hunk: Equatable {
        var from: String
        var to: String
    }

    /// 공통 접두·접미를 뺀 가운데 바뀐 구간. AX 쓰기를 최소 범위로 하기 위해 UTF-16 오프셋으로 돌려준다.
    /// 바뀐 게 없으면 nil.
    static func changedSpan(old: String, new: String) -> (oldRange: NSRange, replacement: String)? {
        guard old != new else { return nil }
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let start16 = String(a[0..<prefix]).utf16.count
        let oldMid16 = String(a[prefix..<(a.count - suffix)]).utf16.count
        let replacement = String(b[prefix..<(b.count - suffix)])
        return (NSRange(location: start16, length: oldMid16), replacement)
    }

    /// 원문에 적용할 편집 목록 (앞에서부터, old 기준 UTF-16 범위).
    /// 줄 수가 같으면 바뀐 줄만 따로 고쳐 안 바뀐 줄의 서식·멘션을 건드리지 않는다. 줄 수가 다르면 한 구간으로.
    static func edits(old: String, new: String) -> [TextEdit] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        guard a.count == b.count else {
            return changedSpan(old: old, new: new).map { [TextEdit(range: $0.oldRange, text: $0.replacement)] } ?? []
        }
        var result: [TextEdit] = [], offset = 0
        for (x, y) in zip(a, b) {
            if let span = changedSpan(old: x, new: y) {
                result.append(TextEdit(
                    range: NSRange(location: offset + span.oldRange.location, length: span.oldRange.length),
                    text: span.replacement
                ))
            }
            offset += x.utf16.count + 1
        }
        return result
    }

    /// edits(앞에서부터, 겹치지 않음)를 모두 적용한 글
    static func apply(_ edits: [TextEdit], to value: String) -> String {
        edits.reversed().reduce(value) { ($0 as NSString).replacingCharacters(in: $1.range, with: $1.text) }
    }

    /// 편집을 모두 적용했을 때 원래 위치가 어디로 가는지 (커서 복원). 바뀐 구간 안이면 그 구간 끝.
    static func shift(_ location: Int, by edits: [TextEdit]) -> Int {
        var delta = 0
        for e in edits {
            let inserted = (e.text as NSString).length
            if location >= NSMaxRange(e.range) { delta += inserted - e.range.length }
            else if location > e.range.location { return e.range.location + delta + inserted }
            else { break }
        }
        return location + delta
    }

    /// 모두 적용한 뒤의 글에서 되돌리는 편집 (앞에서부터)
    static func inverse(of edits: [TextEdit], in original: String) -> [TextEdit] {
        let ns = original as NSString
        var shift = 0
        return edits.map { e in
            let inserted = (e.text as NSString).length
            let back = TextEdit(range: NSRange(location: e.range.location + shift, length: inserted),
                                text: ns.substring(with: e.range))
            shift += inserted - e.range.length
            return back
        }
    }

    /// 화면에 보여 줄 비교 조각
    enum Segment: Equatable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// 단어 단위 비교 (취소선 미리보기용). same+removed 를 이으면 old, same+added 를 이으면 new.
    static func segments(old: String, new: String) -> [Segment] {
        let a = tokens(old), b = tokens(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        // (같은 글) 과 (지움, 넣음) 묶음이 번갈아 나오도록 모은다
        struct Group { var same = "", del = "", ins = "" }
        var groups = [Group()]
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { groups[groups.count - 1].del += a[i]; i += 1 }
            else if j < b.count, inserted.contains(j) { groups[groups.count - 1].ins += b[j]; j += 1 }
            else if i < a.count, j < b.count {
                let last = groups[groups.count - 1]
                if !last.del.isEmpty || !last.ins.isEmpty { groups.append(Group()) }
                groups[groups.count - 1].same += a[i]   // same 은 묶음의 앞에 온다
                i += 1; j += 1
            } else { break }
        }

        // 바뀐 단어 사이에 공백만 있으면 한 묶음으로 (띄엄띄엄 끊겨 보이지 않게)
        var merged: [Group] = []
        for g in groups {
            if let last = merged.last, !last.del.isEmpty || !last.ins.isEmpty, !g.del.isEmpty || !g.ins.isEmpty,
               !g.same.isEmpty, !g.same.contains("\n"), g.same.allSatisfy(\.isWhitespace) {
                merged[merged.count - 1].del += g.same + g.del
                merged[merged.count - 1].ins += g.same + g.ins
            } else {
                merged.append(g)
            }
        }
        return merged.flatMap { g -> [Segment] in
            var out: [Segment] = []
            if !g.same.isEmpty { out.append(.same(g.same)) }
            if !g.del.isEmpty { out.append(.removed(g.del)) }
            if !g.ins.isEmpty { out.append(.added(g.ins)) }
            return out
        }
    }

    /// 바뀐 곳 목록 ("N곳", 알림의 앞부분). 이어진 지움+넣음은 한 곳.
    static func hunks(old: String, new: String) -> [Hunk] {
        var result: [Hunk] = []
        var afterRemoval = false
        for segment in segments(old: old, new: new) {
            switch segment {
            case .same: afterRemoval = false
            case let .removed(t): result.append(Hunk(from: t, to: "")); afterRemoval = true
            case let .added(t):
                if afterRemoval { result[result.count - 1].to = t } else { result.append(Hunk(from: "", to: t)) }
                afterRemoval = false
            }
        }
        return result
    }

    /// 대부분 바뀌어 단어별 취소선이 오히려 읽기 어려운지 (남은 글이 40% 미만)
    static func isMostlyChanged(_ segments: [Segment]) -> Bool {
        var same = 0, old = 0
        for segment in segments {
            switch segment {
            case let .same(t): same += t.count; old += t.count
            case let .removed(t): old += t.count
            case .added: break
            }
        }
        return old >= 20 && Double(same) / Double(old) < 0.4
    }

    /// 단어(글자·숫자 이어짐), 공백, 그 밖의 한 글자. 띄어쓰기가 없는 가나·한자는 한 글자씩.
    private static func tokens(_ s: String) -> [String] {
        enum Kind { case word, space, single }
        func kind(_ c: Character) -> Kind {
            if c == "\n" { return .single }
            if c.isWhitespace { return .space }
            if let v = c.unicodeScalars.first?.value, (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v) { return .single }
            return c.isLetter || c.isNumber || c == "'" || c == "’" ? .word : .single
        }
        var result: [String] = [], last: Kind?
        for c in s {
            let k = kind(c)
            if k != .single, k == last { result[result.count - 1].append(c) } else { result.append(String(c)) }
            last = k
        }
        return result
    }
}
