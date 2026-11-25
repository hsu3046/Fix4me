import Foundation

/// 교정 범위 설정
enum ScopeMode: String, CaseIterable, Identifiable, Sendable {
    case auto        // 짧은 입력창은 전체, 긴 글은 바뀐 문단
    case paragraph   // 커서가 있는 문단
    case whole       // 입력창 전체

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "자동"
        case .paragraph: "커서 문단"
        case .whole: "입력창 전체"
        }
    }

    var summary: String {
        switch self {
        case .auto: "짧은 글(\(TextScope.wholeLimit)자 이하)은 전체를, 긴 글은 새로 쓰거나 바꾼 문단만 고쳐요."
        case .paragraph: "커서가 있는 문단만 고쳐요."
        case .whole: "입력창 전체를 고쳐요. 아주 긴 글은 나눠서 보내요."
        }
    }
}

/// 교정 대상 범위를 정하는 순수 함수 모음. AX 범위는 UTF-16 단위(NSString 기준)다.
enum TextScope {
    /// 요청 1건의 최대 길이 (UTF-16)
    static let maxLength = 4000
    /// 자동 모드에서 전체를 한 번에 보내는 상한
    static let wholeLimit = 1500
    /// "입력창 전체"로 다룰 최대 길이. 넘으면 안내하고 교정하지 않는다.
    static let wholeMaxLength = 20_000
    /// 긴 글에서 한 번에 다룰 바뀐 문단 수
    static let maxChangedParagraphs = 8
    /// 긴 글을 나눌 때 묶음 하나의 목표 길이
    private static let chunkLength = 1200

    /// 교정할 범위들 (앞에서부터, 서로 겹치지 않음). 교정할 글이 없으면 빈 배열.
    /// baseline: 이 입력창에서 "이미 처리된 것으로 보는" 글 (포커스를 얻었을 때나 마지막 교정 직후). 모르면 nil.
    static func plan(
        in value: String, selection: NSRange, mode: ScopeMode, level: CorrectionLevel, baseline: String?
    ) -> [NSRange] {
        let ns = value as NSString
        if selection.length > 0, selection.location >= 0, NSMaxRange(selection) <= ns.length {
            return isBlank(ns.substring(with: selection)) ? [] : [selection]
        }
        let cursor = min(max(selection.location, 0), ns.length)

        switch mode {
        case .paragraph:
            return cursorParagraph(in: ns, cursor: cursor).map { [$0] } ?? []

        case .whole:
            guard let whole = trimmedWhole(ns) else { return [] }
            // 다시 쓰기는 문단을 합치거나 옮길 수 있게 나누지 않는다 (길이 초과는 호출부가 안내)
            if whole.length <= wholeLimit || level == .rewrite { return [whole] }
            return chunks(in: ns)

        case .auto:
            guard let whole = trimmedWhole(ns) else { return [] }
            if whole.length <= wholeLimit { return [whole] }
            let changed = baseline.map { changedParagraphs(in: ns, baseline: $0) } ?? []
            if !changed.isEmpty { return nearest(changed, to: cursor) }
            return cursorParagraph(in: ns, cursor: cursor).map { [$0] } ?? []
        }
    }

    /// 범위 앞뒤의 글 (참고용 맥락). 범위가 글 전체면 빈 문자열.
    static func context(around range: NSRange, in value: String, limit: Int = 300) -> (before: String, after: String) {
        let ns = value as NSString
        let start = max(0, range.location - limit)
        let end = min(ns.length, NSMaxRange(range) + limit)
        // 이모지 같은 대리쌍 가운데에서 자르지 않도록 문자 경계로 맞춘다
        let before = range.location > start
            ? ns.substring(with: ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: range.location - start))) : ""
        let after = end > NSMaxRange(range)
            ? ns.substring(with: ns.rangeOfComposedCharacterSequences(for: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))) : ""
        return (before.trimmingCharacters(in: .whitespacesAndNewlines), after.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - 문단

    /// 공백뿐인 문단을 뺀 모든 문단 (끝 줄바꿈 제외)
    static func paragraphs(in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var location = 0
        while location < ns.length {
            let full = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let body = trimTrailingNewlines(full, in: ns)
            if body.length > 0, !isBlank(ns.substring(with: body)) { result.append(body) }
            location = max(NSMaxRange(full), location + 1)
        }
        return result
    }

    /// baseline 에 없던 문단들. 같은 문단이 여러 번 나오면 개수까지 맞춰 비교한다.
    static func changedParagraphs(in ns: NSString, baseline: String) -> [NSRange] {
        let old = baseline as NSString
        var remaining: [String: Int] = [:]
        for r in paragraphs(in: old) { remaining[old.substring(with: r), default: 0] += 1 }
        return paragraphs(in: ns).filter { r in
            let text = ns.substring(with: r)
            if let n = remaining[text], n > 0 { remaining[text] = n - 1; return false }
            return true
        }
    }

    /// 일부만 교정했을 때의 새 기준: 고친 문단만 처리된 것으로 더한다 (안 고친 문단은 계속 "바뀜"으로 남는다)
    static func baseline(_ old: String, adding processed: [String]) -> String {
        ([old] + processed).joined(separator: "\n")
    }

    private static func cursorParagraph(in ns: NSString, cursor: Int) -> NSRange? {
        let r = trimTrailingNewlines(ns.paragraphRange(for: NSRange(location: cursor, length: 0)), in: ns)
        return isBlank(ns.substring(with: r)) ? nil : r
    }

    /// 커서에서 가까운 문단부터 개수·총 길이 한도까지 고르고, 글 순서로 돌려준다.
    private static func nearest(_ ranges: [NSRange], to cursor: Int) -> [NSRange] {
        func distance(_ r: NSRange) -> Int {
            if cursor < r.location { return r.location - cursor }
            return max(0, cursor - NSMaxRange(r))
        }
        var picked: [NSRange] = [], total = 0
        for r in ranges.sorted(by: { distance($0) < distance($1) }) {
            guard picked.count < maxChangedParagraphs else { break }
            // 첫 문단은 길어도 담는다 (한도 초과 안내는 호출부가 한다)
            if !picked.isEmpty, total + r.length > maxLength { continue }
            picked.append(r); total += r.length
        }
        return picked.sorted { $0.location < $1.location }
    }

    /// 이웃한 문단을 묶어 요청 수를 줄인다
    private static func chunks(in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        for r in paragraphs(in: ns) {
            if let last = result.last, NSMaxRange(r) - last.location <= chunkLength {
                result[result.count - 1] = NSRange(location: last.location, length: NSMaxRange(r) - last.location)
            } else {
                result.append(r)
            }
        }
        return result
    }

    private static func trimmedWhole(_ ns: NSString) -> NSRange? {
        let all = paragraphs(in: ns)
        guard let first = all.first, let last = all.last else { return nil }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    /// 문단 끝 줄바꿈은 대상에서 뺀다 (교정 결과가 줄바꿈을 바꾸지 않도록)
    private static func trimTrailingNewlines(_ range: NSRange, in ns: NSString) -> NSRange {
        var r = range
        while r.length > 0 {
            let last = ns.character(at: NSMaxRange(r) - 1)
            guard last == 0x0A || last == 0x0D || last == 0x2029 || last == 0x2028 else { break }
            r.length -= 1
        }
        return r
    }

    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
