import Foundation

/// 사용자 설정 (UserDefaults). 교정 강도는 CorrectionLevel 이 따로 저장한다.
enum Prefs {
    private enum Key {
        static let scope = "scopeMode"
        static let precompute = "precomputeEnabled"
        static let badge = "badgeEnabled"
        static let excluded = "excludedBundleIDs"
        static let dictionary = "personalDictionary"
        static let history = "historyEnabled"
    }

    static var scope: ScopeMode {
        get { UserDefaults.standard.string(forKey: Key.scope).flatMap(ScopeMode.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.scope) }
    }

    static var precompute: Bool {
        get { UserDefaults.standard.object(forKey: Key.precompute) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.precompute) }
    }

    /// 교정 기록 저장 (기본 꺼짐)
    static var history: Bool {
        get { UserDefaults.standard.bool(forKey: Key.history) }
        set { UserDefaults.standard.set(newValue, forKey: Key.history) }
    }

    /// 개인 사전 (입력한 그대로의 글)
    static var dictionaryText: String {
        get { UserDefaults.standard.string(forKey: Key.dictionary) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.dictionary) }
    }

    static var dictionary: [String] { PersonalDictionary.parse(dictionaryText) }

    /// 고칠 곳 표시 (왼쪽 막대)
    static var indicator: Bool {
        get { UserDefaults.standard.object(forKey: Key.badge) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.badge) }
    }

    /// 미리 교정하지 않을 앱. 저장된 적이 없으면 기본 목록, 사용자가 비웠으면 빈 목록(둘을 구별한다).
    static var excluded: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.excluded) ?? defaultExcluded }
        set { UserDefaults.standard.set(newValue, forKey: Key.excluded) }
    }

    /// 터미널·비밀번호 관리자·코드 편집기
    static let defaultExcluded = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.1password.1password", "com.apple.Passwords", "com.apple.keychainaccess",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", // 마지막은 Cursor
    ]
}
