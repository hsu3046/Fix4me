import Foundation

/// 최근에 본 입력창들의 상태 (메모리 전용 — 앱을 끄면 사라진다).
/// 디스크에 남기지 않는 이유: 입력창 식별자는 앱을 다시 켜면 달라져 짝지을 수 없고, 입력한 글이 파일로 쌓이게 된다.
struct FieldMemory<ID> {
    struct State: Equatable {
        var baseline: String        // 이미 처리된 것으로 보는 글
        var lastValue: String
        var lastChange: Date
        var ignored: Set<String> = []
    }

    private let capacity: Int
    private let same: (ID, ID) -> Bool
    private var entries: [(id: ID, state: State)] = []   // 뒤가 최근

    init(capacity: Int = 20, same: @escaping (ID, ID) -> Bool) {
        self.capacity = capacity
        self.same = same
    }

    subscript(id: ID) -> State? {
        get { entries.last { same($0.id, id) }?.state }
        set {
            entries.removeAll { same($0.id, id) }
            guard let newValue else { return }
            entries.append((id, newValue))
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
    }

    mutating func removeAll() { entries = [] }
}

/// 입력창의 글이 어떻게 달라졌는지. 사용자가 쓴 것과 다른 글이 들어온 것을 구별한다 (순수 함수).
enum FieldChange: Equatable {
    case none
    case edited     // 사용자가 쓰거나 고침 → 교정 대상
    case emptied    // 전송 등으로 비워짐 → 다음 글은 새 글
    case replaced   // 다른 문서·초안이 들어옴 → 원래 있던 글로 본다 (보내지 않는다)

    /// - Parameter resumed: 다른 곳에 있다가 이 입력창으로 돌아온 직후인지
    static func between(_ old: String, _ new: String, resumed: Bool) -> FieldChange {
        guard old != new else { return .none }
        if isBlank(new) { return .emptied }
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let removed = a.count - prefix - suffix, inserted = b.count - prefix - suffix

        // 돌아온 순간에는 키 몇 번 정도의 차이만 사용자의 입력으로 본다
        if resumed { return removed <= 3 && inserted <= 3 ? .edited : .replaced }
        // 있던 글이 거의 통째로 바뀜 (같은 입력창에 다른 메모·채널 초안이 열림)
        if a.count >= 10, inserted >= 10, removed * 10 >= a.count * 8 { return .replaced }
        // 빈 입력창에 긴 글이 한 번에 들어옴
        if isBlank(old), inserted >= 200 { return .replaced }
        return .edited
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
