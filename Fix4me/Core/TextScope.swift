import Foundation

/// 교정 범위 설정
enum ScopeMode: String, CaseIterable, Identifiable, Sendable {
    case auto        // 바뀐 섹션 (없으면 커서 섹션)
    case paragraph   // 커서가 있는 섹션 (저장값 호환을 위해 이름 유지)
    case whole       // 입력창의 모든 섹션

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "자동"
        case .paragraph: "커서 섹션"
        case .whole: "모든 섹션"
        }
    }

    var summary: String {
        switch self {
        case .auto: "새로 쓰거나 바꾼 섹션만 고쳐요. 바뀐 곳이 없으면 커서가 있는 섹션을 고쳐요."
        case .paragraph: "커서가 있는 섹션만 고쳐요."
        case .whole: "입력창의 모든 섹션을 나눠서 고쳐요."
        }
    }
}

/// 교정 대상 범위를 정하는 순수 함수 모음. AX 범위는 UTF-16 단위(NSString 기준)다.
enum TextScope {
    /// 요청 1건의 최대 길이 (UTF-16)
    static let maxLength = 4000
    /// 다룰 글의 최대 길이. 넘으면 안내하고 교정하지 않는다.
    static let wholeMaxLength = 20_000
    /// 자동에서 한 번에 다룰 바뀐 섹션 수
    static let maxChangedUnits = 8

    /// 교정할 범위들 (앞에서부터, 서로 겹치지 않음). 교정할 글이 없으면 빈 배열.
    /// baseline: 이 입력창에서 "이미 처리된 것으로 보는" 글. 모르면 nil.
    static func plan(
        in value: String, selection: NSRange, mode: ScopeMode, level: CorrectionLevel, baseline: String?
    ) -> [NSRange] {
        let ns = value as NSString
        if selection.length > 0, selection.location >= 0, NSMaxRange(selection) <= ns.length {
            return isBlank(ns.substring(with: selection)) ? [] : [selection]
        }
        let cursor = min(max(selection.location, 0), ns.length)
        let units = Sectioner.units(in: value, level: level)
        switch mode {
        case .whole: return units
        case .paragraph: return cursorUnit(units, cursor: cursor)
        case .auto:
            let changed = baseline.map { changedUnits(units, in: value, baseline: $0) } ?? []
            return changed.isEmpty ? cursorUnit(units, cursor: cursor) : nearest(changed, to: cursor)
        }
    }

    /// 미리 교정할 범위: 어느 모드든 사용자가 바꾼 섹션만 (원래 있던 글은 보내지 않는다)
    static func precomputePlan(
        in value: String, cursor: Int, mode: ScopeMode, level: CorrectionLevel, baseline: String
    ) -> [NSRange] {
        let targets = plan(in: value, selection: NSRange(location: cursor, length: 0), mode: mode, level: level, baseline: baseline)
        return nearest(changedUnits(targets, in: value, baseline: baseline), to: cursor)
    }

    /// 바뀐 문단이 하나라도 들어 있는 단위
    static func changedUnits(_ units: [NSRange], in value: String, baseline: String) -> [NSRange] {
        let changed = changedParagraphs(in: value as NSString, baseline: baseline)
        return units.filter { u in changed.contains { NSIntersectionRange($0, u).length > 0 } }
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

    /// 커서가 들어 있는 단위. 빈 줄이나 보호 구역(코드·인용 등)에 있으면 없음.
    private static func cursorUnit(_ units: [NSRange], cursor: Int) -> [NSRange] {
        units.first { cursor >= $0.location && cursor <= NSMaxRange($0) }.map { [$0] } ?? []
    }

    /// 커서에서 가까운 것부터 개수·총 길이 한도까지 고르고, 글 순서로 돌려준다.
    private static func nearest(_ ranges: [NSRange], to cursor: Int) -> [NSRange] {
        func distance(_ r: NSRange) -> Int {
            if cursor < r.location { return r.location - cursor }
            return max(0, cursor - NSMaxRange(r))
        }
        var picked: [NSRange] = [], total = 0
        for r in ranges.sorted(by: { distance($0) < distance($1) }) {
            guard picked.count < maxChangedUnits else { break }
            // 첫 단위는 길어도 담는다 (한도 초과 안내는 호출부가 한다)
            if !picked.isEmpty, total + r.length > maxLength { continue }
            picked.append(r); total += r.length
        }
        return picked.sorted { $0.location < $1.location }
    }

    /// 문단 끝 줄바꿈은 뺀다
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
