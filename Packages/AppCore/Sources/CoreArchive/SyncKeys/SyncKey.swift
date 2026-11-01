import Foundation

/// The key of the exchange between devices: 32 random bytes, made once on the first device and
/// kept in the keychain of every device that joins (the platform's job, never the database's,
/// the archive's or the journal's). It seals nothing itself: the journal files and the snapshot
/// each take a key of their own from it (`HKDF`). A device that lost it is given it back by the
/// recovery code (`RecoveryCode`), the same 32 bytes as 24 words.
///
/// Losing the key loses no money: every device keeps its own database and its copies; only the
/// sealed files in the shared folder have to be written again.
public struct SyncKey: Hashable, Sendable, CustomStringConvertible {
  public static let byteCount = 32

  /// The secret. Never logged: `description` names no byte of it.
  public let bytes: [UInt8]

  /// `nil` unless exactly 32 bytes.
  public init?(bytes: [UInt8]) {
    guard bytes.count == Self.byteCount else { return nil }
    self.bytes = bytes
  }

  public init?(data: Data) {
    self.init(bytes: Array(data))
  }

  /// A new key from `generator` — the system's own generator in the app, a seeded one in tests.
  public static func generate(using generator: inout some RandomNumberGenerator) -> SyncKey {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(byteCount)
    while bytes.count < byteCount {
      var word = generator.next()
      for _ in 0..<8 where bytes.count < byteCount {
        bytes.append(UInt8(truncatingIfNeeded: word))
        word >>= 8
      }
    }
    return SyncKey(bytes: bytes)!
  }

  /// A new key from the system's generator.
  public static func generate() -> SyncKey {
    var system = SystemRandomNumberGenerator()
    return generate(using: &system)
  }

  /// The key typed back from its recovery code.
  public static func recover(from words: String) -> Result<SyncKey, RecoveryCode.Problem> {
    RecoveryCode.entropy(from: words).map { SyncKey(bytes: $0)! }
  }

  public var data: Data { Data(bytes) }

  /// The 24 words of the recovery sheet.
  public var recoveryWords: [String] { RecoveryCode.words(for: bytes)! }

  /// What a key is used for. Each purpose has its own key, derived with its own label.
  public enum Purpose: String, Sendable, CaseIterable {
    case journal = "ohmymoney sync journal v1"
    case snapshot = "ohmymoney sync snapshot v1"
  }

  private static let salt = Array("OhMyMoney sync key".utf8)

  /// The 32-byte AES-256 key for `purpose`.
  public func key(for purpose: Purpose) -> Data {
    Data(
      HKDF.deriveKey(
        inputKeyMaterial: bytes, salt: Self.salt, info: Array(purpose.rawValue.utf8),
        length: Self.byteCount)!)
  }

  /// Eight hex digits that tell two devices' keys apart without showing either: the start of
  /// the SHA-256 of a key derived for nothing else.
  public var fingerprint: String {
    let derived = HKDF.deriveKey(
      inputKeyMaterial: bytes, salt: Self.salt, info: Array("ohmymoney sync fingerprint".utf8),
      length: 32)!
    return String(SHA256.hexDigest(derived).prefix(8))
  }

  public var description: String { "SyncKey(\(fingerprint))" }
}
