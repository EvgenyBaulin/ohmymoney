import CoreKit
import Foundation

/// A journal file or a snapshot sealed with AES-256-GCM under a key of the sync key.
///
///     "OMMSEAL1" (8 bytes) · nonce (12 bytes) · ciphertext · tag (16 bytes)
///
/// The cipher is the platform's (`ArchiveCipher`: CryptoKit on Apple systems), the format is
/// the core's, so another platform reads the same bytes with its own AES-GCM. Every file takes
/// a fresh random nonce. Opening checks the tag first: a wrong key and a changed byte are the
/// same failure, and nothing of such a file is used.
///
/// A file that does not start with the magic is read as it is when it is plain JSON
/// (`acceptsPlain`): the journal files written before sealing existed stay readable for ever.
public struct SealedPayloadCodec: PayloadCodec {
  public static let magic = Array("OMMSEAL1".utf8)
  public static let nonceByteCount = 12
  public static let tagByteCount = 16

  private let cipher: any ArchiveCipher
  private let key: Data
  private let acceptsPlain: Bool
  private let makeNonce: @Sendable () -> [UInt8]

  /// `key` is 32 bytes (`SyncKey.key(for:)`). `makeNonce` is for tests; the app leaves the
  /// system's generator.
  public init(
    cipher: any ArchiveCipher, key: Data, acceptsPlain: Bool = true,
    makeNonce: @escaping @Sendable () -> [UInt8] = SealedPayloadCodec.randomNonce
  ) {
    self.cipher = cipher
    self.key = key
    self.acceptsPlain = acceptsPlain
    self.makeNonce = makeNonce
  }

  public static func randomNonce() -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<nonceByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  /// Whether `data` is sealed by this format (whatever the key).
  public static func isSealed(_ data: Data) -> Bool {
    data.count >= magic.count && Array(data.prefix(magic.count)) == magic
  }

  public func encode(_ plain: Data) throws -> Data {
    let nonce = makeNonce()
    guard nonce.count == Self.nonceByteCount, key.count == 32 else { throw SyncError.codec }
    let sealed = try cipher.seal(plaintext: plain, key: key, nonce: Data(nonce))
    return Data(Self.magic) + Data(nonce) + sealed
  }

  public func decode(_ stored: Data) throws -> Data {
    guard Self.isSealed(stored) else {
      // A file of before sealing: JSON, which always opens with a brace.
      if acceptsPlain, stored.first == UInt8(ascii: "{") { return stored }
      throw SyncError.codec
    }
    let body = stored.dropFirst(Self.magic.count)
    guard body.count >= Self.nonceByteCount + Self.tagByteCount, key.count == 32 else {
      throw SyncError.codec
    }
    let nonce = Data(body.prefix(Self.nonceByteCount))
    let sealed = Data(body.dropFirst(Self.nonceByteCount))
    do {
      return try cipher.open(sealed: sealed, key: key, nonce: nonce)
    } catch {
      throw SyncError.codec
    }
  }
}
