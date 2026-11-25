import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 포커스된 입력창의 스냅샷. range 는 UTF-16 단위.
struct FocusedText {
    let element: AXUIElement
    let pid: pid_t
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
        return FocusedText(element: element, pid: app.processIdentifier, appName: app.localizedName ?? "앱", value: value, selection: selection)
    }

    /// 감시용 읽기의 결과. 안 되는 이유는 진단 기록에만 쓴다 (글 내용은 담지 않는다).
    enum Peek {
        case field(FocusedText)
        case skipped(String)
    }

    static let noFocusReason = "포커스 요소 없음"

    /// 미리 교정의 감시용 읽기. 기다리지 않고, 느린 앱에 오래 붙잡히지 않는다.
    static func peek(_ app: NSRunningApplication, maxCharacters: Int) -> Peek {
        guard isTrusted else { return .skipped("권한 없음") }
        // 어느 앱이든 비밀번호 입력 중이면 아무것도 읽지 않는다
        guard !IsSecureEventInputEnabled() else { return .skipped("보안 입력 중") }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        guard let element = copyElement(appEl, kAXFocusedUIElementAttribute) else { return .skipped(noFocusReason) }
        AXUIElementSetMessagingTimeout(element, 0.2)

        let role = copyString(element, kAXRoleAttribute) ?? "?"
        let subrole = copyString(element, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) { return .skipped("비밀번호 칸") }
        if subrole == (kAXSearchFieldSubrole as String) { return .skipped("검색창") }
        // 종류 이름이 아니라 글을 쓸 수 있는 요소인지로 판단한다
        let known = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role)
        guard known || isSettable(element, kAXSelectedTextAttribute) || isSettable(element, kAXValueAttribute) else {
            return .skipped("쓸 수 없는 요소 \(role)")
        }
        // 브라우저의 주소창은 웹 요소가 아니다 → 웹 요소만 본다
        if let id = app.bundleIdentifier, browsers.contains(id), !isWeb(element) { return .skipped("브라우저 화면(주소창 등) \(role)") }

        // 큰 문서는 값을 복사하기 전에 거른다
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success,
           let n = ref as? Int, n > maxCharacters { return .skipped("너무 긴 글") }
        guard let value = copyString(element, kAXValueAttribute) else { return .skipped("글을 읽을 수 없음 \(role)") }
        guard (value as NSString).length <= maxCharacters else { return .skipped("너무 긴 글") }
        let selection = selectedRange(element) ?? NSRange(location: (value as NSString).length, length: 0)
        return .field(FocusedText(element: element, pid: app.processIdentifier, appName: app.localizedName ?? "앱", value: value, selection: selection))
    }

    private static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var ok: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &ok) == .success && ok.boolValue
    }

    /// 섹션의 화면 위치. 글자 위치를 알려 주지 않는 웹 편집기는 안쪽 글 조각들의 위치로 대신한다.
    static func sectionRect(_ range: NSRange, in field: FocusedText) -> NSRect? {
        if !isWeb(field.element), let r = screenRect(of: range, in: field.element) { return r }
        guard isWeb(field.element) else { return nil }
        return EditorText.union(of: textPieces(field.element), covering: range, in: field.value)
            ?? screenRect(of: range, in: field.element)
    }

    private static func textPieces(_ root: AXUIElement, limit: Int = 200) -> [(text: String, rect: CGRect)] {
        var pieces: [(String, CGRect)] = [], visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard visited < limit, depth < 12 else { return }
            visited += 1
            if copyString(el, kAXRoleAttribute) == (kAXStaticTextRole as String) {
                if let t = copyString(el, kAXValueAttribute), let f = frame(el) { pieces.append((t, f)) }
                return
            }
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
                  let children = ref as? [AXUIElement] else { return }
            for c in children { walk(c, depth + 1) }
        }
        walk(root, 0)
        return pieces
    }

    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
    ]
    private static let browsers = chromium.union(["com.apple.Safari", "org.mozilla.firefox"])

    /// Chrome·Electron 의 접근성 트리를 켠다 (앱마다 한 번). 다른 앱에는 영향을 주지 않도록 속성을 나눠 쓴다.
    static func wake(_ app: NSRunningApplication) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let id = app.bundleIdentifier, chromium.contains(id) {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// 보통 방식으로 안 읽히는 앱에만 쓴다 (창 크기 조절이 어색해지는 앱이 있다)
    static func wakeHarder(_ app: NSRunningApplication) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// 커서의 화면 위치. 글 끝처럼 글자가 없는 자리면 바로 앞 글자 기준.
    static func caretRect(_ field: FocusedText) -> NSRect? {
        let loc = field.selection.location
        if loc > 0, let r = screenRect(of: NSRange(location: loc - 1, length: 1), in: field.element) {
            return NSRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
        }
        return screenRect(of: NSRange(location: loc, length: 1), in: field.element)
    }

    /// 입력창에서 실제로 보이는 화면 영역 (입력창 ∩ 스크롤 영역 ∩ 창). 모르면 nil.
    static func visibleFrame(_ element: AXUIElement) -> NSRect? {
        guard var rect = frame(element) else { return nil }
        if let parent = copyElement(element, kAXParentAttribute),
           copyString(parent, kAXRoleAttribute) == (kAXScrollAreaRole as String), let f = frame(parent) {
            rect = rect.intersection(f)
        }
        if let window = copyElement(element, kAXWindowAttribute), let f = frame(window) { rect = rect.intersection(f) }
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    private static func frame(_ element: AXUIElement) -> NSRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
              let primary = NSScreen.screens.first else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return NSRect(x: origin.x, y: primary.frame.height - origin.y - size.height, width: size.width, height: size.height)
    }

    /// 감시용(짧은 제한 시간)으로 얻은 입력창을 쓰기에 맞게 되돌린다
    static func prepareForWriting(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, 1.0)
    }

    /// 이 입력창이 지금도 앞 앱의 포커스인지 (붙여넣기를 엉뚱한 곳에 보내지 않기 위해)
    static func isFocused(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let now = copyElement(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(now, element)
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

    enum WriteResult: Equatable {
        case done(WriteMethod, EditorText.Mapping)
        case untouched   // 위치를 확인하지 못했거나 앱이 받아들이지 않아 글이 그대로다
        case mismatch    // 글이 바뀌었지만 예상과 다르다
    }

    /// edit 를 적용한다. **실제로 선택된 글이 원문과 같은지 확인한 뒤에만** 쓰고, 쓴 뒤의 글이 예상과 같을 때만 성공이다.
    static func replace(in element: AXUIElement, edit: TextEdit, value: String) async -> WriteResult {
        let original = (value as NSString).substring(with: edit.range)
        let expected = (value as NSString).replacingCharacters(in: edit.range, with: edit.text)
        func state() -> WriteResult? {
            guard let now = currentValue(element) else { return nil }
            if EditorText.same(now, expected) { return .done(.paste, .native) }
            return EditorText.same(now, value) ? .untouched : .mismatch
        }

        guard let mapping = await selectVerified(edit.range, original: original, value: value, in: element) else { return .untouched }

        // 웹 편집기는 접근성 쓰기를 성공이라 답하고 무시하거나, 자기 모델과 어긋나게 화면만 바꾼다 → 바로 붙여넣기
        if !isWeb(element),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, edit.text as CFString) == .success {
            // 앱이 늦게 반영할 수 있다 → 기다렸다가 판단한다 (서둘러 또 쓰면 두 번 들어간다)
            for _ in 0..<10 {
                if let r = state(), r != .untouched { return r == .mismatch ? .mismatch : .done(.accessibility, mapping) }
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard await selectVerified(edit.range, original: original, value: value, in: element) != nil else { return .untouched }
        }

        // ⌘V 는 앞에 있는 앱으로 간다 → 그사이 다른 앱·입력창으로 옮겼으면 쓰지 않는다
        guard isFocused(element) else { return .untouched }
        await paste(edit.text)
        // 편집기가 글을 여러 번에 나눠 고치는 동안의 중간 상태를 결과로 보지 않도록 끝까지 기다린다
        var last = state()
        for _ in 0..<12 {
            if case .done = last { return .done(.paste, mapping) }
            try? await Task.sleep(for: .milliseconds(80))
            last = state()
        }
        if case .done = last { return .done(.paste, mapping) }
        return last ?? .mismatch
    }

    /// range 를 선택하고, 선택된 글이 원문과 같은지 확인한다. 줄 전체로 위치를 맞춘 뒤(짧은 글자는 엉뚱한 곳과
    /// 우연히 같을 수 있다) 실제 범위를 다시 확인한다. 하나라도 다르면 nil.
    private static func selectVerified(
        _ range: NSRange, original: String, value: String, in element: AXUIElement
    ) async -> EditorText.Mapping? {
        guard range.length > 0 else { return nil }
        let line = EditorText.lineRange(around: range, in: value)
        let lineText = (value as NSString).substring(with: line)
        for start in [EditorText.Mapping.native, .noNewlines(extra: 0)] {
            guard let mapping = await align(line, lineText, from: start, value: value, in: element) else { continue }
            if select(mapping.map(range, in: value), in: element), await selection(in: element, becomes: original) { return mapping }
        }
        return nil
    }

    /// 줄을 선택해 읽어 보고, 어긋난 만큼 옮겨 가며 맞춘다
    private static func align(
        _ line: NSRange, _ lineText: String, from start: EditorText.Mapping, value: String, in element: AXUIElement
    ) async -> EditorText.Mapping? {
        var mapping = start
        for _ in 0..<8 {
            let target = mapping.map(line, in: value)
            guard target.location >= 0 else { return nil }
            let before = copyString(element, kAXSelectedTextAttribute)
            guard select(target, in: element) else { return nil }
            let got = await settledSelection(in: element, changedFrom: before, wanted: lineText)
            if EditorText.isSelection(got, of: lineText) { return mapping }
            guard case let .noNewlines(extra) = mapping, let shift = EditorText.shift(from: got, to: lineText) else { return nil }
            mapping = .noNewlines(extra: extra + shift)
        }
        return nil
    }

    /// 선택이 반영될 때까지 기다려 읽는다: 원하던 글이면 바로, 아니면 이전 선택에서 바뀌어 두 번 같을 때
    private static func settledSelection(in element: AXUIElement, changedFrom before: String?, wanted: String) async -> String {
        var last: String?
        for n in 0..<14 {
            let now = copyString(element, kAXSelectedTextAttribute) ?? ""
            if EditorText.isSelection(now, of: wanted) { return now }
            if now == last, now != before || n >= 10 { return now }
            last = now
            try? await Task.sleep(for: .milliseconds(30))
        }
        return last ?? ""
    }

    /// 선택이 비동기로 반영되는 앱(Chrome 등)을 기다리며 확인한다
    private static func selection(in element: AXUIElement, becomes wanted: String) async -> Bool {
        for _ in 0..<12 {
            if let now = copyString(element, kAXSelectedTextAttribute), EditorText.isSelection(now, of: wanted) { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    /// 웹(브라우저·Electron) 안의 요소인지
    static func isWeb(_ element: AXUIElement) -> Bool { hasAttribute(element, "AXDOMClassList") }

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

    private static func hasAttribute(_ el: AXUIElement, _ attr: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success, let list = names as? [String] else { return false }
        return list.contains(attr)
    }

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
