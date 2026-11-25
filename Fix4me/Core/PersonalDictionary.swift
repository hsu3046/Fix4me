import Foundation

/// 고치지 말아야 할 단어 (설정에서 한 줄에 하나씩).
enum PersonalDictionary {
    static let maxWords = 200
    private static let maxLength = 60

    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= maxLength && seen.insert($0).inserted }
            .prefix(maxWords).map { $0 }
    }

    /// 사전 단어가 사라지거나 바뀐 줄은 원문으로 되돌린다. 줄 수가 달라 줄을 짝지을 수 없으면 전체를 원문으로.
    static func enforce(original: String, corrected: String, words: [String]) -> String {
        guard !words.isEmpty, violates(original, corrected, words) else { return corrected }
        let a = original.components(separatedBy: "\n"), b = corrected.components(separatedBy: "\n")
        guard a.count == b.count, a.count > 1 else { return original }
        return zip(a, b).map { violates($0, $1, words) ? $0 : $1 }.joined(separator: "\n")
    }

    private static func violates(_ original: String, _ corrected: String, _ words: [String]) -> Bool {
        words.contains { count($0, in: corrected) < count($0, in: original) }
    }

    private static func count(_ word: String, in text: String) -> Int {
        text.components(separatedBy: word).count - 1
    }
}
