import AppCore
import Foundation

/// Reads the key for every operation: restoring the recovery words takes effect without a
/// restart. Keychain failures never cause a plaintext write. The database package only sees
/// PayloadCodec; CryptoKit remains in the platform layer behind ArchiveCipher.
struct RecoveryPayloadCodec: PayloadCodec {
  let store: any SyncKeyStoring
  let purpose: SyncKey.Purpose

  func encode(_ plain: Data) throws -> Data {
    // The first device makes the key explicitly; a joining device enters its recovery words.
    // Inventing a new key here would publish unreadable files into an existing shared folder.
    guard let key = try store.read() else { throw SyncError.codec }
    return try sealed(key).encode(plain)
  }

  func decode(_ stored: Data) throws -> Data {
    if !SealedPayloadCodec.isSealed(stored) {
      switch purpose {
      case .journal:
        if stored.first == UInt8(ascii: "{") { return stored }
      case .snapshot:
        if stored.starts(with: Data("SQLite format 3\0".utf8)) { return stored }
      }
      throw SyncError.codec
    }
    guard let key = try store.read() else { throw SyncError.codec }
    return try sealed(key).decode(stored)
  }

  private func sealed(_ key: SyncKey) -> SealedPayloadCodec {
    SealedPayloadCodec(
      cipher: CryptoKitArchiveCipher(), key: key.key(for: purpose), acceptsPlain: false)
  }
}
