import AppKit
import SwiftUI

/// 커서 옆 "고칠 곳 N" 배지. 포커스를 빼앗지 않고 클릭을 통과시킨다.
@MainActor
final class BadgeController {
    private let panel: NSPanel
    private let hosting = NSHostingView(rootView: BadgeView(count: 0))

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
    }

    func show(_ count: Int, at caret: NSRect) {
        hosting.rootView = BadgeView(count: count)
        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: caret.maxX + 6, y: caret.maxY - 2)) // 커서 오른쪽 위
        panel.orderFrontRegardless()
    }

    func hide() { if panel.isVisible { panel.orderOut(nil) } }
}

private struct BadgeView: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.blue, in: Capsule())
            .fixedSize()
    }
}
