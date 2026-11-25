import Foundation

/// 키보드가 실제로 교정을 요청하는 곳 (결과는 메모리에만 기억)
@MainActor
final class KeyboardCorrector {
    private var cache = CorrectionCache(capacity: 30)

    var hasKey: Bool { Stub.isOn || Keychain.read(Keychain.openRouterAccount) != nil }

    func correct(_ target: KeyboardText.Target, level: CorrectionLevel) async throws -> String {
        let dictionary = PersonalDictionary.parse(SharedStore.dictionaryText)
        let key = CorrectionCache.Key(level: level, text: target.text, dictionary: dictionary)
        if let hit = cache.value(for: key) { return hit }
        let result: String
        if Stub.isOn {
            result = try await Stub.correct(target.text)
        } else {
            guard let apiKey = Keychain.read(Keychain.openRouterAccount) else { throw CorrectionError.missingKey }
            let client = OpenRouterClient(apiKey: apiKey)
            result = try await CorrectionPipeline.run(target.text, level: level) { input, stage in
                try await client.correct(input, level: stage, before: target.context, dictionary: dictionary)
            }
        }
        cache.insert(result, for: key)
        return result
    }
}

/// 시험용 가짜 교정 (디버그 빌드에서 앱 설정으로 켠 경우만). 시뮬레이터에 실제 키를 넣지 않고 동작을 확인한다.
enum Stub {
    static var isOn: Bool {
        #if DEBUG
        SharedStore.stubCorrections
        #else
        false
        #endif
    }

    static func correct(_ text: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(500))
        return [("않 ", "안 "), ("이번주", "이번 주"), ("금요일 까지", "금요일까지"), ("I has a", "I have an"), ("会議わ", "会議は")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}
