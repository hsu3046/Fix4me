import Foundation
import Security

/// 일반 암호 항목. Mac 은 로그인 키체인(같은 인증서의 이 앱만 묻지 않고 읽음), iPhone 은 앱과 키보드가 공유하는 키체인 그룹.
enum Keychain {
    static let service = "com.aib.fix4me"
    static let openRouterAccount = "openrouter-api-key"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 저장 성공 시 errSecSuccess.
    @discardableResult
    static func save(_ account: String, value: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return status }
        var add = base
        add[kSecValueData as String] = data
        #if os(iOS)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly   // 백업·다른 기기로 옮기지 않는다
        #endif
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
