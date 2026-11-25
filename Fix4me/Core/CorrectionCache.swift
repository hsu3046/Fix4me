/// 교정 결과 캐시 (메모리 전용, 오래 안 쓴 것부터 버림).
struct CorrectionCache {
    struct Key: Hashable, Sendable {
        let level: CorrectionLevel
        let text: String
        var dictionary: [String] = []   // 사전이 바뀌면 예전 결과를 쓰지 않는다
    }

    let capacity: Int
    private var values: [Key: String] = [:]
    private var order: [Key] = []   // 뒤가 최근

    init(capacity: Int) { self.capacity = capacity }

    mutating func value(for key: Key) -> String? {
        guard let v = values[key] else { return nil }
        touch(key)
        return v
    }

    mutating func insert(_ value: String, for key: Key) {
        values[key] = value
        touch(key)
        while order.count > capacity { values[order.removeFirst()] = nil }
    }

    private mutating func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}
