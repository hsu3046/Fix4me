import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let controller = CorrectionController()
    private let settingsModel = SettingsModel()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 단위 테스트 호스트로 뜰 때는 메뉴·단축키를 만들지 않는다
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        setUpStatusItem()
        let ok1 = HotKeyCenter.shared.register(HotKeyCenter.correct) { [weak self] in self?.controller.correctFocused() }
        let ok2 = HotKeyCenter.shared.register(HotKeyCenter.revert) { [weak self] in self?.controller.revertLast() }
        settingsModel.hotKeysOK = ok1 && ok2

        // 처음 실행이거나 준비가 덜 됐으면 설정 창부터
        if !AXText.isTrusted || Keychain.read(Keychain.openRouterAccount) == nil || !settingsModel.hotKeysOK {
            showSettings()
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Fix4me")

        let menu = NSMenu()
        menu.addItem(withTitle: "지금 교정  \(HotKeyCenter.correct.label)", action: #selector(correctNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "마지막 교정 되돌리기  \(HotKeyCenter.revert.label)", action: #selector(revertNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Fix4me 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func correctNow() { controller.correctFocused() }
    @objc private func revertNow() { controller.revertLast() }
    @objc private func openSettings() { showSettings() }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settingsModel)))
            window.title = "Fix4me 설정"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            // 내용의 fitting size 에 기대지 않고 첫 크기를 명시 (SettingsView 의 ideal 크기와 같게)
            window.setContentSize(NSSize(width: 520, height: 540))
            window.contentMinSize = NSSize(width: 460, height: 360)
            settingsWindow = window
        }
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
