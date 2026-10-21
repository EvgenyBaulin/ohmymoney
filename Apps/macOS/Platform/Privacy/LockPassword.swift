import AppCore
import Foundation
import Security

/// The password of «OhMyMoney» itself, as it is kept: never the password, only a salted
/// PBKDF2-HMAC-SHA256 of it, in the Keychain of this Mac — not in the database, not in the
/// archive, not in the journal.
///
/// The password is taken in NFC, as the archive takes its own: «й» typed on the keyboard and «й»
/// pasted as «и» with a combining breve are one password. The iteration count travels in the
/// record, so a record written today still opens after the count is raised.
struct LockPassword: Codable, Equatable, Sendable {
  /// The fewest characters a password may have.
  static let minimumLength = 4

  /// OWASP's figure for PBKDF2-HMAC-SHA256, the same as the archive's
  /// (`EncryptionHeader.recommendedIterations`): about half a second in the optimised build, run
  /// away from the main thread, once per unlock — slow enough that a copy of the record is
  /// not worth guessing at, and the pause after wrong attempts guards the window itself. The
  /// unoptimised Debug build runs the same code fifty times slower, so it uses fewer; its
  /// records live under its own bundle id and never meet the Release ones.
  #if DEBUG
    static let iterations = 20_000
  #else
    static let iterations = EncryptionHeader.recommendedIterations
  #endif
  static let saltByteCount = 16
  static let keyByteCount = 32

  /// The format of the record; a later one may change how it is read.
  var version = 1
  var iterations: Int
  var salt: [UInt8]
  var hash: [UInt8]

  /// What is wrong with a new password typed twice, if anything.
  enum Issue: Equatable, Sendable {
    case tooShort
    case mismatch
  }

  /// The first thing wrong with a new password and its repetition: too short, then different.
  static func issue(_ password: String, repeated: String) -> Issue? {
    if password.precomposedStringWithCanonicalMapping.count < minimumLength { return .tooShort }
    if password.precomposedStringWithCanonicalMapping
      != repeated.precomposedStringWithCanonicalMapping
    {
      return .mismatch
    }
    return nil
  }

  /// A record of a new password with a fresh random salt. Slow: called away from the main
  /// actor.
  static func make(_ password: String, iterations: Int = LockPassword.iterations) -> LockPassword {
    var generator = SystemRandomNumberGenerator()
    let salt = (0..<saltByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return make(password, salt: salt, iterations: iterations)
  }

  static func make(_ password: String, salt: [UInt8], iterations: Int) -> LockPassword {
    LockPassword(
      iterations: iterations, salt: salt,
      hash: derive(password, salt: salt, iterations: iterations))
  }

  /// Whether a typed password is the one of the record. Slow: called away from the main actor.
  /// Every byte is compared, so the time does not tell how much of a guess was right.
  func matches(_ password: String) -> Bool {
    guard version == 1, (1...EncryptionHeader.iterationBounds.upperBound).contains(iterations),
      !hash.isEmpty
    else { return false }
    let candidate = Self.derive(password, salt: salt, iterations: iterations)
    guard candidate.count == hash.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(candidate, hash) { difference |= left ^ right }
    return difference == 0
  }

  private static func derive(_ password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
    PBKDF2.deriveKey(
      password: [UInt8](password.precomposedStringWithCanonicalMapping.utf8), salt: salt,
      iterations: iterations, keyByteCount: keyByteCount)
  }

  /// The bytes kept in the Keychain.
  func encoded() -> Data {
    (try? JSONEncoder().encode(self)) ?? Data()
  }

  /// A record read back; nothing for bytes that are not one.
  static func decoded(_ data: Data) -> LockPassword? {
    try? JSONDecoder().decode(LockPassword.self, from: data)
  }
}

/// Where the record of the password lives. The app keeps it in the Keychain
/// (`KeychainLockPasswordStore`); a test hands in one in memory, so no test touches the
/// owner's Keychain.
protocol LockPasswordStore: AnyObject, Sendable {
  func read() throws -> Data?
  func write(_ data: Data) throws
  func delete() throws
}

/// What the Keychain answered, when it was not a success: the status code alone goes to the
/// journal.
struct KeychainFailure: Error, Equatable {
  let status: OSStatus
}

/// The record of the password in memory: for tests, and for the test host.
final class InMemoryLockPasswordStore: LockPasswordStore, @unchecked Sendable {
  private let guardLock = NSLock()
  private var data: Data?
  /// When set, every call fails with it: a Keychain that refuses.
  var failure: KeychainFailure?

  init(_ data: Data? = nil) { self.data = data }

  func read() throws -> Data? {
    try guardLock.withLock {
      if let failure { throw failure }
      return data
    }
  }

  func write(_ data: Data) throws {
    try guardLock.withLock {
      if let failure { throw failure }
      self.data = data
    }
  }

  func delete() throws {
    try guardLock.withLock {
      if let failure { throw failure }
      data = nil
    }
  }
}

/// The record of the password in the login Keychain of this Mac, a generic password of the
/// service «<bundle id>.lock».
///
/// The file-based login Keychain, not the data-protection one: the data-protection Keychain on
/// macOS needs a `keychain-access-groups` entitlement backed by a provisioning profile, which a
/// build signed by the owner's own certificate or ad-hoc does not have (it answers
/// `errSecMissingEntitlement`). The sandbox lets an app keep its own items in the login
/// Keychain without any entitlement; the item is readable by the app that wrote it — the
/// designated requirement of «OhMyMoney Local Signing» stays the same from one update to the next.
/// The item never syncs (`kSecAttrSynchronizable` false): another Mac may have no such app.
/// Debug and Release have their own bundle ids and so their own items.
final class KeychainLockPasswordStore: LockPasswordStore, @unchecked Sendable {
  let service: String
  let account: String

  init(
    service: String = (Bundle.main.bundleIdentifier ?? "io.github.EvgenyBaulin.ohmymoney")
      + ".lock",
    account: String = "app-password"
  ) {
    self.service = service
    self.account = account
  }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func read() throws -> Data? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    switch status {
    case errSecSuccess: return result as? Data
    case errSecItemNotFound: return nil
    default: throw KeychainFailure(status: status)
    }
  }

  func write(_ data: Data) throws {
    let update = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw KeychainFailure(status: update) }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrLabel as String] = "OhMyMoney lock password"
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainFailure(status: added) }
  }

  func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainFailure(status: status)
    }
  }
}
