import Foundation

/// 교정 대상 범위를 정하는 순수 함수 모음. AX 범위는 UTF-16 단위(NSString 기준)다.
enum TextScope {
    /// 한 번에 보낼 최대 길이 (UTF-16). 넘으면 교정하지 않고 안내한다.
    static let maxLength = 4000

    /// 선택 영역이 있으면 그 범위, 없으면 커서가 있는 문단(줄바꿈 제외)을 돌려준다.
    /// 공백뿐이면 nil.
    static func target(in value: String, selection: NSRange) -> NSRange? {
        let ns = value as NSString
        let clamped = NSRange(
            location: min(max(selection.location, 0), ns.length),
            length: 0
        )
        var range: NSRange
        if selection.length > 0, NSMaxRange(selection) <= ns.length {
            range = selection
        } else {
            range = ns.paragraphRange(for: clamped)
            // 문단 끝 줄바꿈은 대상에서 뺀다 (교정 결과가 줄바꿈을 바꾸지 않도록)
            while range.length > 0 {
                let last = ns.character(at: NSMaxRange(range) - 1)
                guard last == 0x0A || last == 0x0D || last == 0x2029 || last == 0x2028 else { break }
                range.length -= 1
            }
        }
        let text = ns.substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return range
    }
}
