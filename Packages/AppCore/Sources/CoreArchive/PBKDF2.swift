import Foundation

/// PBKDF2 with HMAC-SHA-256 as the pseudorandom function (RFC 8018, section 5.2).
///
/// This is how the archive password becomes a 256-bit key. The iteration count lives in
/// the archive header, so an archive written today still opens after the recommendation
/// is raised — see `EncryptionHeader.recommendedIterations`.
public enum PBKDF2 {
  /// Upper bound on the derived key; the format asks for 32 bytes, the bound only keeps a
  /// malformed header from making us allocate without end.
  public static let maximumKeyByteCount = 4096

  public static func deriveKey(
    password: [UInt8], salt: [UInt8], iterations: Int, keyByteCount: Int
  ) -> [UInt8] {
    precondition(iterations >= 1, "PBKDF2 needs at least one iteration")
    precondition(keyByteCount >= 1, "PBKDF2 needs a positive key length")
    precondition(keyByteCount <= maximumKeyByteCount, "PBKDF2 key length is out of range")

    let function = HMACSHA256(key: password)
    let blockCount = (keyByteCount + HMACSHA256.codeByteCount - 1) / HMACSHA256.codeByteCount
    var derived = [UInt8]()
    derived.reserveCapacity(blockCount * HMACSHA256.codeByteCount)

    var seed = [UInt8]()
    seed.reserveCapacity(salt.count + 4)
    for blockIndex in 1...blockCount {
      let counter = UInt32(blockIndex)
      seed.removeAll(keepingCapacity: true)
      seed.append(contentsOf: salt)
      seed.append(UInt8(truncatingIfNeeded: counter >> 24))
      seed.append(UInt8(truncatingIfNeeded: counter >> 16))
      seed.append(UInt8(truncatingIfNeeded: counter >> 8))
      seed.append(UInt8(truncatingIfNeeded: counter))

      var current = function.authenticationCode(for: seed)
      var accumulated = current
      if iterations > 1 {
        for _ in 1..<iterations {
          current = function.authenticationCode(for: current)
          for index in 0..<accumulated.count { accumulated[index] ^= current[index] }
        }
      }
      derived.append(contentsOf: accumulated)
    }
    return [UInt8](derived[0..<keyByteCount])
  }

  /// The password is taken as UTF-8, exactly as given: this is the primitive of RFC 8018.
  /// The archive normalises its password to NFC first (`EncryptionHeader.passwordBytes`).
  public static func deriveKey(
    password: String, salt: [UInt8], iterations: Int, keyByteCount: Int
  ) -> [UInt8] {
    deriveKey(
      password: [UInt8](password.utf8), salt: salt, iterations: iterations,
      keyByteCount: keyByteCount)
  }
}
