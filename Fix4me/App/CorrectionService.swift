import Foundation

/// 캐시 + 진행 중인 요청 공유. 미리 교정이 보낸 요청을 단축키가 이어받아 두 번 보내지 않는다.
@MainActor
final class CorrectionService {
    private var cache = CorrectionCache(capacity: 300)
    private var inFlight: [CorrectionCache.Key: Task<String, Error>] = [:]

    func cached(_ text: String, level: CorrectionLevel) -> String? {
        cache.value(for: .init(level: level, text: text))
    }

    func isInFlight(_ text: String, level: CorrectionLevel) -> Bool {
        inFlight[.init(level: level, text: text)] != nil
    }

    func correct(_ text: String, level: CorrectionLevel, before: String, after: String) async throws -> String {
        let key = CorrectionCache.Key(level: level, text: text)
        if let hit = cache.value(for: key) { return hit }
        if let running = inFlight[key] { return try await running.value }

        guard let apiKey = Keychain.read(Keychain.openRouterAccount), !apiKey.isEmpty else { throw CorrectionError.missingKey }
        let client = OpenRouterClient(apiKey: apiKey)
        let task = Task { try await client.correct(text, level: level, before: before, after: after) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        cache.insert(result, for: key)
        return result
    }
}
