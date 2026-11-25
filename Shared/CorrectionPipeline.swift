/// 강도별 호출 순서. 다시 쓰기는 먼저 교정하고 그 결과를 다시 쓴다
/// — 한 번에 하면 오타("않 고쳤어요")를 반대 뜻("싹 고쳤어요")으로 푸는 일이 잦다.
enum CorrectionPipeline {
    static func stages(for level: CorrectionLevel) -> [CorrectionLevel] {
        level == .rewrite ? [.proofread, .rewrite] : [level]
    }

    /// 지금 보여 줄 수 있는 가장 뒤 단계의 결과. 다시 쓰기가 끝나기 전에는 교정 결과를 먼저 보여 준다.
    /// 결과가 원문과 같으면(고칠 곳 없음) nil.
    static func best(
        for text: String, level: CorrectionLevel, cached: (CorrectionLevel) -> String?
    ) -> (level: CorrectionLevel, corrected: String)? {
        for stage in stages(for: level).reversed() {
            guard let result = cached(stage) else { continue }
            return result == text ? nil : (stage, result)
        }
        return nil
    }

    /// 앞 단계가 실패하면 뒤 단계를 하지 않고 그 오류를 그대로 던진다.
    static func run(
        _ text: String, level: CorrectionLevel, isolation: isolated (any Actor)? = #isolation,
        call: (String, CorrectionLevel) async throws -> String
    ) async throws -> String {
        var current = text
        for stage in stages(for: level) { current = try await call(current, stage) }
        return current
    }
}
