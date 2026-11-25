import AppKit

/// ⌥ 를 짧게 두 번 눌렀는지 판정 (순수 로직). 두 번째 손을 뗄 때 성립한다 — 그때는 보조 키가 모두 떨어져 있다.
struct DoubleTapDetector {
    enum Input: Equatable {
        case down(key: UInt16)   // ⌥ 만 눌림 (왼쪽·오른쪽 키 번호)
        case up(key: UInt16)     // ⌥ 를 떼어 보조 키가 하나도 없음
        case other               // 다른 키·다른 보조 키·마우스
    }

    static let maxHold: TimeInterval = 0.3   // 이보다 오래 누르면 두 번 누르기가 아니다
    static let maxGap: TimeInterval = 0.3    // 첫 번째를 떼고 두 번째를 누르기까지

    private enum State {
        case idle
        case firstDown(key: UInt16, at: TimeInterval)
        case firstUp(key: UInt16, at: TimeInterval)
        case secondDown(key: UInt16, at: TimeInterval)
    }

    private var state = State.idle

    /// 두 번 누르기가 성립하면 true
    mutating func handle(_ input: Input, at time: TimeInterval) -> Bool {
        switch (state, input) {
        case let (.firstDown(key, at), .up(k)) where k == key && time - at <= Self.maxHold:
            state = .firstUp(key: key, at: time)
        case let (.firstUp(key, at), .down(k)) where k == key && time - at <= Self.maxGap:
            state = .secondDown(key: key, at: time)
        case let (.secondDown(key, at), .up(k)) where k == key && time - at <= Self.maxHold:
            state = .idle
            return true
        case let (_, .down(k)):
            state = .firstDown(key: k, at: time)   // 새로 시작
        default:
            state = .idle
        }
        return false
    }
}

/// 시스템 전체의 ⌥ 두 번 누르기를 지켜본다. 키를 가로채지 않으므로 ⌥ 조합 입력은 그대로 된다.
@MainActor
final class DoubleTapMonitor {
    private var detector = DoubleTapDetector()
    private var monitors: [Any] = []
    private var starting: Task<Void, Never>?
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    /// 손쉬운 사용 권한이 있어야 다른 앱의 키가 보인다 → 허용될 때까지 기다렸다 시작한다
    func start() {
        starting = Task { [weak self] in
            while !Task.isCancelled, !AXText.isTrusted { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            self?.install()
        }
    }

    private func install() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.observe(e) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.observe(e) }
            return e
        }
        monitors = [global, local].compactMap { $0 }
    }

    private func observe(_ event: NSEvent) {
        let fired = detector.handle(Self.input(event), at: event.timestamp)
        if fired, Prefs.doubleTap { action() }
    }

    static func input(_ event: NSEvent) -> DoubleTapDetector.Input {
        guard event.type == .flagsChanged, event.keyCode == 58 || event.keyCode == 61 else { return .other }
        return input(key: event.keyCode, flags: event.modifierFlags)
    }

    static func input(key: UInt16, flags: NSEvent.ModifierFlags) -> DoubleTapDetector.Input {
        switch flags.intersection([.control, .option, .command, .shift, .function]) {
        case .option: .down(key: key)
        case []: .up(key: key)
        default: .other
        }
    }
}
