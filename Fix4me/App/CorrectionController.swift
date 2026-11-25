import AppKit
import OSLog

/// 단축키 → 입력창 읽기 → LLM 교정 → 안전 확인 → 쓰기 의 전체 흐름.
@MainActor
final class CorrectionController {
    private let hud = HUDController()
    private let service: CorrectionService
    private let precomputer: Precomputer
    private let history: HistoryStore
    private let log = Logger(subsystem: "com.aib.fix4me", category: "correction")
    private var busy = false
    private var lastEdit: LastEdit?

    /// 되돌리기용 기록: 교정 후 글 기준으로 원래 내용을 되살리는 편집들 (앞에서부터)
    private struct LastEdit {
        let element: AXUIElement
        let undo: [TextEdit]
        let inserted: [String]   // 각 구간에 지금 있어야 하는 글
        let originals: [String]  // 교정 대상이던 원문 (되돌린 뒤 다시 보내지 않도록)
        let history: [UUID]      // 되돌리면 결과를 바꿀 기록
    }

    init(service: CorrectionService, precomputer: Precomputer, history: HistoryStore) {
        self.service = service
        self.precomputer = precomputer
        self.history = history
        precomputer.onApply = { [weak self] item, element in self?.applyOne(item, to: element) }
        precomputer.onIgnore = { [weak self] item, app in
            _ = self?.history.record(original: item.original, corrected: item.corrected, level: item.level, app: app, outcome: .ignored)
        }
    }

    func correctFocused() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            await runCorrection()
        }
    }

    func revertLast() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            await runRevert()
        }
    }

    // MARK: - 교정

    private func runCorrection() async {
        guard SharedStore.isOn else { return hud.show(.error(CorrectionError.off.localizedDescription), near: nil) }
        let field: FocusedText
        do {
            field = try await AXText.focused()
        } catch {
            hud.show(.error(error.localizedDescription), near: nil)
            return
        }
        // 설정은 누를 때마다 읽어 바로 반영한다
        let level = CorrectionLevel.current
        let scope = Prefs.scope
        let value = field.value as NSString
        guard value.length <= TextScope.wholeMaxLength || scope != .whole || field.selection.length > 0 else {
            hud.show(.error("너무 길어요 — 고칠 부분을 선택해 주세요"), near: nil)
            return
        }
        var targets = TextScope.plan(
            in: field.value, selection: field.selection, mode: scope, level: level,
            baseline: precomputer.baseline(for: field.element)
        )
        // 미리보기에서 무시한 문단은 뺀다 (직접 선택한 글은 예외)
        if field.selection.length == 0, !targets.isEmpty {
            targets.removeAll { precomputer.isIgnored(value.substring(with: $0), level: level, in: field.element) }
            if targets.isEmpty {
                hud.show(.error("무시한 글이에요 — 고치려면 선택하고 다시 눌러 주세요"), near: AXText.caretRect(field))
                return
            }
        }
        guard let last = targets.last else {
            hud.show(.error("교정할 텍스트가 없어요"), near: AXText.screenRect(of: field.selection, in: field.element))
            return
        }
        guard targets.allSatisfy({ $0.length <= TextScope.maxLength }) else {
            hud.show(.error("너무 길어요 — \(TextScope.maxLength)자 이하로 선택해 주세요"), near: nil)
            return
        }

        let anchor = AXText.caretRect(field) ?? AXText.screenRect(of: last, in: field.element)
        let originals = targets.map { value.substring(with: $0) }
        if originals.contains(where: { service.cached($0, level: level) == nil }) {
            hud.show(.working(level.workingTitle), near: anchor)
        }

        let started = ContinuousClock.now
        let corrected: [String]
        do {
            corrected = try await correctAll(originals, ranges: targets, in: field.value, level: level)
        } catch {
            hud.show(.error(error.localizedDescription), near: anchor)
            return
        }
        let elapsed = ContinuousClock.now - started
        log.info("corrected level=\(level.rawValue, privacy: .public) targets=\(targets.count) in \(elapsed.seconds, format: .fixed(precision: 2))s")

        await finish(field: field, targets: targets, originals: originals, corrected: corrected, level: level,
                     seconds: elapsed.seconds, anchor: anchor)
    }

    /// 미리보기의 "적용": 그 문단만 고친다
    private func applyOne(_ item: IndicatorController.Item, to element: AXUIElement) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            // 미리보기를 띄운 뒤 글이나 입력창이 바뀌지 않았는지 확인
            guard AXText.isFocused(element), let app = NSWorkspace.shared.frontmostApplication,
                  case let .field(field) = AXText.peek(app, maxCharacters: TextScope.wholeMaxLength), CFEqual(field.element, element),
                  NSMaxRange(item.range) <= (field.value as NSString).length,
                  (field.value as NSString).substring(with: item.range) == item.original else {
                hud.show(.error("내용이 바뀌어 적용하지 않았어요"), near: item.rect)
                return
            }
            AXText.prepareForWriting(field.element)
            await finish(field: field, targets: [item.range], originals: [item.original], corrected: [item.corrected], level: item.level,
                         seconds: 0, anchor: item.rect ?? AXText.caretRect(field))
        }
    }

    /// 교정 결과를 입력창에 쓰고, 되돌리기를 기록하고, 알린다.
    private func finish(
        field: FocusedText, targets: [NSRange], originals: [String], corrected: [String], level: CorrectionLevel,
        seconds: Double, anchor: NSRect?
    ) async {
        // 범위 안에서 실제로 바뀐 구간만, 글 전체 기준 위치로
        var edits: [TextEdit] = []
        for (i, range) in targets.enumerated() {
            edits += TextDiff.edits(old: originals[i], new: corrected[i]).map {
                TextEdit(range: NSRange(location: range.location + $0.range.location, length: $0.range.length), text: $0.text)
            }
        }
        guard !edits.isEmpty else {
            precomputer.didWrite(field.value, before: field.value, processed: originals, to: field.element)
            hud.show(.noChange(seconds: seconds), near: anchor)
            return
        }

        // 기다리는 동안 글이 바뀌었으면 옛 결과로 덮어쓰지 않는다 (스냅샷 대조)
        guard let latest = AXText.currentValue(field.element), EditorText.same(latest, field.value) else {
            hud.show(.error("기다리는 동안 내용이 바뀌어 취소했어요"), near: anchor)
            return
        }

        precomputer.suspended = true
        defer { precomputer.suspended = false }
        let writing = ContinuousClock.now
        let applied = await write(edits, to: field.element, value: field.value)
        let bundle = NSRunningApplication(processIdentifier: field.pid)?.bundleIdentifier ?? "?"
        log.notice("write app=\(bundle, privacy: .public) edits=\(applied.edits.count)/\(edits.count) method=\(applied.method.rawValue, privacy: .public) mismatch=\(applied.mismatch) in \((ContinuousClock.now - writing).seconds, format: .fixed(precision: 2))s")
        watchAfterWrite(field.element, app: bundle)
        guard !applied.mismatch else {
            // 예상과 다른 글이 들어갔다: 되돌리기 위치를 믿을 수 없으므로 앱의 실행 취소를 안내하고, 어긋난 글을 다시 보내지 않는다
            lastEdit = nil
            if let now = AXText.currentValue(field.element) {
                precomputer.didWrite(now, before: now, processed: [now], to: field.element)
            }
            log.notice("write mismatch app=\(NSRunningApplication(processIdentifier: field.pid)?.bundleIdentifier ?? "?", privacy: .public)")
            hud.show(.error("예상과 다르게 들어갔어요 — ⌘Z 로 되돌려 주세요"), near: anchor)
            return
        }
        guard !applied.edits.isEmpty else {
            hud.show(.error("\(field.appName)에서 고칠 위치를 확인하지 못해 쓰지 않았어요"), near: anchor)
            return
        }
        if applied.edits.count == edits.count, let now = AXText.currentValue(field.element) {
            precomputer.didWrite(now, before: field.value, processed: corrected, to: field.element)
        }
        // 다 쓴 경우만 기록한다 (일부만 쓴 결과는 교정 품질의 신호가 아니다)
        let app = NSRunningApplication(processIdentifier: field.pid)?.bundleIdentifier ?? ""
        let recorded = applied.edits.count != edits.count ? [] : zip(originals, corrected).compactMap {
            history.record(original: $0, corrected: $1, level: level, app: app, outcome: .applied)
        }
        lastEdit = LastEdit(
            element: field.element, undo: TextDiff.inverse(of: applied.edits, in: field.value), inserted: applied.edits.map(\.text),
            originals: originals, history: recorded
        )
        guard applied.edits.count == edits.count else {
            hud.show(.error("\(edits.count)곳 중 \(applied.edits.count)곳만 고쳤어요 — \(HotKeyCenter.revert.label) 로 되돌릴 수 있어요"), near: anchor)
            return
        }

        // 커서를 원래 있던 글자 옆으로. 읽어 온 커서 위치도 앱의 세는 방식이므로 글 기준과 같을 때만 옮긴다
        if applied.mapping == .native {
            let caret = TextDiff.shift(NSMaxRange(field.selection), by: edits)
            AXText.select(NSRange(location: caret, length: 0), in: field.element)
        }
        let hunks = zip(originals, corrected).flatMap { TextDiff.hunks(old: $0, new: $1) }
        hud.show(.done(count: hunks.count, hunks: hunks, seconds: seconds), near: anchor)
    }

    /// 쓴 뒤 4초 동안 글이 다시 바뀌는지 본다 (진단용, 글 내용은 남기지 않고 길이와 시각만)
    private func watchAfterWrite(_ element: AXUIElement, app: String) {
        let first = AXText.currentValue(element)
        let started = ContinuousClock.now
        Task {
            var last = first
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(100))
                let now = AXText.currentValue(element)
                guard now != last else { continue }
                log.notice("after-write app=\(app, privacy: .public) changed at \((ContinuousClock.now - started).seconds, format: .fixed(precision: 2))s len \(last?.utf16.count ?? -1)->\(now?.utf16.count ?? -1) backToFirst=\(now == first)")
                last = now
            }
        }
    }

    /// 범위마다 교정 (캐시에 있으면 즉시, 진행 중이면 이어받음). 하나라도 실패하면 아무것도 쓰지 않는다.
    private func correctAll(
        _ originals: [String], ranges: [NSRange], in value: String, level: CorrectionLevel
    ) async throws -> [String] {
        var results = originals
        let width = 4 // 동시 요청 수
        for start in stride(from: 0, to: originals.count, by: width) {
            let batch = Array(start..<min(start + width, originals.count))
            let tasks = batch.map { i in
                let context = Sectioner.context(before: ranges[i], in: value)
                return Task { try await service.correct(originals[i], level: level, before: context) }
            }
            for (i, task) in zip(batch, tasks) { results[i] = try await task.value }
        }
        return results
    }

    private struct Written {
        var edits: [TextEdit] = []          // 확인된 것만
        var method = AXText.WriteMethod.accessibility
        var mapping = EditorText.Mapping.native
        var mismatch = false                // 예상과 다른 글이 들어갔다
    }

    /// 뒤에서부터 써서 앞쪽 위치가 밀리지 않게 한다. 매번 지금 글이 예상과 같은지 확인하고, 다르면 멈춘다.
    private func write(_ edits: [TextEdit], to element: AXUIElement, value: String) async -> Written {
        var result = Written(), current = value
        for raw in edits.reversed() {
            guard let now = AXText.currentValue(element), EditorText.same(now, current) else { break }
            let edit = EditorText.anchored(raw, in: current)
            switch await AXText.replace(in: element, edit: edit, value: current) {
            case let .done(method, mapping):
                if method == .paste { result.method = .paste }
                result.mapping = mapping
                result.edits.insert(edit, at: 0)
                current = (current as NSString).replacingCharacters(in: edit.range, with: edit.text)
            case .untouched:
                return result
            case .mismatch:
                result.mismatch = true
                return result
            }
        }
        return result
    }

    // MARK: - 되돌리기

    private func runRevert() async {
        guard let edit = lastEdit else {
            hud.show(.error("되돌릴 교정이 없어요"), near: nil)
            return
        }
        lastEdit = nil
        // 같은 입력창, 같은 자리에 교정 결과가 그대로 있을 때만 되돌린다
        guard let value = AXText.currentValue(edit.element),
              zip(edit.undo, edit.inserted).allSatisfy({ e, text in
                  NSMaxRange(e.range) <= (value as NSString).length && (value as NSString).substring(with: e.range) == text
              }) else {
            hud.show(.error("이미 내용이 바뀌었어요 — ⌘Z 를 써 주세요"), near: nil)
            return
        }
        precomputer.suspended = true
        defer { precomputer.suspended = false }
        let applied = await write(edit.undo, to: edit.element, value: value)
        if let now = AXText.currentValue(edit.element) {
            precomputer.didWrite(now, before: value, processed: edit.originals, to: edit.element)
        }
        let ok = !applied.mismatch && applied.edits.count == edit.undo.count
        if ok { history.update(edit.history, outcome: .reverted) }
        hud.show(ok ? .reverted : .error("다 되돌리지 못했어요 — ⌘Z 를 써 주세요"),
                 near: edit.undo.first.flatMap { AXText.screenRect(of: $0.range, in: edit.element) })
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
