import Foundation

/// LLM 응답 해석과 이상 응답 차단 (순수 함수).
enum CorrectionParser {
    enum ParseError: Error, Equatable {
        case noJSON
        case invalidJSON
    }

    private struct Payload: Decodable { let corrected: String }

    /// 응답 본문에서 `{"corrected": "..."}` 를 꺼낸다. 앞뒤 잡문·코드펜스가 있어도 첫 `{` ~ 마지막 `}` 만 해석.
    static func parse(_ content: String) throws -> String {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end else { throw ParseError.noJSON }
        let json = String(content[start...end])
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ParseError.invalidJSON
        }
        return payload.corrected
    }

    /// 앱이 입력을 감싼 `<text>\n…\n</text>` 를 모델이 결과에 옮겨 왔으면 벗긴다.
    /// 여는·닫는 태그가 **둘 다** 결과 양 끝에 있을 때만 함께 제거 (한쪽만 지우면 본문이 잘릴 수 있다).
    /// 원문 자체가 그 태그로 시작·끝나면 사용자 내용이므로 건드리지 않는다.
    static func unwrapTextTags(_ corrected: String, original: String) -> String {
        let open = "<text>", close = "</text>"
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if o.hasPrefix(open) || o.hasSuffix(close) { return corrected }

        let c = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.hasPrefix(open), c.hasSuffix(close), c.count >= open.count + close.count else { return corrected }
        var inner = String(c.dropFirst(open.count).dropLast(close.count))
        // 래퍼가 붙인 줄바꿈 한 개씩만 제거 (원문의 앞뒤 줄바꿈은 보존)
        if inner.hasPrefix("\n") { inner.removeFirst() }
        if inner.hasSuffix("\n") { inner.removeLast() }
        return inner
    }

    /// 교정이 아니라 "대답"이나 "번역"을 내놓은 경우를 길이로 거른다.
    /// 짧은 글은 절대 차이, 긴 글은 비율로 판정.
    static func isPlausible(original: String, corrected: String) -> Bool {
        let o = original.count, c = corrected.count
        guard c > 0 else { return false }
        if o < 20 { return abs(o - c) <= 12 }
        let ratio = Double(c) / Double(o)
        return ratio >= 0.6 && ratio <= 1.5
    }
}
