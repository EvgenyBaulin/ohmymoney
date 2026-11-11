import AppCore
import Foundation
import Security

/// Where the sync key lives: the keychain of this device, never the database, the archive, the
/// journal or the settings. A device that joins later gets the same key from the recovery code
/// (`RecoveryCode`), typed or read from the printed sheet.
protocol SyncKeyStoring: Sendable {
  func load() -> SyncKey?
  /// Distinguishes a missing key from a keychain that is locked or unavailable.
  func read() throws -> SyncKey?
  func save(_ key: SyncKey) throws
}

extension SyncKeyStoring {
  func read() throws -> SyncKey? { load() }

  /// Invalid words never replace the key already on this device.
  func recover(from words: String) throws {
    let key = try SyncKey.recover(from: words).get()
    try save(key)
  }

  /// The key kept, or a new one made, kept and returned with `created == true`.
  func keyCreatingIfNeeded() throws -> (key: SyncKey, created: Bool) {
    if let key = try read() { return (key, false) }
    let key = SyncKey.generate()
    try save(key)
    return (key, true)
  }
}

/// The keychain item of the sync key: a generic password of this app, the way the lock password
/// is kept (`KeychainLockPasswordStore`: no entitlement, readable by the app that wrote it), and
/// never synced through iCloud Keychain — another device takes the key from the recovery code
/// the owner printed, not from Apple. Debug and Release have their own items.
struct KeychainSyncKeyStore: SyncKeyStoring {
  let service: String
  let account: String

  init(
    service: String = (Bundle.main.bundleIdentifier ?? "io.github.EvgenyBaulin.ohmymoney")
      + ".sync",
    account: String = "sync-key"
  ) {
    self.service = service
    self.account = account
  }

  enum Failure: Error, Equatable {
    case status(Int32)
  }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func load() -> SyncKey? {
    try? read()
  }

  func read() throws -> SyncKey? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure.status(status) }
    guard let data = item as? Data, let key = SyncKey(data: data) else {
      throw Failure.status(errSecDecode)
    }
    return key
  }

  func save(_ key: SyncKey) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: key.data,
      kSecAttrLabel as String: "OhMyMoney sync key",
    ]
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw Failure.status(updated) }
    var item = query
    item.merge(attributes) { _, new in new }
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw Failure.status(status) }
  }
}

/// For tests and previews: a key kept in memory.
final class InMemorySyncKeyStore: SyncKeyStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var key: SyncKey?

  init(_ key: SyncKey? = nil) {
    self.key = key
  }

  func load() -> SyncKey? { lock.withLock { key } }
  func save(_ key: SyncKey) throws { lock.withLock { self.key = key } }
}
