import AppKit
import OSLog

/// 입력이 멈추면 단축키가 고칠 범위를 미리 교정해 둔다. 결과는 CorrectionService 캐시에 쌓인다.
@MainActor
final class Precomputer {
    private static let interval: Duration = .milliseconds(300)
    private static let idle: TimeInterval = 0.9
    private static let maxRequestsPerMinute = 30
    private static let maxParallel = 3

    private struct Session {
        let element: AXUIElement
        var baseline: String        // 이미 처리된 것으로 보는 글
        var lastValue: String
        var lastChange: Date
        var requested: Request?     // 같은 글·설정에 요청을 되풀이하지 않기 위해
        var ignored: Set<String> = []
    }

    private struct Request: Equatable {
        let value: String
        let level: CorrectionLevel
        let scope: ScopeMode
        let dictionary: [String]
    }

    private let service: CorrectionService
    private let indicator = IndicatorController()
    private let log = Logger(subsystem: "com.aib.fix4me", category: "precompute")
    private var session: Session?
    private var woken: Set<pid_t> = []
    private var sent: [Date] = []
    private var pausedUntil = Date.distantPast
    private var loop: Task<Void, Never>?

    /// 교정을 쓰는 동안 true — 앱이 쓰는 중간 상태를 사용자의 입력으로 보지 않는다
    var suspended = false {
        didSet { if suspended { indicator.hide() } }
    }

    /// 미리보기에서 "적용"을 눌렀을 때 (한 문단만)
    var onApply: ((IndicatorController.Item, AXUIElement) -> Void)?

    init(service: CorrectionService) {
        self.service = service
        indicator.onIgnore = { [weak self] item in self?.ignore(item) }
        indicator.onApply = { [weak self] item in
            guard let self, let element = session?.element else { return }
            onApply?(item, element)
        }
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// 이 입력창에서 이미 처리된 글 (긴 글의 바뀐 문단을 찾는 기준). 지켜본 적 없으면 nil.
    func baseline(for element: AXUIElement) -> String? {
        guard let session, CFEqual(session.element, element) else { return nil }
        return session.baseline
    }

    /// 교정·되돌리기 직후. 방금 처리한 글은 다시 보내지 않고, 손대지 않은 바뀐 문단은 계속 바뀐 것으로 둔다.
    /// - Parameters: before: 쓰기 전 글 (지켜본 적 없는 입력창의 기준), processed: 처리한 범위의 결과 글
    func didWrite(_ value: String, before: String, processed: [String], to element: AXUIElement) {
        let base = TextScope.baseline(baseline(for: element) ?? before, adding: processed)
        let ignored = session.flatMap { CFEqual($0.element, element) ? $0.ignored : nil } ?? []
        session = Session(element: element, baseline: base, lastValue: value, lastChange: .now, requested: nil, ignored: ignored)
        indicator.hide()
    }

    // MARK: - 감시

    private func tick() {
        guard !suspended else { return }
        guard Prefs.precompute, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Prefs.excluded.contains(app.bundleIdentifier ?? "") else { return reset() }
        guard let field = AXText.peek(app, maxCharacters: TextScope.wholeMaxLength) else {
            if woken.insert(app.processIdentifier).inserted { AXText.wake(app) }
            indicator.hide()
            return
        }

        // 새 입력창: 원래 있던 글은 보내지 않는다. 사용자가 바꾼 뒤부터 본다.
        guard var s = session, CFEqual(s.element, field.element) else {
            session = Session(element: field.element, baseline: field.value, lastValue: field.value, lastChange: .now, requested: nil)
            indicator.hide()
            return
        }
        if field.value != s.lastValue {
            s.lastValue = field.value
            s.lastChange = .now
            // 전송 등으로 비워지면 새 글로 본다
            if field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s.baseline = field.value }
            session = s
            indicator.hide()
            return
        }
        guard Date.now.timeIntervalSince(s.lastChange) >= Self.idle else { return indicator.hide() }

        let level = CorrectionLevel.current, scope = Prefs.scope
        // 선택 영역은 미리 교정하지 않는다 (커서 위치만 사용)
        let targets = TextScope.precomputePlan(
            in: field.value, cursor: field.selection.location, mode: scope, level: level, baseline: s.baseline
        ).filter { $0.length <= TextScope.maxLength }
        guard !targets.isEmpty else { return indicator.hide() }

        let request = Request(value: field.value, level: level, scope: scope, dictionary: Prefs.dictionary)
        if s.requested != request {
            s.requested = request
            session = s
            send(targets, in: field.value, level: level)
        }
        showIndicator(targets, field: field, level: level)
    }

    private func reset() {
        session = nil
        indicator.hide()
    }

    // MARK: - 요청

    private func send(_ targets: [NSRange], in value: String, level: CorrectionLevel) {
        guard Date.now >= pausedUntil else { return }
        let ns = value as NSString
        let pending = targets.filter { r in
            let text = ns.substring(with: r)
            return PrecomputeFilter.isWorthChecking(text)
                && service.cached(text, level: level) == nil && !service.isInFlight(text, level: level)
        }
        guard !pending.isEmpty else { return }
        Task {
            // 한꺼번에 많이 보내지 않도록 묶음으로 나눈다
            for start in stride(from: 0, to: pending.count, by: Self.maxParallel) {
                let batch = pending[start..<min(start + Self.maxParallel, pending.count)]
                await withTaskGroup(of: Void.self) { group in
                    for r in batch where takeQuota() {
                        let text = ns.substring(with: r)
                        let context = Sectioner.context(before: r, in: value)
                        group.addTask { await self.request(text, level: level, context: context) }
                    }
                }
                guard Date.now >= pausedUntil else { return }
            }
        }
    }

    private func request(_ text: String, level: CorrectionLevel, context: String) async {
        do {
            _ = try await service.correct(text, level: level, before: context)
            log.info("precomputed len=\(text.utf16.count)")   // 글 내용은 남기지 않는다
        } catch {
            // 조용히 실패하되 연달아 두드리지 않는다. 키·잔액 문제는 길게 쉰다. (단축키를 누르면 오류가 보인다)
            var pause: TimeInterval = 15
            switch error as? CorrectionError {
            case .missingKey: pause = 300
            case let .http(status, _) where [401, 402, 403].contains(status): pause = 300
            case .http(429, _): pause = 60
            case .implausible, .badResponse, .emptyResponse: pause = 0   // 이 글만의 문제
            default: break
            }
            pausedUntil = max(pausedUntil, Date.now.addingTimeInterval(pause))
            log.info("precompute failed, pause \(Int(pause))s")
        }
    }

    /// 분당 요청 수 상한 (비용 안전장치)
    private func takeQuota() -> Bool {
        let now = Date.now
        sent.removeAll { now.timeIntervalSince($0) > 60 }
        guard sent.count < Self.maxRequestsPerMinute else { return false }
        sent.append(now)
        return true
    }

    // MARK: - 표시

    private func showIndicator(_ targets: [NSRange], field: FocusedText, level: CorrectionLevel) {
        guard Prefs.indicator else { return indicator.hide() }
        let ns = field.value as NSString
        let items = targets.compactMap { r -> IndicatorController.Item? in
            let text = ns.substring(with: r)
            guard !isIgnored(text, in: field.element),
                  let fixed = service.cached(text, level: level), fixed != text else { return nil }
            return .init(range: r, original: text, corrected: fixed, rect: AXText.screenRect(of: r, in: field.element))
        }
        guard !items.isEmpty else { return indicator.hide() }
        indicator.update(.init(
            items: items, visible: AXText.visibleFrame(field.element), caret: AXText.caretRect(field), level: level
        ))
    }

    /// 미리보기에서 "무시"한 글인지. 글을 바꾸면 다시 살아난다.
    func isIgnored(_ text: String, in element: AXUIElement) -> Bool {
        guard let session, CFEqual(session.element, element) else { return false }
        return session.ignored.contains(text)
    }

    private func ignore(_ item: IndicatorController.Item) {
        session?.ignored.insert(item.original)
    }
}
