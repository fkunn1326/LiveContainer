import Foundation
import Security

final class XToolPairingStore {
    static let shared = XToolPairingStore()

    private let service = "org.xtool.XToolRunner.pairing-token"
    private let account = "default"
    private let lock = NSLock()

    enum StoreError: Error, LocalizedError {
        case keychain(OSStatus)
        case invalidToken

        var errorDescription: String? {
            switch self {
            case .keychain(let status): "Keychain error \(status)"
            case .invalidToken: "Stored pairing token is not 32 bytes"
            }
        }
    }

    func tokenData() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            let token = XToolCrypto.randomBytes(count: 32)
            try save(token)
            return token
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data, data.count == 32 else { throw StoreError.invalidToken }
        return data
    }

    func regenerate() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let token = XToolCrypto.randomBytes(count: 32)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let updateAttributes: [CFString: Any] = [kSecValueData: token]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let item = query.merging([
                kSecValueData: token,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { _, new in new }
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw StoreError.keychain(status) }
        } else if updateStatus != errSecSuccess {
            throw StoreError.keychain(updateStatus)
        }
        return token
    }

    func displayToken() throws -> String { XToolCrypto.base64URL(try tokenData()) }

    private func save(_ token: Data) throws {
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: token,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }
}
