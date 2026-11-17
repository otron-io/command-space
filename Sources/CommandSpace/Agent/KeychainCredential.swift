import Foundation
import LocalAuthentication
import Security

/// On macOS, Command Space's existing credentials live in the file-based Keychain.
/// The interaction setting for that Keychain is process-wide. Keep accesses on the
/// main actor and restore the setting immediately after each synchronous query.
@MainActor
struct KeychainCredential {
    enum Status { case available, missing, needsAccess, unavailable }

    let service: String
    let account: String

    private var attributes: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    var status: Status { read().status }

    func read(allowingInteraction: Bool = false) -> (status: Status, value: String?) {
        var query = attributes
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result: OSStatus
        if allowingInteraction {
            result = SecItemCopyMatching(query as CFDictionary, &item)
        } else {
            // A per-query context covers the data protection Keychain. The older
            // file-based Keychain uses its separate interaction setting for ACL prompts.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            guard let status = withoutInteraction({ SecItemCopyMatching(query as CFDictionary, &item) }) else {
                return (.unavailable, nil)
            }
            result = status
        }

        switch result {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                return (.unavailable, nil)
            }
            return (.available, value)
        case errSecItemNotFound: return (.missing, nil)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return (.needsAccess, nil)
        default: return (.unavailable, nil)
        }
    }

    /// Preserve the saved credential if an update fails. Add only when there is no item.
    func save(_ value: String, allowingInteraction: Bool = true) -> Bool {
        let data = Data(value.utf8)
        func write() -> OSStatus {
            let update = SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecItemNotFound else { return update }
            var item = attributes
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil)
        }
        if allowingInteraction { return write() == errSecSuccess }
        let current = status
        guard current == .available || current == .missing else { return false }
        return withoutInteraction(write) == errSecSuccess
    }

    func delete() -> Bool {
        let result = SecItemDelete(attributes as CFDictionary)
        return result == errSecSuccess || result == errSecItemNotFound
    }

    private func withoutInteraction(_ operation: () -> OSStatus) -> OSStatus? {
        var interactionWasAllowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&interactionWasAllowed) == errSecSuccess else { return nil }
        if !interactionWasAllowed.boolValue { return operation() }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return nil }
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return operation()
    }
}
