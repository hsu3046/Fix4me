import AppKit
import SwiftUI

/// 고칠 곳 표시: 문단 왼쪽 막대(위치를 모르면 모서리 배지). 마우스를 올리면 미리보기가 뜬다.
/// 표시는 클릭을 통과시키고, 미리보기 창은 눌러도 입력창의 포커스를 빼앗지 않는다.
@MainActor
final class IndicatorController {
    struct Item: Equatable {
        let range: NSRange
        let original: String
        let corrected: String
        let level: CorrectionLevel
        let isFinal: Bool      // 고른 강도의 결과인지 (다시 쓰기를 기다리는 동안의 교정 결과면 false)
        let rect: NSRect?      // 문단의 화면 위치 (앱이 알려 준 경우)
    }

    struct Content: Equatable {
        let items: [Item]
        let waiting: [NSRect?]   // 교정을 기다리는 섹션의 위치
        let visible: NSRect?
        let caret: NSRect?
        let level: CorrectionLevel
    }

    var onApply: ((Item) -> Void)?
    var onIgnore: ((Item) -> Void)?

    private static let hoverDelay: TimeInterval = 0.2
    private static let leaveDelay: TimeInterval = 0.35

    private var pending: Content?
    private var shown: Content?
    private var marks: [(panel: NSPanel, hit: NSRect, items: [Item])] = []
    private var waitingPanels: [NSPanel] = []
    private var preview: NSPanel?
    private var previewOf: Int?
    private var hoverStart: (index: Int, at: Date)?
    private var lastInside = Date.distantPast
    private var hoverLoop: Task<Void, Never>?

    /// 같은 내용·위치가 두 번 이어졌을 때만 그린다 (스크롤·창 이동 중에는 숨김)
    func update(_ content: Content) {
        guard !content.items.isEmpty || !content.waiting.isEmpty else { return hide() }
        if content == shown { return }
        if content == pending { draw(content) } else { clear(); pending = content }
    }

    func hide() {
        pending = nil
        clear()
    }

    // MARK: - 그리기

    private func clear() {
        hoverLoop?.cancel(); hoverLoop = nil
        closePreview()
        marks.forEach { $0.panel.orderOut(nil) }
        marks = []
        waitingPanels.forEach { $0.orderOut(nil) }
        waitingPanels = []
        shown = nil
        hoverStart = nil
    }

    private func draw(_ content: Content) {
        clear()
        shown = content
        pending = content
        for item in content.items {
            guard let bar = IndicatorLayout.bar(text: item.rect, visible: content.visible) else { continue }
            let panel = Self.makePanel(interactive: false)
            panel.contentView = NSHostingView(rootView: BarView(color: item.level.color))
            panel.setFrame(bar, display: true)
            panel.orderFrontRegardless()
            marks.append((panel, IndicatorLayout.hitArea(bar), [item]))
        }
        drawWaiting(content)
        if marks.isEmpty, !content.items.isEmpty {
            let count = content.items.reduce(0) { $0 + TextDiff.hunks(old: $1.original, new: $1.corrected).count }
            let view = NSHostingView(rootView: PillView(text: "\(count)", color: content.items[0].level.color))
            let size = view.fittingSize
            guard let origin = IndicatorLayout.pillOrigin(size: size, visible: content.visible, caret: content.caret) else { return }
            let panel = Self.makePanel(interactive: false)
            panel.contentView = view
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            panel.orderFrontRegardless()
            marks.append((panel, IndicatorLayout.hitArea(panel.frame), content.items))
        }
        guard !marks.isEmpty else { return }
        hoverLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.trackMouse()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// 준비 중: 흐린 회색 막대. 위치를 모르면 모서리에 "…" (다른 표시가 없을 때만)
    private func drawWaiting(_ content: Content) {
        func show(_ view: NSView, _ frame: NSRect) {
            let panel = Self.makePanel(interactive: false)
            panel.contentView = view
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            waitingPanels.append(panel)
        }
        for rect in content.waiting {
            if let bar = IndicatorLayout.bar(text: rect, visible: content.visible) {
                show(NSHostingView(rootView: BarView(color: .gray).opacity(0.45)), bar)
            }
        }
        guard waitingPanels.isEmpty, !content.waiting.isEmpty, content.items.isEmpty else { return }
        let view = NSHostingView(rootView: PillView(text: "…", color: .gray).opacity(0.7))
        if let origin = IndicatorLayout.pillOrigin(size: view.fittingSize, visible: content.visible, caret: content.caret) {
            show(view, NSRect(origin: origin, size: view.fittingSize))
        }
    }

    // MARK: - 롤오버

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation, now = Date.now
        let over = marks.firstIndex { $0.hit.contains(mouse) }

        if let open = previewOf {
            let insidePreview = preview.map { $0.frame.insetBy(dx: -6, dy: -8).contains(mouse) } ?? false
            if over == open || insidePreview { lastInside = now; hoverStart = nil; return }
            if over == nil, now.timeIntervalSince(lastInside) < Self.leaveDelay { return }
            closePreview()
        }
        guard let over else { hoverStart = nil; return }
        if hoverStart?.index != over { hoverStart = (over, now) }
        if let start = hoverStart, now.timeIntervalSince(start.at) >= Self.hoverDelay { openPreview(over) }
    }

    private func openPreview(_ index: Int) {
        guard shown != nil, marks.indices.contains(index) else { return }
        let mark = marks[index]
        let panel = Self.makePanel(interactive: true)
        let view = ClickThroughHostingView(rootView: PreviewView(
            items: mark.items,
            apply: { [weak self] item in self?.hide(); self?.onApply?(item) },
            ignore: { [weak self] item in self?.hide(); self?.onIgnore?(item) }
        ))
        panel.contentView = view
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(mark.hit) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(origin: IndicatorLayout.previewOrigin(size: size, anchor: mark.panel.frame, screen: visible), size: size), display: true)
        panel.orderFrontRegardless()
        preview = panel
        previewOf = index
        lastInside = .now
        hoverStart = nil
    }

    private func closePreview() {
        preview?.orderOut(nil)
        preview = nil
        previewOf = nil
    }

    private static func makePanel(interactive: Bool) -> NSPanel {
        let panel = QuietPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = interactive
        panel.ignoresMouseEvents = !interactive
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

/// 키 윈도가 되지 않는 패널 — 버튼을 눌러도 입력창의 커서가 그대로 있다
private final class QuietPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 키 윈도가 아니어도 첫 클릭을 버튼에 전달한다
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension CorrectionLevel {
    var color: Color {
        switch self {
        case .proofread: .yellow
        case .polish: .blue
        case .rewrite: .purple
        }
    }
}

private struct BarView: View {
    let color: Color
    var body: some View { RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.85)) }
}

private struct PillView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color == .yellow ? .black : .white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color, in: Capsule())
            .fixedSize()
    }
}

struct PreviewView: View {
    let items: [IndicatorController.Item]
    let apply: (IndicatorController.Item) -> Void
    let ignore: (IndicatorController.Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in row(item) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            Text(footer)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: String {
        let level = items.first?.level.title ?? ""
        return items.allSatisfy(\.isFinal)
            ? "\(level) · 전체 적용 \(Prefs.correctLabel)"
            : "\(level) 결과 먼저 · \(CorrectionLevel.current.title) 준비 중 (\(Prefs.correctLabel) 는 기다렸다 적용)"
    }

    private func row(_ item: IndicatorController.Item) -> some View {
        let segments = TextDiff.segments(old: item.original, new: item.corrected)
        return VStack(alignment: .leading, spacing: 8) {
            if TextDiff.isMostlyChanged(segments) {
                // 거의 다 바뀌면 단어별로 섞지 않고 원문 전체 취소선 → 고친 글
                Text(DiffText.removed(item.original)).opacity(0.8)
                Text(DiffText.added(item.corrected))
            } else {
                Text(DiffText.inline(segments))
            }
            HStack(spacing: 8) {
                Button("적용") { apply(item) }
                Button("무시") { ignore(item) }
            }
            .controlSize(.small)
        }
        .font(.system(size: 13))
        .lineSpacing(3)
    }
}
