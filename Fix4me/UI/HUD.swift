import AppKit
import SwiftUI

enum HUDState: Equatable {
    case working(String)   // 진행 문구 (강도별: 교정 중… / 다듬는 중…)
    case done(count: Int, preview: String, seconds: Double)
    case noChange(seconds: Double)
    case reverted
    case error(String)
}

/// 커서 근처에 뜨는 작은 상태 표시. 포커스를 빼앗지 않고 클릭도 통과시킨다.
@MainActor
final class HUDController {
    private let panel: NSPanel
    private let hosting = NSHostingView(rootView: HUDView(state: .working("")))
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
    }

    /// anchor: 교정 대상 텍스트의 화면 사각형(Cocoa 좌표). 없으면 마우스 위치.
    func show(_ state: HUDState, near anchor: NSRect?) {
        hosting.rootView = HUDView(state: state)
        let size = hosting.fittingSize
        panel.setContentSize(size)

        let point: NSPoint
        if let anchor {
            point = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6) // 텍스트 바로 아래
        } else {
            let mouse = NSEvent.mouseLocation
            point = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        }
        panel.setFrameOrigin(clamped(point, size: size))
        panel.orderFrontRegardless()

        hideTask?.cancel()
        if case .working = state { return }   // 진행 중에는 자동으로 숨기지 않는다
        var delay: Duration = .seconds(2.5)
        if case .error = state { delay = .seconds(4) } // 오류는 읽을 시간을 더 준다
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }

    private func clamped(_ p: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return p }
        return NSPoint(
            x: min(max(p.x, frame.minX + 4), frame.maxX - size.width - 4),
            y: min(max(p.y, frame.minY + 4), frame.maxY - size.height - 4)
        )
    }
}

private struct HUDView: View {
    let state: HUDState

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .noChange: Image(systemName: "hand.thumbsup.fill").foregroundStyle(.blue)
        case .reverted: Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.orange)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
    }

    private var title: String {
        switch state {
        case let .working(title): title
        case let .done(count, _, s): "\(count)곳 고쳤어요 · \(String(format: "%.1f", s))초"
        case let .noChange(s): "고칠 곳이 없어요 · \(String(format: "%.1f", s))초"
        case .reverted: "원래대로 되돌렸어요"
        case let .error(message): message
        }
    }

    private var detail: String? {
        switch state {
        case let .done(_, preview, _): "\(preview)   ·   \(HotKeyCenter.revert.label) 되돌리기"
        default: nil
        }
    }
}
