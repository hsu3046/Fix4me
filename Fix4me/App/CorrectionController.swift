import AppKit
import OSLog

/// 단축키 → 입력창 읽기 → LLM 교정 → 안전 확인 → 쓰기 의 전체 흐름.
@MainActor
final class CorrectionController {
    private let hud = HUDController()
    private let log = Logger(subsystem: "com.aib.fix4me", category: "correction")
    private var busy = false
    private var lastEdit: LastEdit?

    /// 되돌리기용 기록: 교정 후 입력창에서 바뀐 구간과 원래 내용
    private struct LastEdit {
        let element: AXUIElement
        let range: NSRange      // 교정 후 값 기준, 삽입된 구간
        let inserted: String
        let original: String
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
        guard let key = Keychain.read(Keychain.openRouterAccount), !key.isEmpty else {
            hud.show(.error(CorrectionError.missingKey.localizedDescription), near: nil)
            return
        }

        let field: FocusedText
        do {
            field = try await AXText.focused()
        } catch {
            hud.show(.error(error.localizedDescription), near: nil)
            return
        }
        guard let target = TextScope.target(in: field.value, selection: field.selection) else {
            hud.show(.error("교정할 텍스트가 없어요"), near: AXText.screenRect(of: field.selection, in: field.element))
            return
        }
        guard target.length <= TextScope.maxLength else {
            hud.show(.error("너무 길어요 — \(TextScope.maxLength)자 이하로 선택해 주세요"), near: nil)
            return
        }

        let anchor = AXText.screenRect(of: target, in: field.element)
        let original = (field.value as NSString).substring(with: target)
        let level = CorrectionLevel.current   // 설정에서 고른 강도 (누를 때마다 읽어 즉시 반영)
        hud.show(.working(level.workingTitle), near: anchor)

        let started = ContinuousClock.now
        let corrected: String
        do {
            corrected = try await OpenRouterClient(apiKey: key).correct(original, level: level)
        } catch {
            hud.show(.error(error.localizedDescription), near: anchor)
            return
        }
        let elapsed = ContinuousClock.now - started
        log.info("corrected level=\(level.rawValue) len=\(original.count) in \(elapsed.components.seconds)s")

        guard let span = TextDiff.changedSpan(old: original, new: corrected) else {
            hud.show(.noChange(seconds: elapsed.seconds), near: anchor)
            return
        }

        // 기다리는 동안 사용자가 입력을 바꿨으면 옛 결과로 덮어쓰지 않는다 (스냅샷 대조)
        guard let latest = AXText.currentValue(field.element),
              NSMaxRange(target) <= (latest as NSString).length,
              (latest as NSString).substring(with: target) == original else {
            hud.show(.error("기다리는 동안 내용이 바뀌어 취소했어요"), near: anchor)
            return
        }

        let writeRange = NSRange(location: target.location + span.oldRange.location, length: span.oldRange.length)
        let expected = (latest as NSString).replacingCharacters(in: writeRange, with: span.replacement)
        guard let method = await AXText.replace(
            in: field.element, range: writeRange, with: span.replacement, expected: expected
        ) else {
            hud.show(.error("\(field.appName)에 쓰지 못했어요"), near: anchor)
            return
        }

        // 커서를 바뀐 구간 끝으로 (붙여넣기 경로는 앱이 이미 옮겨 둠)
        let insertedRange = NSRange(location: writeRange.location, length: (span.replacement as NSString).length)
        if method == .accessibility {
            AXText.select(NSRange(location: NSMaxRange(insertedRange), length: 0), in: field.element)
        }
        lastEdit = LastEdit(
            element: field.element, range: insertedRange,
            inserted: span.replacement, original: (latest as NSString).substring(with: writeRange)
        )

        let hunks = TextDiff.hunks(old: original, new: corrected)
        hud.show(.done(count: hunks.count, preview: Self.preview(hunks), seconds: elapsed.seconds), near: anchor)
    }

    // MARK: - 되돌리기

    private func runRevert() async {
        guard let edit = lastEdit else {
            hud.show(.error("되돌릴 교정이 없어요"), near: nil)
            return
        }
        // 같은 입력창, 같은 자리에 교정 결과가 그대로 있을 때만 되돌린다
        guard let value = AXText.currentValue(edit.element),
              NSMaxRange(edit.range) <= (value as NSString).length,
              (value as NSString).substring(with: edit.range) == edit.inserted else {
            lastEdit = nil
            hud.show(.error("이미 내용이 바뀌었어요 — ⌘Z 를 써 주세요"), near: nil)
            return
        }
        let expected = (value as NSString).replacingCharacters(in: edit.range, with: edit.original)
        let ok = await AXText.replace(in: edit.element, range: edit.range, with: edit.original, expected: expected) != nil
        lastEdit = nil
        hud.show(ok ? .reverted : .error("되돌리지 못했어요 — ⌘Z 를 써 주세요"),
                 near: AXText.screenRect(of: edit.range, in: edit.element))
    }

    /// "않 → 안, 금새 → 금세" 처럼 앞쪽 몇 개만
    private static func preview(_ hunks: [TextDiff.Hunk]) -> String {
        hunks.prefix(3).map { h in
            let from = h.from.isEmpty ? "␣" : String(h.from.prefix(12))
            let to = h.to.isEmpty ? "삭제" : String(h.to.prefix(12))
            return "\(from) → \(to)"
        }.joined(separator: ", ") + (hunks.count > 3 ? " …" : "")
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
