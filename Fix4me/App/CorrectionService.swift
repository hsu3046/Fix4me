import Foundation

/// 캐시 + 진행 중인 요청 공유. 미리 교정이 보낸 요청을 단축키가 이어받아 두 번 보내지 않는다.
@MainActor
final class CorrectionService {
    private var cache = CorrectionCache(capacity: 300)
    private var inFlight: [CorrectionCache.Key: Task<String, Error>] = [:]

    func cached(_ text: String, level: CorrectionLevel) -> String? {
        cache.value(for: .init(level: level, text: text, dictionary: Prefs.dictionary))
    }

    func isInFlight(_ text: String, level: CorrectionLevel) -> Bool {
        inFlight[.init(level: level, text: text, dictionary: Prefs.dictionary)] != nil
    }

    func correct(_ text: String, level: CorrectionLevel, before: String) async throws -> String {
        guard SharedStore.isOn else { throw CorrectionError.off }
        let dictionary = Prefs.dictionary
        let key = CorrectionCache.Key(level: level, text: text, dictionary: dictionary)
        if let hit = cache.value(for: key) { return hit }
        if let running = inFlight[key] { return try await running.value }

        guard let apiKey = Keychain.read(Keychain.openRouterAccount), !apiKey.isEmpty else { throw CorrectionError.missingKey }
        let client = OpenRouterClient(apiKey: apiKey)
        let task = Task {
            try await CorrectionPipeline.run(text, level: level) { input, stage in
                // 마지막이 아닌 단계(다시 쓰기 앞의 교정)는 캐시·진행 중 요청을 함께 쓴다
                if stage != level { return try await correct(input, level: stage, before: before) }
                guard SharedStore.isOn else { throw CorrectionError.off }   // 앞 단계를 기다리는 동안 껐을 수 있다
                return try await client.correct(input, level: stage, before: before, dictionary: dictionary)
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        cache.insert(result, for: key)
        return result
    }
}
