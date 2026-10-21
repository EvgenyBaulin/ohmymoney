import CoreKit
import Foundation

/// The clear-text header of an encrypted archive.
///
/// An encrypted archive is `header || ciphertext || tag`: 48 bytes that say how the key
/// was derived and which cipher was used, followed by whatever `ArchiveCipher.seal`
/// returned for the zip container. The header is authenticated by nothing on its own —
/// changing it makes the tag check fail, which is reported as a wrong password.
///
/// Byte layout, little-endian, fixed size:
///
///     0   8   magic "OHMYARC1"
///     8   2   header version (currently 1)
///     10  2   key derivation identifier (1 = PBKDF2-HMAC-SHA256)
///     12  2   cipher identifier (1 = AES-256-GCM)
///     14  2   reserved, must be zero
///     16  4   PBKDF2 iteration count
///     20  16  salt
///     36  12  nonce
///     48      end of header
///
/// The same 48 bytes must be readable by the future Windows build, so nothing in here
/// depends on the platform or on the order the fields happen to sit in memory.
public struct EncryptionHeader: Equatable, Sendable {
  public static let magic: [UInt8] = [UInt8]("OHMYARC1".utf8)
  public static let byteCount = 48
  public static let currentVersion: UInt16 = 1
  public static let saltByteCount = 16
  public static let nonceByteCount = 12
  public static let keyByteCount = 32
  /// AES-GCM appends a 128-bit authentication tag to the ciphertext.
  public static let tagByteCount = 16

  /// OWASP's Password Storage Cheat Sheet recommends 600 000 iterations for
  /// PBKDF2-HMAC-SHA256 (the figure published in 2023 and unchanged since). It costs a
  /// fraction of a second once per archive — the file is opened by hand, not in a loop —
  /// and it is the number the recommendation names, so there is nothing to invent here.
  /// The count travels inside the header, so raising it later keeps old archives readable.
  public static let recommendedIterations = 600_000
  /// Guard rail for a header that arrives from outside: below one PBKDF2 is undefined, and
  /// an absurdly large count would only be a way to make the application hang.
  public static let iterationBounds = 1...50_000_000

  public enum KeyDerivation: UInt16, Equatable, Sendable {
    case pbkdf2HMACSHA256 = 1
  }

  public enum CipherSuite: UInt16, Equatable, Sendable {
    case aes256GCM = 1
  }

  public let version: UInt16
  public let keyDerivation: KeyDerivation
  public let cipherSuite: CipherSuite
  public let iterations: Int
  public let salt: [UInt8]
  public let nonce: [UInt8]

  public init(
    version: UInt16 = EncryptionHeader.currentVersion,
    keyDerivation: KeyDerivation = .pbkdf2HMACSHA256,
    cipherSuite: CipherSuite = .aes256GCM,
    iterations: Int = EncryptionHeader.recommendedIterations,
    salt: [UInt8],
    nonce: [UInt8]
  ) throws {
    guard salt.count == EncryptionHeader.saltByteCount,
      nonce.count == EncryptionHeader.nonceByteCount,
      EncryptionHeader.iterationBounds.contains(iterations),
      version == EncryptionHeader.currentVersion
    else { throw CoreError.invalidArchive(reason: .unsupportedFormatVersion) }
    self.version = version
    self.keyDerivation = keyDerivation
    self.cipherSuite = cipherSuite
    self.iterations = iterations
    self.salt = salt
    self.nonce = nonce
  }

  public func encoded() -> Data {
    var output = Data()
    output.reserveCapacity(EncryptionHeader.byteCount)
    output.append(contentsOf: EncryptionHeader.magic)
    output.appendLittleEndian(version)
    output.appendLittleEndian(keyDerivation.rawValue)
    output.appendLittleEndian(cipherSuite.rawValue)
    output.appendLittleEndian(UInt16(0))  // reserved
    output.appendLittleEndian(UInt32(iterations))
    output.append(contentsOf: salt)
    output.append(contentsOf: nonce)
    return output
  }

  /// Recognises the magic without parsing anything else, so the application can ask for a
  /// password before it tries to open the file.
  public static func looksEncrypted(_ data: Data) -> Bool {
    guard data.count >= magic.count else { return false }
    return [UInt8](data.prefix(magic.count)) == magic
  }

  public static func decode(_ data: Data) throws -> EncryptionHeader {
    guard looksEncrypted(data) else {
      throw CoreError.invalidArchive(reason: .notAZipContainer)
    }
    guard data.count >= byteCount else {
      throw CoreError.invalidArchive(reason: .truncated)
    }
    let bytes = [UInt8](data.prefix(byteCount))
    let version = uint16(bytes, 8)
    guard version == currentVersion,
      let derivation = KeyDerivation(rawValue: uint16(bytes, 10)),
      let suite = CipherSuite(rawValue: uint16(bytes, 12)),
      uint16(bytes, 14) == 0
    else { throw CoreError.invalidArchive(reason: .unsupportedFormatVersion) }
    let iterations = Int(uint32(bytes, 16))
    return try EncryptionHeader(
      version: version, keyDerivation: derivation, cipherSuite: suite,
      iterations: iterations,
      salt: [UInt8](bytes[20..<(20 + saltByteCount)]),
      nonce: [UInt8](bytes[36..<(36 + nonceByteCount)]))
  }

  /// Stretches the password into the 256-bit content key. The password is the UTF-8 of its
  /// NFC form: «й» typed on the keyboard and «й» pasted from a file name as «и» with a
  /// combining breve are one password, and have to be one key on every machine and in
  /// every implementation.
  public func deriveKey(password: String) -> [UInt8] {
    deriveKey(passwordBytes: Self.passwordBytes(password))
  }

  /// The bytes the format hashes for `password`: UTF-8 of Unicode Normalization Form C.
  public static func passwordBytes(_ password: String) -> [UInt8] {
    [UInt8](password.precomposedStringWithCanonicalMapping.utf8)
  }

  private func deriveKey(passwordBytes: [UInt8]) -> [UInt8] {
    switch keyDerivation {
    case .pbkdf2HMACSHA256:
      return PBKDF2.deriveKey(
        password: passwordBytes, salt: salt, iterations: iterations,
        keyByteCount: EncryptionHeader.keyByteCount)
    }
  }

  // MARK: - Envelope

  /// Wraps `payload` into `header || sealed`. The cipher itself comes from the platform:
  /// `AppCore` owns the format, not the primitive (see the transfer section of the spec).
  public static func seal(
    payload: Data, password: String, cipher: ArchiveCipher, salt: [UInt8], nonce: [UInt8],
    iterations: Int = EncryptionHeader.recommendedIterations
  ) throws -> Data {
    let header = try EncryptionHeader(iterations: iterations, salt: salt, nonce: nonce)
    let key = header.deriveKey(password: password)
    let sealed = try cipher.seal(plaintext: payload, key: Data(key), nonce: Data(nonce))
    var output = header.encoded()
    output.append(sealed)
    return output
  }

  /// Unwraps `header || sealed`. A failing tag cannot tell a wrong password from a tampered
  /// file, and both deserve the same answer, so anything the cipher rejects is reported as
  /// `.wrongPassword`. Only damage that is visible without the key — a file too short to
  /// hold a header and a tag — is reported as `.truncated`.
  public static func open(
    container: Data, password: String, cipher: ArchiveCipher
  ) throws -> Data {
    let header = try decode(container)
    guard container.count >= byteCount + tagByteCount else {
      throw CoreError.invalidArchive(reason: .truncated)
    }
    let sealed = Data(container.suffix(from: container.startIndex + byteCount))
    let normalized = passwordBytes(password)
    // Archives written before 24.09.2026 hashed the password as it was typed. When that was
    // not NFC, those bytes are tried as well, so such an archive still opens with it.
    var candidates = [normalized]
    let asTyped = [UInt8](password.utf8)
    if asTyped != normalized { candidates.append(asTyped) }
    for bytes in candidates {
      let key = header.deriveKey(passwordBytes: bytes)
      if let payload = try? cipher.open(sealed: sealed, key: Data(key), nonce: Data(header.nonce)) {
        return payload
      }
    }
    throw CoreError.invalidArchive(reason: .wrongPassword)
  }

  // MARK: - Random material

  /// Fresh salt and nonce for one archive. AES-GCM breaks if a nonce is ever reused with
  /// the same key, so both are drawn again for every single export.
  public static func makeSalt<Source: RandomSource>(using source: inout Source) -> [UInt8] {
    randomBytes(count: saltByteCount, using: &source)
  }

  public static func makeNonce<Source: RandomSource>(using source: inout Source) -> [UInt8] {
    randomBytes(count: nonceByteCount, using: &source)
  }

  private static func randomBytes<Source: RandomSource>(
    count: Int, using source: inout Source
  ) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    while bytes.count < count {
      var word = source.nextUInt64()
      for _ in 0..<8 where bytes.count < count {
        bytes.append(UInt8(truncatingIfNeeded: word))
        word >>= 8
      }
    }
    return bytes
  }

  private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian(_ value: UInt16) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
  }

  fileprivate mutating func appendLittleEndian(_ value: UInt32) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value >> 16))
    append(UInt8(truncatingIfNeeded: value >> 24))
  }
}
