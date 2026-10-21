import Foundation

/// HMAC-SHA-256 as specified by RFC 2104 (and FIPS 198-1).
///
/// The two padded key blocks are absorbed once at construction time and kept as forked
/// `SHA256` values, so producing a code costs two short hashes instead of four. PBKDF2
/// leans on that: it authenticates millions of 32-byte messages under the same key.
public struct HMACSHA256: Sendable {
  public static let codeByteCount = SHA256.digestByteCount

  private let innerPrefix: SHA256
  private let outerPrefix: SHA256

  public init(key: [UInt8]) {
    var block = [UInt8](repeating: 0, count: SHA256.blockByteCount)
    // A key longer than one block is replaced by its digest; a shorter one is zero-padded.
    let normalized = key.count > SHA256.blockByteCount ? SHA256.hash(key) : key
    for index in 0..<normalized.count { block[index] = normalized[index] }

    var inner = SHA256()
    var outer = SHA256()
    var innerPad = [UInt8](repeating: 0, count: SHA256.blockByteCount)
    var outerPad = [UInt8](repeating: 0, count: SHA256.blockByteCount)
    for index in 0..<SHA256.blockByteCount {
      innerPad[index] = block[index] ^ 0x36
      outerPad[index] = block[index] ^ 0x5C
    }
    inner.update(innerPad)
    outer.update(outerPad)
    self.innerPrefix = inner
    self.outerPrefix = outer
  }

  public init(key: Data) {
    self.init(key: [UInt8](key))
  }

  public init(key: String) {
    self.init(key: [UInt8](key.utf8))
  }

  public func authenticationCode(for message: [UInt8]) -> [UInt8] {
    var inner = innerPrefix
    inner.update(message)
    var outer = outerPrefix
    outer.update(inner.finalize())
    return outer.finalize()
  }

  public func authenticationCode(for message: Data) -> [UInt8] {
    authenticationCode(for: [UInt8](message))
  }

  public func authenticationCode(for message: String) -> [UInt8] {
    authenticationCode(for: [UInt8](message.utf8))
  }

  public static func code(key: [UInt8], message: [UInt8]) -> [UInt8] {
    HMACSHA256(key: key).authenticationCode(for: message)
  }

  /// Constant-time comparison: authentication tags must never be compared byte by byte
  /// with an early exit, otherwise the comparison leaks how much of the tag was right.
  public static func equal(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
  }
}
