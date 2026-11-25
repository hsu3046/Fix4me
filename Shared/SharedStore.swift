import Foundation

/// 설정값을 두는 곳
protocol SettingsStore {
    func string(forKey key: String) -> String?
    /// 저장했으면 true
    @discardableResult func save(_ value: String, forKey key: String) -> Bool
}

extension UserDefaults: SettingsStore {
    func save(_ value: String, forKey key: String) -> Bool {
        set(value, forKey: key)
        return true
    }
}

/// 앱과 키보드가 함께 읽는 저장소 (iPhone). 작은 설정 몇 개뿐이라, 따로 등록해야 하는 앱 그룹 대신 API 키와 같은 공유 키체인을 쓴다.
struct KeychainSettings: SettingsStore {
    func string(forKey key: String) -> String? { Keychain.read("setting." + key) }
    func save(_ value: String, forKey key: String) -> Bool { Keychain.save("setting." + key, value: value) == errSecSuccess }
}

/// 설정 저장소: Mac 은 UserDefaults, iPhone 은 공유 키체인
enum SharedStore {
    private static let dictionaryKey = "personalDictionary"
    private static let stubKey = "stubCorrections"
    private static let offKey = "correctionOff"

    static var store: any SettingsStore {
        #if os(iOS)
        KeychainSettings()
        #else
        UserDefaults.standard
        #endif
    }

    /// 개인 사전 (입력한 그대로의 글)
    static var dictionaryText: String { store.string(forKey: dictionaryKey) ?? "" }
    @discardableResult static func saveDictionary(_ text: String) -> Bool { store.save(text, forKey: dictionaryKey) }

    /// 교정을 켜 두었는지 (저장된 적이 없으면 켜짐). 끄면 아무것도 보내지 않는다
    static var isOn: Bool { isOn(in: store) }
    static func isOn(in store: any SettingsStore) -> Bool { store.string(forKey: offKey) != "1" }
    static func saveOn(_ on: Bool, to store: any SettingsStore = store) -> Bool { store.save(on ? "0" : "1", forKey: offKey) }

    /// 시험용 가짜 교정 (디버그 빌드에서만 쓴다)
    static var stubCorrections: Bool {
        get { store.string(forKey: stubKey) == "1" }
        set { store.save(newValue ? "1" : "0", forKey: stubKey) }
    }
}
