import Foundation
import Security

/// Where the tokens and passwords of cloud drives live: the keychain of this device, never the
/// database, the archive or the settings.
protocol CloudCredentialStoring: Sendable {
  func load(account: String) -> String?
  func save(_ value: String, account: String) throws
  func remove(account: String)
}

struct KeychainCloudCredentialStore: CloudCredentialStoring {
  let service: String

  init(
    service: String = (Bundle.main.bundleIdentifier ?? "io.github.EvgenyBaulin.ohmymoney")
      + ".cloud"
  ) {
    self.service = service
  }

  struct Failure: Error { let status: Int32 }

  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func load(account: String) -> String? {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func save(_ value: String, account: String) throws {
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw Failure(status: status) }
    var add = query(account)
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { throw Failure(status: added) }
  }

  func remove(account: String) { SecItemDelete(query(account) as CFDictionary) }
}

final class MemoryCloudCredentialStore: CloudCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]
  func load(account: String) -> String? { lock.withLock { values[account] } }
  func save(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
  func remove(account: String) { lock.withLock { _ = values.removeValue(forKey: account) } }
}
