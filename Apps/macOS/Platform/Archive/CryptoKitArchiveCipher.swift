import AppCore
import CryptoKit
import Foundation

/// AES-256-GCM for the transfer archive.
///
/// The core owns the archive format and derives the key (PBKDF2-HMAC-SHA256 written in pure
/// Swift, so the Windows build can read the same files); the cipher itself comes from
/// CryptoKit, because writing AES-GCM by hand would put the owner's data at risk for no
/// benefit.
public struct CryptoKitArchiveCipher: ArchiveCipher {
  public init() {}

  public func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data {
    let sealed = try AES.GCM.seal(
      plaintext,
      using: SymmetricKey(data: key),
      nonce: AES.GCM.Nonce(data: nonce))
    return sealed.ciphertext + sealed.tag
  }

  public func open(sealed: Data, key: Data, nonce: Data) throws -> Data {
    let tagLength = EncryptionHeader.tagByteCount
    guard sealed.count >= tagLength else {
      throw CoreError.invalidArchive(reason: .truncated)
    }
    let box = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: nonce),
      ciphertext: sealed.dropLast(tagLength),
      tag: sealed.suffix(tagLength))
    do {
      return try AES.GCM.open(box, using: SymmetricKey(data: key))
    } catch {
      // A wrong password and a tampered file are indistinguishable by design.
      throw CoreError.invalidArchive(reason: .wrongPassword)
    }
  }
}
