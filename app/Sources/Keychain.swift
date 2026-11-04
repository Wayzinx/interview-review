import Foundation
import Security

/// DeepSeek API key 存在 macOS 钥匙串里（「钥匙串访问」里搜"面试复盘"能看到），不落明文文件。
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.interview-review",
        kSecAttrAccount as String: "deepseek-api-key",
    ]

    static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(data: d, encoding: .utf8)
        return s?.isEmpty == false ? s : nil
    }

    /// 传空字符串 = 删除
    @discardableResult
    static func save(_ value: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var q = base
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrLabel as String] = "面试复盘 · DeepSeek API key"
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
