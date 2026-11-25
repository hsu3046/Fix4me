import Foundation
import Observation

/// 교정 키보드의 상태. 문법 교정은 열면 바로 고치고 쓰던 키보드로 돌아가고, 문장 개선·다시 쓰기는 미리보기를 보여 준다.
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
    /// 되돌린 글: 다시 열었을 때 같은 교정을 또 바로 적용하지 않고 미리보기를 보여 준다
    private static var reverted: String?
    static func forget() { applied = nil; reverted = nil }

    private(set) var state = State.reading
    var level: CorrectionLevel {
        didSet {
            guard level != oldValue else { return }
            environment.saveLevel(level)
            run()
        }
    }
    @ObservationIgnored private let session: KeyboardSession
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private let close: () -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var text: KeyboardText?
    @ObservationIgnored private var target: KeyboardText.Target?
    @ObservationIgnored private var touching = false    // 우리가 커서를 옮기거나 쓰는 중
    @ObservationIgnored private var isOpen = false

    /// 키보드 밖의 것들 (시험에서는 바꿔 끼운다)
    struct Environment {
        var hasFullAccess: () -> Bool
        var hasKey: () -> Bool
        var loadLevel: () -> CorrectionLevel = { .current }
        var saveLevel: (CorrectionLevel) -> Void = { CorrectionLevel.save($0) }
        var correct: (KeyboardText.Target, CorrectionLevel) async throws -> String
        /// "고칠 곳이 없어요" 를 보여 주는 시간
        var showNoChange: () async -> Void = { try? await Task.sleep(for: .milliseconds(800)) }
    }

    init(session: KeyboardSession, environment: Environment, close: @escaping () -> Void) {
        self.session = session
        self.environment = environment
        self.close = close
        level = environment.loadLevel()
    }

    /// 키보드가 열릴 때
    func open() {
        isOpen = true
        level = environment.loadLevel()   // 앱에서 바꾼 강도 (바뀌었으면 아래에서 다시 시작한다)
        run(opening: true)
    }

    /// 키보드가 닫힐 때: 기다리던 교정을 뒤늦게 적용하거나 키보드를 바꾸지 않는다
    func closed() {
        isOpen = false
        task?.cancel()
    }

    private func leave() {
        if isOpen { close() }
    }

    /// 우리가 한 일이 아닌 변경: 보여 준 결과가 더는 맞지 않는다
    func textMayHaveChanged() {
        guard !touching, case .result = state else { return }
        guard session.proxy.selected == (text?.selected ?? ""), KeyboardSession.agrees(session.proxy.before, withEndOf: text?.before ?? "") else {
            return state = .error(KeyboardError.changed.localizedDescription)
        }
    }

    /// - Parameter opening: 키보드를 막 열었다. 커서 앞이 방금 고친 글이면 되돌리기를 보이고, 문법 교정은 바로 적용한다
    func run(opening: Bool = false) {
        task?.cancel()
        guard environment.hasFullAccess() else { return state = .needsFullAccess }
        guard environment.hasKey() else { return state = .needsKey }
        state = .reading
        task = Task { await correct(opening: opening) }
    }

    private func correct(opening: Bool) async {
        do {
            touching = true
            defer { touching = false }
            let read = try await session.read()
            guard !Task.isCancelled else { return }
            text = read
            if opening, let applied = Self.applied, read.selected.isEmpty, read.before.hasSuffix(applied.corrected) {
                return state = .applied
            }
            target = read.target(level: level)
        } catch {
            if !Task.isCancelled { state = .error(error.localizedDescription) }
            return
        }
        guard let target else { return state = .empty }
        let level = self.level
        state = .working(level.workingTitle)
        do {
            let corrected = try await environment.correct(target, level)
            guard !Task.isCancelled else { return }
            guard corrected != target.text else {
                state = .noChange
                guard opening else { return }
                await environment.showNoChange()
                if !Task.isCancelled { leave() }
                return
            }
            state = .result(original: target.text, corrected: corrected)
            if opening, level == .proofread, target.text != Self.reverted { apply() }
        } catch {
            if !Task.isCancelled { state = .error(error.localizedDescription) }
        }
    }

    func apply() {
        guard !touching, case let .result(original, corrected) = state, let text, let target else { return }
        touching = true
        Task {
            defer { touching = false }
            do {
                try await session.apply(target, in: text, corrected: corrected)
                Self.applied = Applied(original: original, corrected: corrected)
                Self.reverted = nil
                state = .applied
                leave()   // 쓰던 키보드로 돌아간다
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// 커서 바로 앞이 고친 글일 때만 되돌린다
    func revert() {
        guard !touching, let applied = Self.applied else { return }
        touching = true
        Task {
            defer { touching = false }
            do {
                let read = try await session.read()
                guard read.before.hasSuffix(applied.corrected) else { throw KeyboardError.changed }
                let target = KeyboardText.Target(text: applied.corrected, context: "", forward: "", backward: "", isSelection: false)
                try await session.apply(target, in: read, corrected: applied.original)
                Self.applied = nil
                Self.reverted = applied.original
                leave()
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func retry() {
        Self.applied = nil
        run()
    }

    func finish() { leave() }
}
