import Foundation

/// 정해 둔 글로 교정 결과를 채점한다 (프롬프트·모델을 바꿀 때 나빠졌는지 보기 위해).
struct EvalCase: Codable, Sendable {
    let id: String
    let text: String
    /// 비우면 모든 강도
    var levels: [String]?
    /// 결과에 모두 있어야 하는 정규식
    var require: [String]?
    /// 결과에 하나라도 있으면 실패인 정규식
    var reject: [String]?
    /// 글자 하나도 바뀌면 안 되는 글
    var unchanged: Bool?
    /// 줄 수가 그대로여야 하는 글
    var keepLines: Bool?

    func runs(at level: CorrectionLevel) -> Bool { levels?.contains(level.rawValue) ?? true }

    /// 실패 이유. 통과면 nil.
    func failure(_ output: String) -> String? {
        if unchanged == true, output != text { return "바뀌면 안 됨" }
        if keepLines == true, output.components(separatedBy: "\n").count != text.components(separatedBy: "\n").count { return "줄 수가 바뀜" }
        for p in reject ?? [] where Self.matches(output, p) { return "있으면 안 됨: \(p)" }
        for p in require ?? [] where !Self.matches(output, p) { return "없음: \(p)" }
        return nil
    }

    /// 잘못된 정규식이나 강도 이름은 채점 전에 알린다 (조용히 통과하지 않도록)
    var problem: String? {
        for p in (require ?? []) + (reject ?? []) where (try? NSRegularExpression(pattern: p)) == nil { return "정규식 오류: \(p)" }
        for l in levels ?? [] where CorrectionLevel(rawValue: l) == nil { return "모르는 강도: \(l)" }
        if require == nil, reject == nil, unchanged == nil, keepLines == nil { return "채점 기준이 없음" }
        return nil
    }

    static func load(_ data: Data) throws -> [EvalCase] {
        try data.split(separator: 0x0A).filter { !$0.allSatisfy { $0 == 0x20 || $0 == 0x0D } }
            .map { try JSONDecoder().decode(EvalCase.self, from: Data($0)) }
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}
