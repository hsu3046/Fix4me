import Carbon.HIToolbox

/// Carbon 전역 단축키. 손쉬운 사용 권한 없이도 동작하고, 어떤 앱이 앞에 있어도 먼저 받는다.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 사용자에게 보여줄 단축키 정의
    struct Binding {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    // ⌃⌥Space 는 macOS 기본 "다음 입력 소스" 단축키라 피한다
    static let correct = Binding(id: 1, keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥F")
    static let revert = Binding(id: 2, keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Z")

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    /// 등록 성공 여부를 돌려준다 (다른 앱이 이미 점유하면 false).
    func register(_ binding: Binding, handler: @escaping () -> Void) -> Bool {
        if refs[binding.id] != nil { handlers[binding.id] = handler; return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4634_4D45) /* 'F4ME' */, id: binding.id)
        let status = RegisterEventHotKey(
            binding.keyCode, binding.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        refs[binding.id] = ref
        handlers[binding.id] = handler
        return true
    }

    /// 등록을 풀어 다른 앱이 그 키를 쓸 수 있게 한다
    func unregister(_ binding: Binding) {
        if let ref = refs.removeValue(forKey: binding.id) { UnregisterEventHotKey(ref) }
        handlers[binding.id] = nil
    }

    private func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id = hotKeyID.id
            // Carbon 이벤트는 메인 런루프에서 전달된다
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
