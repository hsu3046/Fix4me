import Foundation
import NaturalLanguage

/// 글을 규칙만으로 섹션으로 나눈다 (LLM 없음, 같은 글은 항상 같게). 범위는 UTF-16 단위.
enum Sectioner {
    /// 이보다 짧은 덩어리는 이웃과 합친다
    static let minLength = 40
    /// 이보다 긴 덩어리는 줄바꿈 → 문장 끝 순서로 나눈다
    static let maxLength = 600
    private static let contextLimit = 300

    enum Kind: Equatable {
        case text, heading, list
        case divider, code, quote, table, url, signature

        /// 보내지도 고치지도 않는 부분
        var isProtected: Bool {
            switch self {
            case .text, .heading, .list: false
            case .divider, .code, .quote, .table, .url, .signature: true
            }
        }
    }

    enum Boundary: Int, Comparable {
        case weak, medium, strong
        static func < (a: Boundary, b: Boundary) -> Bool { a.rawValue < b.rawValue }
    }

    struct Block: Equatable {
        var range: NSRange
        let kind: Kind
        let boundary: Boundary   // 이 덩어리 앞 경계의 강도
    }

    // MARK: - 교정 단위

    /// 교정 단위들 (앞에서부터). 강한 경계와 보호 구역을 넘지 않는다.
    static func units(in text: String, level: CorrectionLevel) -> [NSRange] {
        let ns = text as NSString
        // 교정은 앞뒤 흐름이 덜 필요하다 → 약한 경계에서도 나눈다
        let splitAt: Boundary = level == .proofread ? .weak : .medium

        var result: [NSRange] = []
        var group: [(range: NSRange, boundary: Boundary)] = []   // 강한 경계 사이의 덩어리들
        func flush() {
            result += pack(group, splitAt: splitAt)
            group = []
        }
        var afterHeading = false
        for block in blocks(in: text) {
            if block.boundary == .strong || block.kind.isProtected { flush() }
            if block.kind.isProtected { afterHeading = false; continue }
            let pieces = split(block.range, in: ns)
            for (i, piece) in pieces.enumerated() {
                if i == 0, afterHeading, let last = group.popLast() {
                    // 제목은 뒤따르는 본문과 한 덩어리 (빈 줄이 있어도)
                    group.append((union(last.range, piece), last.boundary))
                } else {
                    group.append((piece, i == 0 ? block.boundary : .medium))
                }
            }
            afterHeading = block.kind == .heading
        }
        flush()
        return result
    }

    /// 참고 문맥: 가장 가까운 제목 + 바로 앞 덩어리 (글 전체를 보내지 않는다)
    static func context(before range: NSRange, in text: String) -> String {
        let ns = text as NSString
        let previous = blocks(in: text).filter { !$0.kind.isProtected && NSMaxRange($0.range) <= range.location }
        guard let last = previous.last else { return "" }
        var parts: [String] = []
        if let heading = previous.last(where: { $0.kind == .heading }), heading != last {
            parts.append(ns.substring(with: heading.range))
        }
        let start = max(last.range.location, NSMaxRange(last.range) - contextLimit)
        let tail = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: NSMaxRange(last.range) - start))
        parts.append(ns.substring(with: tail))
        return parts.joined(separator: "\n")
    }

    private static func pack(_ group: [(range: NSRange, boundary: Boundary)], splitAt: Boundary) -> [NSRange] {
        var out: [NSRange] = []
        for (i, item) in group.enumerated() {
            guard i > 0, let last = out.last else { out.append(item.range); continue }
            let joined = union(last, item.range)
            let fits = joined.length <= maxLength
            let wantsSplit = item.boundary >= splitAt && last.length >= minLength
            if fits, !wantsSplit { out[out.count - 1] = joined } else { out.append(item.range) }
        }
        // 끝에 남은 짧은 조각은 앞과 합친다
        if out.count >= 2, out[out.count - 1].length < minLength {
            let joined = union(out[out.count - 2], out[out.count - 1])
            if joined.length <= maxLength { out.removeLast(2); out.append(joined) }
        }
        return out
    }

    /// 긴 덩어리를 줄바꿈 → 문장 끝에서 나눈다. 한 문장이 길면 그대로 둔다.
    private static func split(_ range: NSRange, in ns: NSString) -> [NSRange] {
        guard range.length > maxLength else { return [range] }
        var atoms: [NSRange] = []
        for line in lines(in: ns, within: range) {
            if line.length <= maxLength { atoms.append(line); continue }
            let text = ns.substring(with: line)
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            for r in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
                let n = NSRange(r, in: text)
                atoms.append(NSRange(location: line.location + n.location, length: n.length))
            }
        }
        var out: [NSRange] = []
        for atom in atoms where atom.length > 0 {
            if let last = out.last, NSMaxRange(atom) - last.location <= maxLength { out[out.count - 1] = union(last, atom) }
            else { out.append(atom) }
        }
        return out.map { trim($0, in: ns) }.filter { $0.length > 0 }
    }

    // MARK: - 덩어리

    static func blocks(in text: String) -> [Block] {
        let ns = text as NSString
        let all = lines(in: ns, within: NSRange(location: 0, length: ns.length))
        let kinds = classify(all.map { ns.substring(with: $0) })
        let perLine = habit(zip(all, kinds).compactMap { $1 == .text ? ns.substring(with: $0) : nil }, hasBlankBetween: hasInnerBlank(kinds)) == .linePerParagraph

        var out: [Block] = []
        var blanks = 0
        for (range, kind) in zip(all, kinds) {
            guard let kind else { blanks += 1; continue }
            defer { blanks = 0 }
            guard let last = out.last else { out.append(Block(range: range, kind: kind, boundary: .strong)); continue }
            let touching = blanks == 0
            // 같은 종류가 붙어 있으면 이어 붙인다 (제목은 한 줄씩, 줄=문단 습관이면 본문도 한 줄씩)
            if touching, kind == last.kind, kind != .heading, !(kind == .text && perLine) {
                out[out.count - 1].range = union(last.range, range)
                continue
            }
            let boundary: Boundary
            if blanks >= 2 || kind == .heading || kind.isProtected || last.kind.isProtected { boundary = .strong }
            else if blanks == 1 || kind != last.kind { boundary = .medium }
            else { boundary = .weak }
            out.append(Block(range: range, kind: kind, boundary: boundary))
        }
        return out
    }

    // MARK: - 줄바꿈 습관

    enum Habit: Equatable { case blankSeparated, linePerParagraph, hardWrapped }

    /// 본문 줄들로 이 글에서 줄바꿈 하나가 무슨 뜻인지 정한다.
    static func habit(_ textLines: [String], hasBlankBetween: Bool) -> Habit {
        guard !hasBlankBetween, textLines.count >= 2 else { return .blankSeparated }
        let widths = textLines.map(width)
        let longest = widths.max() ?? 0
        let ended = textLines.filter(endsSentence).count

        // 일정 폭에서 잘린 글: 마지막 줄 말고는 길이가 비슷하고 대부분 문장 중간에서 끊긴다
        if textLines.count >= 4, longest >= 40 {
            let body = zip(widths, textLines).dropLast()
            let wrapped = body.filter { Double($0) >= Double(longest) * 0.8 && !endsSentence($1) }.count
            if Double(wrapped) >= Double(body.count) * 0.7 { return .hardWrapped }
        }
        // 긴 줄이 문장으로 끝나며 이어지는 글: 줄 하나가 문단
        let median = widths.sorted()[widths.count / 2]
        if median >= 60, Double(ended) >= Double(textLines.count) * 0.5 { return .linePerParagraph }
        return .blankSeparated
    }

    /// 화면 폭 (한·중·일 글자는 2칸)
    private static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) }
    }

    private static func endsSentence(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)」』)"))
        guard let c = t.last else { return false }
        return ".!?。！？…~".contains(c)
    }

    private static func hasInnerBlank(_ kinds: [Kind?]) -> Bool {
        guard let first = kinds.firstIndex(where: { $0 != nil }), let last = kinds.lastIndex(where: { $0 != nil }) else { return false }
        return kinds[first...last].contains { $0 == nil }
    }

    // MARK: - 줄 종류

    /// 줄마다 종류 (빈 줄은 nil). 이웃 줄을 봐야 정해지는 것(번호 제목·기호 제목·코드·서명)도 여기서.
    static func classify(_ lines: [String]) -> [Kind?] {
        var kinds: [Kind?] = []
        var inFence = false, inSignature = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inSignature { kinds.append(line.isEmpty ? nil : .signature); continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { kinds.append(.code); inFence.toggle(); continue }
            if inFence { kinds.append(.code); continue }   // 닫지 않은 코드는 글 끝까지 보호
            if line.isEmpty { kinds.append(nil); continue }
            if line == "--" { inSignature = true; kinds.append(.signature); continue }

            let previous = i > 0 ? lines[i - 1].trimmingCharacters(in: .whitespaces) : ""
            let next = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
            if matches(line, dividerPattern) { kinds.append(.divider) }
            else if line.hasPrefix(">") || line.hasPrefix("＞") { kinds.append(.quote) }
            else if line.count > 2, line.hasPrefix("|"), line.hasSuffix("|") { kinds.append(.table) }
            else if matches(line, urlPattern) { kinds.append(.url) }
            else if matches(line, #"^#{1,6}\s+\S"#) || matches(line, bracketHeadingPattern) { kinds.append(.heading) }
            else if matches(line, symbolPattern) {
                // ■ 제목 / 같은 기호가 이어지면 목록
                let symbol = line.first!
                let repeated = previous.first == symbol || next.first == symbol
                kinds.append(repeated ? .list : (isTitleLike(line) ? .heading : .list))
            }
            else if matches(line, numberPattern) {
                // "1. 개요" 제목 / 번호가 이어지거나 문장이면 목록
                let repeated = matches(previous, numberPattern) || matches(next, numberPattern)
                kinds.append(!repeated && previous.isEmpty && isTitleLike(line) && hasBody(after: i, in: lines) ? .heading : .list)
            }
            else if matches(line, bulletPattern) { kinds.append(.list) }
            // 목록 항목의 들여쓴 다음 줄
            else if kinds.last == .some(.list), !previous.isEmpty, raw.hasPrefix("  ") || raw.hasPrefix("\t") { kinds.append(.list) }
            else { kinds.append(.text) }
        }
        return kinds
    }

    private static let dividerPattern = #"^([-*_=─━~・＊·])(\s*\1){2,}$"#
    private static let urlPattern = #"^<?https?://\S+>?$"#
    private static let bracketHeadingPattern = #"^(【[^】]{1,40}】.{0,30}|\[[^\]]{1,40}\]|〈[^〉]{1,40}〉|《[^》]{1,40}》)$"#
    private static let symbolPattern = #"^[■□◆◇●○▶▷★☆◎]\s*\S"#
    private static let numberPattern = #"^(\d{1,2}[.)]|\(\d{1,2}\))\s+\S"#
    private static let bulletPattern = #"^([-*+–]\s+\S|[•・‣▪◦·]\s*\S|[①-⑳]\s*\S|[A-Za-z][.)]\s+\S)"#

    private static func isTitleLike(_ line: String) -> Bool { line.count <= 30 && !endsSentence(line) }

    /// 제목이려면 뒤에 번호 없는 본문이 있어야 한다
    private static func hasBody(after i: Int, in lines: [String]) -> Bool {
        guard let body = lines.dropFirst(i + 1).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return false }
        return !matches(body, numberPattern)
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - 범위

    /// 줄바꿈을 뺀 줄들
    private static func lines(in ns: NSString, within range: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var location = range.location
        while location < NSMaxRange(range) {
            var end = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let stop = min(contentsEnd, NSMaxRange(range))
            out.append(NSRange(location: location, length: max(0, stop - location)))
            location = max(end, location + 1)
        }
        return out
    }

    private static func union(_ a: NSRange, _ b: NSRange) -> NSRange {
        NSRange(location: a.location, length: NSMaxRange(b) - a.location)
    }

    /// 앞뒤 공백·줄바꿈 제외 (나눈 조각 사이의 띄어쓰기는 교정 대상에 넣지 않는다)
    private static func trim(_ r: NSRange, in ns: NSString) -> NSRange {
        var start = r.location, end = NSMaxRange(r)
        let ws = CharacterSet.whitespacesAndNewlines
        func isSpace(_ i: Int) -> Bool { Unicode.Scalar(ns.character(at: i)).map(ws.contains) ?? false }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
}
