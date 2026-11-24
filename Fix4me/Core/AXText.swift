import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 포커스된 입력창의 스냅샷. range 는 UTF-16 단위.
struct FocusedText {
    let element: AXUIElement
    let appName: String
    let value: String
    let selection: NSRange
}

enum AXTextError: LocalizedError {
    case notTrusted
    case noFocus
    case secureField
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notTrusted: "손쉬운 사용 권한이 필요해요 (설정에서 허용)"
        case .noFocus: "포커스된 입력창을 찾지 못했어요"
        case .secureField: "비밀번호 입력란은 교정하지 않아요"
        case .unreadable: "이 앱의 입력창은 텍스트를 읽을 수 없어요"
        }
    }
}

/// Accessibility API 로 입력창을 읽고 쓴다. 모든 호출은 메인 스레드.
@MainActor
enum AXText {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 시스템의 "손쉬운 사용 허용" 창을 띄운다.
    static func requestTrust() {
        // kAXTrustedCheckOptionPrompt 전역 var 는 Swift 6 동시성 검사에 걸려 같은 값의 리터럴을 쓴다
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: - 읽기

    static func focused() async throws -> FocusedText {
        guard isTrusted else { throw AXTextError.notTrusted }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw AXTextError.noFocus }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 1.0)

        var element = copyElement(appEl, kAXFocusedUIElementAttribute)
        if element == nil || copyString(element!, kAXValueAttribute) == nil {
            // Chrome·Electron 은 접근성 트리를 요청받아야 만든다 → 켜고 잠시 뒤 재시도
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(200))
            element = copyElement(appEl, kAXFocusedUIElementAttribute)
        }
        guard let element else { throw AXTextError.noFocus }
        AXUIElementSetMessagingTimeout(element, 1.0)

        if copyString(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            throw AXTextError.secureField
        }
        guard let value = copyString(element, kAXValueAttribute) else { throw AXTextError.unreadable }
        let selection = selectedRange(element) ?? NSRange(location: (value as NSString).length, length: 0)
        return FocusedText(element: element, appName: app.localizedName ?? "앱", value: value, selection: selection)
    }

    static func currentValue(_ element: AXUIElement) -> String? {
        copyString(element, kAXValueAttribute)
    }

    /// 범위의 화면 좌표(Cocoa 좌표계, 좌하단 원점). 지원하지 않는 앱이면 nil.
    static func screenRect(of range: NSRange, in element: AXUIElement) -> NSRect? {
        var cf = CFRange(location: range.location, length: max(range.length, 1))
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out
        ) == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.width >= 0, rect.height > 0 else { return nil }
        // AX 는 주 화면 좌상단 원점 → Cocoa 좌하단 원점으로 변환
        guard let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - 쓰기

    enum WriteMethod: String { case accessibility, paste }

    /// range 를 text 로 바꾼다. AX 직접 쓰기 → 반영 확인 → 실패 시 붙여넣기 대체.
    /// expected: 쓰기 후 기대하는 전체 값 (반영 확인용).
    static func replace(
        in element: AXUIElement, range: NSRange, with text: String, expected: String
    ) async -> WriteMethod? {
        let before = currentValue(element)

        if select(range, in: element),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            if currentValue(element) == expected { return .accessibility }
        }

        // 값이 바뀌지 않았을 때만 붙여넣기로 재시도 (부분 반영된 상태에서 또 쓰면 중복된다)
        guard currentValue(element) == before else {
            return currentValue(element) == expected ? .accessibility : nil
        }
        guard select(range, in: element) else { return nil }
        await paste(text)
        // 붙여넣기는 대상 앱이 비동기로 처리한다 → 잠시 기다린 뒤 확인
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(80))
            if currentValue(element) == expected { return .paste }
        }
        // 일부 웹 에디터는 AXValue 갱신이 늦거나 다르게 보고한다. 바뀌긴 했으면 성공으로 본다.
        return currentValue(element) != before ? .paste : nil
    }

    @discardableResult
    static func select(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// 클립보드로 붙여넣고 원래 클립보드를 복구한다.
    private static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        }
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand   // 눌려 있을 수 있는 ⌃⌥ 를 섞지 않도록 명시
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        try? await Task.sleep(for: .milliseconds(400))
        pb.clearContents()
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    // MARK: - 저수준 헬퍼

    private static func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func copyString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func selectedRange(_ el: AXUIElement) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var cf = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &cf) else { return nil }
        return NSRange(location: cf.location, length: cf.length)
    }
}
