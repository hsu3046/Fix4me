import AppKit
import OSLog

/// 입력이 멈추면 단축키가 고칠 범위를 미리 교정해 둔다. 결과는 CorrectionService 캐시에 쌓인다.
@MainActor
final class Precomputer {
    private static let interval: Duration = .milliseconds(300)
    private static let idle: TimeInterval = 0.6
    private static let maxRequestsPerMinute = 30
    private static let maxParallel = 3

    private struct Request: Equatable {
        let value: String
        let level: CorrectionLevel
        let scope: ScopeMode
        let dictionary: [String]
    }

    private let service: CorrectionService
    private let indicator = IndicatorController()
    private let log = Logger(subsystem: "com.aib.fix4me", category: "precompute")
    private let statusLog = Logger(subsystem: "com.aib.fix4me", category: "status")
    private var lastNote = ""
    private var fields = FieldMemory<AXUIElement> { CFEqual($0, $1) }
    private var current: AXUIElement?      // 바로 앞 감시에서 보던 입력창
    private var requested: Request?        // 같은 글·설정에 요청을 되풀이하지 않기 위해
    private var unreadableSince: [pid_t: Date] = [:]
    private var wokenHarder: Set<pid_t> = []
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
    /// 미리보기에서 "무시"를 눌렀을 때 (기록용, 앱 번들 ID)
    var onIgnore: ((IndicatorController.Item, String) -> Void)?

    init(service: CorrectionService) {
        self.service = service
        indicator.onIgnore = { [weak self] item in self?.ignore(item) }
        indicator.onApply = { [weak self] item in
            guard let self, let element = current else { return }
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
        fields[element]?.baseline
    }

    /// 교정·되돌리기 직후. 방금 처리한 글은 다시 보내지 않고, 손대지 않은 바뀐 문단은 계속 바뀐 것으로 둔다.
    /// - Parameters: before: 쓰기 전 글 (지켜본 적 없는 입력창의 기준), processed: 처리한 범위의 결과 글
    func didWrite(_ value: String, before: String, processed: [String], to element: AXUIElement) {
        let base = TextScope.baseline(baseline(for: element) ?? before, adding: processed)
        fields[element] = .init(baseline: base, lastValue: value, lastChange: .now, ignored: fields[element]?.ignored ?? [])
        requested = nil
        indicator.hide()
    }

    // MARK: - 감시

    private func tick() {
        guard !suspended else { return }
        guard Self.isOn, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Prefs.excluded.contains(app.bundleIdentifier ?? "") else { return reset() }
        let id = app.bundleIdentifier ?? "?"
        // 입력하기 전에 깨워 둔다 (늦게 깨우면 그동안 쓴 글을 원래 있던 글로 본다)
        if woken.insert(app.processIdentifier).inserted { AXText.wake(app) }
        let field: FocusedText
        switch AXText.peek(app, maxCharacters: TextScope.wholeMaxLength) {
        case let .field(f): field = f
        case let .skipped(reason):
            note(reason, app: id)
            if reason == AXText.noFocusReason { wakeHarderIfStuck(app, id: id) }
            else { unreadableSince[app.processIdentifier] = nil }
            current = nil
            indicator.hide()
            return
        }
        unreadableSince[app.processIdentifier] = nil

        let resumed = !(current.map { CFEqual($0, field.element) } ?? false)
        current = field.element
        // 처음 보는 입력창: 원래 있던 글은 보내지 않는다. 사용자가 바꾼 뒤부터 본다.
        guard var state = fields[field.element] else {
            fields[field.element] = .init(baseline: field.value, lastValue: field.value, lastChange: .now)
            note("새 입력창", app: id)
            indicator.hide()
            return
        }
        let change = FieldChange.between(state.lastValue, field.value, resumed: resumed)
        if change != .none {
            if change != .edited {
                state.baseline = field.value
                state.ignored = []
                if change == .replaced { note("다른 글이 들어옴", app: id) }
            }
            state.lastValue = field.value
            state.lastChange = .now
            fields[field.element] = state
            indicator.hide()
            return
        }
        guard Date.now.timeIntervalSince(state.lastChange) >= Self.idle else { return indicator.hide() }

        let level = CorrectionLevel.current, scope = Prefs.scope
        // 선택 영역은 미리 교정하지 않는다 (커서 위치만 사용)
        let targets = TextScope.precomputePlan(
            in: field.value, cursor: field.selection.location, mode: scope, level: level, baseline: state.baseline
        ).filter { $0.length <= TextScope.maxLength }
        guard !targets.isEmpty else {
            note("포커스 뒤 바뀐 섹션 없음", app: id)
            return indicator.hide()
        }

        let request = Request(value: field.value, level: level, scope: scope, dictionary: Prefs.dictionary)
        if requested != request {
            requested = request
            // 방금 보낸 요청은 다음 감시부터 진행 중으로 보인다
            if send(targets, in: field.value, level: level) { return note("요청 보냄", app: id) }
        }
        showIndicator(targets, field: field, level: level, app: id)
    }

    private static var isOn: Bool { SharedStore.isOn && Prefs.precompute }

    private func reset() {
        current = nil
        if !Self.isOn {   // 끄면 기억한 글도 버린다 → 끈 동안 쓴 글은 다시 켜도 보내지 않는다
            fields.removeAll()
            requested = nil
        }
        indicator.hide()
    }

    /// 입력창이 3초 넘게 안 읽히는 앱은 다른 방식으로 한 번 더 깨운다
    private func wakeHarderIfStuck(_ app: NSRunningApplication, id: String) {
        let pid = app.processIdentifier
        let since = unreadableSince[pid] ?? .now
        unreadableSince[pid] = since
        guard Date.now.timeIntervalSince(since) >= 3, wokenHarder.insert(pid).inserted else { return }
        AXText.wakeHarder(app)
        note("다른 방식으로 깨움", app: id)
    }

    // MARK: - 요청

    /// 새로 보낸 것이 있으면 true
    private func send(_ targets: [NSRange], in value: String, level: CorrectionLevel) -> Bool {
        guard Date.now >= pausedUntil else { return false }
        let ns = value as NSString
        let pending = targets.filter { r in
            let text = ns.substring(with: r)
            return PrecomputeFilter.isWorthChecking(text)
                && service.cached(text, level: level) == nil && !service.isInFlight(text, level: level)
        }
        guard !pending.isEmpty else { return false }
        Task {
            // 한꺼번에 많이 보내지 않도록 묶음으로 나눈다
            for start in stride(from: 0, to: pending.count, by: Self.maxParallel) {
                let batch = pending[start..<min(start + Self.maxParallel, pending.count)]
                await withTaskGroup(of: Void.self) { group in
                    for r in batch where takeQuota(CorrectionPipeline.stages(for: level).count) {
                        let text = ns.substring(with: r)
                        let context = Sectioner.context(before: r, in: value)
                        group.addTask { await self.request(text, level: level, context: context) }
                    }
                }
                guard Date.now >= pausedUntil, Self.isOn else { return }
            }
        }
        return true
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
            case .off: return
            case .implausible, .badResponse, .emptyResponse: pause = 0   // 이 글만의 문제
            default: break
            }
            pausedUntil = max(pausedUntil, Date.now.addingTimeInterval(pause))
            log.info("precompute failed, pause \(Int(pause))s")
        }
    }

    /// 분당 요청 수 상한 (비용 안전장치)
    private func takeQuota(_ calls: Int) -> Bool {
        let now = Date.now
        sent.removeAll { now.timeIntervalSince($0) > 60 }
        guard sent.count + calls <= Self.maxRequestsPerMinute else { return false }
        sent += Array(repeating: now, count: calls)
        return true
    }

    // MARK: - 표시

    private func showIndicator(_ targets: [NSRange], field: FocusedText, level: CorrectionLevel, app: String) {
        guard Prefs.indicator else { return indicator.hide() }
        let ns = field.value as NSString
        var items: [IndicatorController.Item] = [], waiting: [NSRect?] = []
        for r in targets {
            let text = ns.substring(with: r)
            let best = CorrectionPipeline.best(for: text, level: level) { service.cached(text, level: $0) }
            if let best, !isIgnored(text, level: best.level, in: field.element) {
                items.append(.init(range: r, original: text, corrected: best.corrected, level: best.level,
                                   isFinal: best.level == level, rect: AXText.sectionRect(r, in: field)))
            } else if best == nil, service.cached(text, level: level) == nil, service.isInFlight(text, level: level) {
                waiting.append(AXText.sectionRect(r, in: field))
            }
        }
        let visible = AXText.visibleFrame(field.element), caret = AXText.caretRect(field)
        let bars = items.filter { IndicatorLayout.bar(text: $0.rect, visible: visible) != nil }.count
        if !items.isEmpty {
            let place = bars > 0 ? "막대" : (visible != nil || caret != nil ? "배지" : nil)
            note(place.map { "\($0) 표시\(items.allSatisfy(\.isFinal) ? "" : " (교정 먼저)")" } ?? "표시할 위치를 모름", app: app)
        } else if !waiting.isEmpty {
            note("준비 중 표시", app: app)
        } else {
            let texts = targets.map { ns.substring(with: $0) }
            if texts.allSatisfy({ !PrecomputeFilter.isWorthChecking($0) }) { note("보내지 않는 글(짧거나 키·주소처럼 보임)", app: app) }
            else if texts.allSatisfy({ service.cached($0, level: level) != nil }) { note("고칠 곳 없음 또는 무시함", app: app) }
            else { note("교정 결과 없음(실패·한도)", app: app) }
        }
        indicator.update(.init(items: items, waiting: waiting, visible: visible, caret: caret, level: level))
    }

    /// 표시 상태가 바뀔 때만 이유를 시스템 기록에 남긴다. 글 내용은 남기지 않는다.
    ///   /usr/bin/log show --last 1d --predicate 'subsystem == "com.aib.fix4me" AND category == "status"'
    private func note(_ status: String, app: String) {
        let line = "\(app) — \(status)"
        guard line != lastNote else { return }
        lastNote = line
        statusLog.notice("\(line, privacy: .public)")
    }

    /// 미리보기에서 "무시"한 결과인지. 글이나 강도를 바꾸면 다시 살아난다.
    func isIgnored(_ text: String, level: CorrectionLevel, in element: AXUIElement) -> Bool {
        fields[element]?.ignored.contains(Self.ignoreKey(text, level)) ?? false
    }

    private static func ignoreKey(_ text: String, _ level: CorrectionLevel) -> String { level.rawValue + "\n" + text }

    private func ignore(_ item: IndicatorController.Item) {
        guard let current else { return }
        fields[current]?.ignored.insert(Self.ignoreKey(item.original, item.level))
        onIgnore?(item, NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }
}
