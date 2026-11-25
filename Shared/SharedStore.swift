import Foundation

/// 설정 저장소. iPhone 은 앱과 키보드가 같은 값을 보도록 앱 그룹을 쓴다.
enum SharedStore {
    static let appGroup = "group.com.aib.fix4me"

    /// UserDefaults 는 스레드에 안전하지만 Sendable 로 표시돼 있지 않아 매번 꺼낸다
    static var defaults: UserDefaults {
        #if os(iOS)
        UserDefaults(suiteName: appGroup) ?? .standard
        #else
        .standard
        #endif
    }
}
