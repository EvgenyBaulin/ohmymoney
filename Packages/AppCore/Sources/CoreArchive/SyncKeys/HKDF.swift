import Foundation

/// HKDF with HMAC-SHA256 (RFC 5869): one secret, several keys that say what they are for. The
/// sync key never seals anything itself; the journal and the snapshot each get a key of their
/// own from it, so a key that leaks from one use says nothing about the other.
public enum HKDF {
  /// More than 255 blocks of output is not defined by the RFC.
  public static let maxOutputByteCount = 255 * HMACSHA256.codeByteCount

  /// Step 1: a pseudorandom key from the input key material. An empty salt is a salt of
  /// 32 zero bytes, as the RFC says.
  public static func extract(salt: [UInt8], inputKeyMaterial: [UInt8]) -> [UInt8] {
    let salt = salt.isEmpty ? [UInt8](repeating: 0, count: HMACSHA256.codeByteCount) : salt
    return HMACSHA256.code(key: salt, message: inputKeyMaterial)
  }

  /// Step 2: `length` bytes of keys from the pseudorandom key and the purpose `info`. `nil`
  /// beyond `maxOutputByteCount`.
  public static func expand(
    pseudorandomKey: [UInt8], info: [UInt8], length: Int
  ) -> [UInt8]? {
    guard length >= 0, length <= maxOutputByteCount else { return nil }
    let mac = HMACSHA256(key: pseudorandomKey)
    var output: [UInt8] = []
    output.reserveCapacity(length)
    var previous: [UInt8] = []
    var counter: UInt8 = 1
    while output.count < length {
      previous = mac.authenticationCode(for: previous + info + [counter])
      output.append(contentsOf: previous)
      counter &+= 1
    }
    return Array(output.prefix(length))
  }

  /// Both steps.
  public static func deriveKey(
    inputKeyMaterial: [UInt8], salt: [UInt8], info: [UInt8], length: Int
  ) -> [UInt8]? {
    expand(
      pseudorandomKey: extract(salt: salt, inputKeyMaterial: inputKeyMaterial), info: info,
      length: length)
  }
}
