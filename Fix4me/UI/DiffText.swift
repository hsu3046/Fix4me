import SwiftUI

/// 원문은 취소선, 고친 글은 강조해서 보여 주는 글
enum DiffText {
    static func inline(_ segments: [TextDiff.Segment]) -> AttributedString {
        var out = AttributedString()
        var afterRemoval = false
        for segment in segments {
            switch segment {
            case let .same(t): out += AttributedString(t)
            case let .removed(t): out += removed(t)
            case let .added(t):
                // 화면에서만 살짝 띄운다 (취소선과 고친 글이 붙으면 한 단어로 읽힌다)
                if afterRemoval { out += AttributedString("\u{2009}") }
                out += added(t)
            }
            if case .removed = segment { afterRemoval = true } else { afterRemoval = false }
        }
        return out
    }

    /// 알림용: 앞쪽 몇 곳만 "~~않~~ 안"
    static func summary(_ hunks: [TextDiff.Hunk], limit: Int = 3) -> AttributedString {
        var out = AttributedString()
        for (i, h) in hunks.prefix(limit).enumerated() {
            if i > 0 { out += AttributedString("   ") }
            if !h.from.isEmpty { out += removed(shorten(h.from)) }
            if !h.from.isEmpty, !h.to.isEmpty { out += AttributedString(" ") }
            if !h.to.isEmpty { out += added(shorten(h.to)) }
        }
        if hunks.count > limit { out += AttributedString("  …") }
        return out
    }

    static func removed(_ t: String) -> AttributedString {
        var a = AttributedString(t)
        a.strikethroughStyle = .single
        a.foregroundColor = .red
        return a
    }

    static func added(_ t: String) -> AttributedString {
        var a = AttributedString(t)
        a.inlinePresentationIntent = .stronglyEmphasized
        a.foregroundColor = .green
        return a
    }

    private static func shorten(_ s: String) -> String {
        s.count > 16 ? s.prefix(15) + "…" : s
    }
}
