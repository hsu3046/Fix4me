import Foundation

/// 미리 교정으로 보내도 되는 글인지 (순수 함수). 단축키를 직접 누른 교정에는 적용하지 않는다.
enum PrecomputeFilter {
    static func isWorthChecking(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 6, !looksSecret(t) else { return false }
        // 띄어쓰기 없는 영숫자 한 덩어리는 주소·아이디·비밀번호일 가능성이 크다
        let hasCJK = t.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) }
        return hasCJK || t.contains { $0.isWhitespace }
    }

    /// API 키·토큰처럼 보이는 조각이 하나라도 있으면 통째로 보내지 않는다
    static func looksSecret(_ text: String) -> Bool {
        let prefixes = ["sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA", "AIza", "eyJ", "sb_secret_"]
        if text.contains("-----BEGIN") { return true }
        return text.split { $0.isWhitespace || "\"'`,;=:()<>".contains($0) }.contains { token in
            token.count >= 20 && prefixes.contains { token.hasPrefix($0) }
        }
    }
}
