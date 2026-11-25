import CoreGraphics

/// 고칠 곳 표시의 위치 계산 (순수 함수, Cocoa 좌표).
enum IndicatorLayout {
    static let barWidth: CGFloat = 4

    /// 문단 왼쪽 막대. 앱이 준 위치가 입력창 밖이거나 말이 안 되면 nil → 모서리 배지로 대신한다.
    static func bar(text: CGRect?, visible: CGRect?) -> CGRect? {
        guard let text, let visible, text.height >= 6, text.width >= 1,
              text.minX >= visible.minX - 4, text.minX < visible.maxX else { return nil }
        let clipped = text.intersection(visible.insetBy(dx: -4, dy: -4))
        guard !clipped.isNull, clipped.height >= 6 else { return nil }
        return CGRect(x: text.minX - 10, y: clipped.minY, width: barWidth, height: clipped.height)
    }

    /// 막대를 조준하기 쉽게 넓힌 마우스 감지 영역
    static func hitArea(_ rect: CGRect) -> CGRect { rect.insetBy(dx: -8, dy: -2) }

    /// 모서리 배지의 오른쪽 아래 기준점. 입력창 위치를 모르면 커서 옆.
    static func pillOrigin(size: CGSize, visible: CGRect?, caret: CGRect?) -> CGPoint? {
        if let visible { return CGPoint(x: visible.maxX - size.width - 6, y: visible.minY + 4) }
        return caret.map { CGPoint(x: $0.maxX + 6, y: $0.maxY - 2) }
    }

    /// 미리보기 창: 표시 위에 두고, 자리가 없으면 아래. 화면 밖으로 나가지 않게.
    static func previewOrigin(size: CGSize, anchor: CGRect, screen: CGRect) -> CGPoint {
        var y = anchor.maxY + 6
        if y + size.height > screen.maxY { y = anchor.minY - size.height - 6 }
        return CGPoint(
            x: max(screen.minX + 4, min(anchor.minX, screen.maxX - size.width - 4)),
            y: max(screen.minY + 4, min(y, screen.maxY - size.height - 4))
        )
    }
}
