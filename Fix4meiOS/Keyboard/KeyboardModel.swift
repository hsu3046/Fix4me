import Foundation
import Observation

@MainActor
@Observable
final class KeyboardModel {
    enum State: Equatable {
        case needsFullAccess
        case needsKey
        case reading
        case empty
        case working(String)
        case result(original: String, corrected: String)
        case noChange
        case applied
        case error(String)
    }

    /// 마지막으로 적용한 것. 키보드는 열 때마다 새로 만들어지므로 프로세스에 둔다 (메모리에만, 디스크에 남기지 않음)
    private struct Applied {
        let original: String
        let corrected: String
    }
    private static var applied: Applied?

    private(set) var state = State.reading
    var level = CorrectionLevel.current {
        didSet {
            guard level != oldValue else { return }
            CorrectionLevel.save(level)
            run()
        }
    }
    @ObservationIgnored private let session: KeyboardSession
    @ObservationIgnored private let hasFullAccess: () -> Bool
    @ObservationIgnored private let close: () -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cache = CorrectionCache(capacity: 30)
    @ObservationIgnored private var text: KeyboardText?
    @ObservationIgnored private var target: KeyboardText.Target?
    @ObservationIgnored private var touching = false    // 우리가 커서를 옮기거나 쓰는 중

    init(session: KeyboardSession, hasFullAccess: @escaping () -> Bool, close: @escaping () -> Void) {
        self.session = session
        self.hasFullAccess = hasFullAccess
        self.close = close
    }

    /// 키보드가 열릴 때
    func open() {
        level = CorrectionLevel.current   // 앱에서 바꾼 강도 (바뀌었으면 아래에서 다시 시작한다)
        run(offerRevert: true)
    }

    /// 우리가 한 일이 아닌 변경: 보여 준 결과가 더는 맞지 않는다
    func textMayHaveChanged() {
        guard !touching, case .result = state else { return }
        guard session.proxy.selected == (text?.selected ?? ""), KeyboardSession.agrees(session.proxy.before, withEndOf: text?.before ?? "") else {
            return state = .error(KeyboardError.changed.localizedDescription)
        }
    }

    /// - Parameter offerRevert: 커서 앞이 방금 고친 글이면 교정 대신 되돌리기를 보인다
    func run(offerRevert: Bool = false) {
        task?.cancel()
        guard hasFullAccess() else { return state = .needsFullAccess }
        guard Stub.isOn || Keychain.read(Keychain.openRouterAccount) != nil else { return state = .needsKey }
        state = .reading
        task = Task { await correct(offerRevert: offerRevert) }
    }

    private func correct(offerRevert: Bool) async {
        do {
            touching = true
            defer { touching = false }
            let read = try await session.read()
            guard !Task.isCancelled else { return }
            text = read
            if offerRevert, let applied = Self.applied, read.selected.isEmpty, read.before.hasSuffix(applied.corrected) {
                return state = .applied
            }
            target = read.target(level: level)
        } catch {
            return state = .error(error.localizedDescription)
        }
        guard let target else { return state = .empty }
        let level = self.level
        state = .working(level.workingTitle)
        do {
            let corrected = try await corrected(target, level: level)
            guard !Task.isCancelled else { return }
            state = corrected == target.text ? .noChange : .result(original: target.text, corrected: corrected)
        } catch {
            if !Task.isCancelled { state = .error(error.localizedDescription) }
        }
    }

    private func corrected(_ target: KeyboardText.Target, level: CorrectionLevel) async throws -> String {
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

    func apply() {
        guard case let .result(original, corrected) = state, let text, let target else { return }
        touching = true
        Task {
            defer { touching = false }
            do {
                try await session.apply(target, in: text, corrected: corrected)
                Self.applied = Applied(original: original, corrected: corrected)
                state = .applied
                close()   // 쓰던 키보드로 돌아간다
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// 커서 바로 앞이 고친 글일 때만 되돌린다
    func revert() {
        guard let applied = Self.applied else { return }
        touching = true
        Task {
            defer { touching = false }
            do {
                let read = try await session.read()
                guard read.before.hasSuffix(applied.corrected) else { throw KeyboardError.changed }
                let target = KeyboardText.Target(text: applied.corrected, context: "", forward: "", backward: "", isSelection: false)
                try await session.apply(target, in: read, corrected: applied.original)
                Self.applied = nil
                close()
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func retry() {
        Self.applied = nil
        run()
    }

    func finish() { close() }
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
