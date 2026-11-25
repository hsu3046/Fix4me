import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let history = HistoryStore()
    private lazy var doubleTap = DoubleTapMonitor { [weak self] in self?.controller.correctFocused() }
    private let precomputer: Precomputer
    private let controller: CorrectionController
    private let settingsModel: SettingsModel
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    override init() {
        let service = CorrectionService()
        precomputer = Precomputer(service: service)
        controller = CorrectionController(service: service, precomputer: precomputer, history: history)
        settingsModel = SettingsModel(history: history)
        super.init()
        settingsModel.openHistory = { [weak self] in self?.showHistory() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 단위 테스트 호스트로 뜰 때는 메뉴·단축키를 만들지 않는다
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        setUpMainMenu()
        setUpStatusItem()
        applyShortcuts()
        settingsModel.tabChanged = { [weak self] in self?.updateStatusIcon() }
        settingsModel.shortcutsChanged = { [weak self] in self?.applyShortcuts() }
        precomputer.start()
        doubleTap.start()
        history.prune()

        // 처음 실행이거나 준비가 덜 됐으면 설정 창부터
        if !AXText.isTrusted || Keychain.read(Keychain.openRouterAccount) == nil || !settingsModel.hotKeysOK {
            showSettings()
        }
    }

    /// Dock 아이콘 클릭·Finder/Spotlight 로 다시 열면 설정 창을 띄운다 (없으면 이미 켜진 앱이 무반응)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// 일반 앱(Dock 표시)이 되면 상단 메뉴가 필요하다 — 특히 편집 메뉴가 없으면 키 입력란에서 ⌘V 가 안 된다
    private func setUpMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "교정 기록…", action: #selector(openHistory), keyEquivalent: "y").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Fix4me 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Fix4me", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "편집", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "윈도우")
        window.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "윈도우", action: nil, keyEquivalent: "").submenu = window

        NSApp.mainMenu = main
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.addItem(withTitle: "지금 교정", action: #selector(correctNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "마지막 교정 되돌리기  \(HotKeyCenter.revert.label)", action: #selector(revertNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "교정 기록…", action: #selector(openHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Fix4me 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    /// 켜져 있으면 쓰는 펜, 끄면 빗금 그은 펜
    private func updateStatusIcon() {
        let on = SharedStore.isOn
        statusItem?.button?.image = NSImage(
            systemSymbolName: on ? "pencil.and.scribble" : "pencil.slash", accessibilityDescription: on ? "Fix4me" : "Fix4me (꺼짐)"
        )
    }

    /// 교정 단축키는 하나만: ⌥ 두 번을 고르면 ⌃⌥F 등록을 풀고, 아니면 그 반대
    private func applyShortcuts() {
        var ok = HotKeyCenter.shared.register(HotKeyCenter.revert) { [weak self] in self?.controller.revertLast() }
        if Prefs.doubleTap {
            HotKeyCenter.shared.unregister(HotKeyCenter.correct)
        } else {
            ok = HotKeyCenter.shared.register(HotKeyCenter.correct) { [weak self] in self?.controller.correctFocused() } && ok
        }
        settingsModel.hotKeysOK = ok
    }

    @objc private func correctNow() { controller.correctFocused() }
    @objc private func revertNow() { controller.revertLast() }
    @objc private func openSettings() { showSettings() }
    @objc private func openHistory() { showHistory() }

    private func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(model: HistoryModel(store: history))))
            window.title = "Fix4me 교정 기록"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 560))
            window.contentMinSize = NSSize(width: 520, height: 360)
            historyWindow = window
        }
        historyWindow?.center()
        NSApp.activate()
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    private func showSettings() {
        if settingsWindow == nil {
            // 스크롤 없이 내용 크기에 맞춘 창 (권한 안내가 나타나면 창도 따라 커진다)
            let hosting = NSHostingController(rootView: SettingsView(model: settingsModel))
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "Fix4me 설정"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
