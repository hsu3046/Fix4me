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

    /// 바뀐 묶음(hunk) 목록. HUD 의 "N곳 수정" 과 미리보기에 쓴다.
    static func hunks(old: String, new: String) -> [Hunk] {
        let a = Array(old), b = Array(new)
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        var result: [Hunk] = []
        var current: Hunk?
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let oldKept = i < a.count && !removed.contains(i)
            let newKept = j < b.count && !inserted.contains(j)
            if oldKept && newKept {
                if let h = current { result.append(h); current = nil }
                i += 1; j += 1
            } else if i < a.count && removed.contains(i) {
                current = current ?? Hunk(from: "", to: "")
                current!.from.append(a[i]); i += 1
            } else if j < b.count && inserted.contains(j) {
                current = current ?? Hunk(from: "", to: "")
                current!.to.append(b[j]); j += 1
            } else {
                break // 도달 불가 (방어)
            }
        }
        if let h = current { result.append(h) }
        return result
    }
}
