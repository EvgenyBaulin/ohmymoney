import CoreKit
import Foundation
import Testing

@testable import CoreArchive

@Suite("The encrypted archive envelope")
struct EncryptionTests {
  private let supported = 7
  private let salt = repeated(0xA5, 16)
  private let nonce = repeated(0x5A, 12)
  /// The real default is 600 000; the tests use a small count so the suite stays quick.
  private let iterations = 1_000

  @Test func headerParametersFollowTheCurrentRecommendation() {
    // OWASP: 600 000 iterations for PBKDF2-HMAC-SHA256.
    #expect(EncryptionHeader.recommendedIterations == 600_000)
    #expect(EncryptionHeader.saltByteCount == 16)
    #expect(EncryptionHeader.nonceByteCount == 12)
    #expect(EncryptionHeader.keyByteCount == 32)
    #expect(EncryptionHeader.tagByteCount == 16)
    #expect(EncryptionHeader.byteCount == 48)
  }

  @Test func headerRoundTripsThroughItsBytes() throws {
    let header = try EncryptionHeader(iterations: 600_000, salt: salt, nonce: nonce)
    let encoded = header.encoded()
    #expect(encoded.count == EncryptionHeader.byteCount)
    #expect([UInt8](encoded.prefix(8)) == [UInt8]("OHMYARC1".utf8))
    #expect(try EncryptionHeader.decode(encoded) == header)

    let decoded = try EncryptionHeader.decode(encoded)
    #expect(decoded.version == 1)
    #expect(decoded.keyDerivation == .pbkdf2HMACSHA256)
    #expect(decoded.cipherSuite == .aes256GCM)
    #expect(decoded.iterations == 600_000)
    #expect(decoded.salt == salt)
    #expect(decoded.nonce == nonce)
  }

  @Test func headerRejectsMaterialOfTheWrongSize() {
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try EncryptionHeader(salt: repeated(0x01, 15), nonce: repeated(0x02, 12))
    }
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try EncryptionHeader(salt: repeated(0x01, 16), nonce: repeated(0x02, 16))
    }
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try EncryptionHeader(iterations: 0, salt: repeated(0x01, 16), nonce: repeated(0x02, 12))
    }
  }

  @Test func headerRejectsAnUnknownKeyDerivationOrCipher() throws {
    var encoded = try EncryptionHeader(salt: salt, nonce: nonce).encoded()
    encoded[encoded.startIndex + 10] = 9  // unknown key derivation identifier
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try EncryptionHeader.decode(encoded)
    }
    var other = try EncryptionHeader(salt: salt, nonce: nonce).encoded()
    other[other.startIndex + 12] = 9  // unknown cipher identifier
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try EncryptionHeader.decode(other)
    }
  }

  @Test func aFileWithoutTheMagicIsNotAnEncryptedArchive() throws {
    let plain = try sampleBuilder().build()
    #expect(!ArchiveOpener.isEncrypted(plain))
    #expect(throws: CoreError.invalidArchive(reason: .notAZipContainer)) {
      try EncryptionHeader.decode(plain)
    }
  }

  @Test func keyDerivationIsPbkdf2OverThePasswordAndSalt() throws {
    let header = try EncryptionHeader(iterations: iterations, salt: salt, nonce: nonce)
    let expected = PBKDF2.deriveKey(
      password: "correct horse", salt: salt, iterations: iterations, keyByteCount: 32)
    #expect(header.deriveKey(password: "correct horse") == expected)
    #expect(header.deriveKey(password: "correct horse").count == 32)
    #expect(header.deriveKey(password: "wrong horse") != expected)
  }

  /// «й» typed on the keyboard is one scalar (NFC); pasted from a file name it can be «и» and a
  /// combining breve (NFD). Both look the same and are the same password, but their UTF-8
  /// differs, and so did the keys: an archive locked on one Mac refused the owner on another.
  private let composed = "\u{043F}\u{0430}\u{0440}\u{043E}\u{043B}\u{044C} \u{0439}"
  private let decomposed = "\u{043F}\u{0430}\u{0440}\u{043E}\u{043B}\u{044C} \u{0438}\u{0306}"

  @Test func theKeyComesFromTheNFCFormOfThePassword() throws {
    #expect([UInt8](composed.utf8) != [UInt8](decomposed.utf8))
    let header = try EncryptionHeader(iterations: iterations, salt: salt, nonce: nonce)
    let nfc = PBKDF2.deriveKey(
      password: [UInt8](composed.utf8), salt: salt, iterations: iterations, keyByteCount: 32)
    #expect(header.deriveKey(password: composed) == nfc)
    #expect(header.deriveKey(password: decomposed) == nfc)
    // The bytes the archive format gives for the Windows reader.
    #expect(
      EncryptionHeader.passwordBytes(decomposed)
        == bytes(hex: "d0 bf d0 b0 d1 80 d0 be d0 bb d1 8c 20 d0 b9"))
  }

  @Test func anArchiveLockedWithOneFormOpensWithTheOther() throws {
    let builder = try sampleBuilder()
    for (written, typed) in [(decomposed, composed), (composed, decomposed)] {
      let sealed = try builder.build(
        password: written, cipher: TestCipher(), salt: salt, nonce: nonce,
        iterations: iterations)
      let archive = try ArchiveOpener.open(
        sealed, password: typed, cipher: TestCipher(), supportedSchemaVersion: supported)
      #expect(archive.manifest == builder.manifest())
    }
  }

  /// An archive written before the password was normalised has its key from the bytes as they
  /// were typed. When they were not NFC, the opening tries them too, so it still opens.
  @Test func anArchiveLockedWithTheBytesOfADecomposedPasswordStillOpens() throws {
    let payload = try sampleBuilder().build()
    let header = try EncryptionHeader(iterations: iterations, salt: salt, nonce: nonce)
    let asTyped = PBKDF2.deriveKey(
      password: [UInt8](decomposed.utf8), salt: salt, iterations: iterations, keyByteCount: 32)
    var container = header.encoded()
    container.append(
      try TestCipher().seal(plaintext: payload, key: Data(asTyped), nonce: Data(nonce)))
    #expect(
      try EncryptionHeader.open(container: container, password: decomposed, cipher: TestCipher())
        == payload)
    #expect(throws: CoreError.invalidArchive(reason: .wrongPassword)) {
      try EncryptionHeader.open(container: container, password: "parol", cipher: TestCipher())
    }
  }

  @Test func sealedArchiveOpensWithTheRightPassword() throws {
    let builder = try sampleBuilder()
    let sealed = try builder.build(
      password: "пароль", cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)

    #expect(ArchiveOpener.isEncrypted(sealed))
    #expect(sealed.count == EncryptionHeader.byteCount + (try builder.build().count) + 16)
    let archive = try ArchiveOpener.open(
      sealed, password: "пароль", cipher: TestCipher(), supportedSchemaVersion: supported)
    #expect(archive.manifest == builder.manifest())
    #expect(archive.database == Data([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65]))
    #expect(archive.settings == Data("{\"language\":\"ru\"}".utf8))
  }

  @Test func theContainerIsNotReadableWithoutTheKey() throws {
    let builder = try sampleBuilder()
    let sealed = try builder.build(
      password: "пароль", cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)
    let body = Data(sealed.suffix(from: sealed.startIndex + EncryptionHeader.byteCount))
    #expect(throws: CoreError.self) { try ZipReader.entries(in: body) }
  }

  @Test func theWrongPasswordIsReportedAsSuch() throws {
    let sealed = try sampleBuilder().build(
      password: "пароль", cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)
    #expect(throws: CoreError.invalidArchive(reason: .wrongPassword)) {
      try ArchiveOpener.open(
        sealed, password: "parol", cipher: TestCipher(), supportedSchemaVersion: supported)
    }
    #expect(throws: CoreError.invalidArchive(reason: .wrongPassword)) {
      try ArchiveOpener.open(
        sealed, password: "", cipher: TestCipher(), supportedSchemaVersion: supported)
    }
  }

  @Test func anEditedCiphertextFailsTheSameWayAWrongPasswordDoes() throws {
    var sealed = try sampleBuilder().build(
      password: "пароль", cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)
    sealed[sealed.startIndex + EncryptionHeader.byteCount + 5] ^= 0x01
    #expect(throws: CoreError.invalidArchive(reason: .wrongPassword)) {
      try ArchiveOpener.open(
        sealed, password: "пароль", cipher: TestCipher(), supportedSchemaVersion: supported)
    }
  }

  @Test func anEditedHeaderAlsoFails() throws {
    var sealed = try sampleBuilder().build(
      password: "пароль", cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)
    sealed[sealed.startIndex + 20] ^= 0x01  // first byte of the salt
    #expect(throws: CoreError.invalidArchive(reason: .wrongPassword)) {
      try ArchiveOpener.open(
        sealed, password: "пароль", cipher: TestCipher(), supportedSchemaVersion: supported)
    }
  }

  @Test func aTruncatedEncryptedFileSaysSoInsteadOfBlamingThePassword() throws {
    let sealed = try sampleBuilder().build(
      password: "пароль", cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)
    for length in [EncryptionHeader.byteCount - 1, EncryptionHeader.byteCount + 15] {
      let cut = Data(sealed.prefix(length))
      #expect(throws: CoreError.invalidArchive(reason: .truncated)) {
        try ArchiveOpener.open(
          cut, password: "пароль", cipher: TestCipher(), supportedSchemaVersion: supported)
      }
    }
  }

  @Test func anEncryptedArchiveOpenedWithoutAPasswordAsksForOne() throws {
    let sealed = try sampleBuilder().build(
      password: "пароль", cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)
    #expect(throws: CoreError.invalidArchive(reason: .wrongPassword)) {
      try ArchiveOpener.open(sealed, supportedSchemaVersion: supported)
    }
  }

  @Test func saltAndNonceComeFromTheCallersRandomSource() throws {
    var first = SplitMix64(seed: 20_260_918)
    var second = SplitMix64(seed: 20_260_918)
    var third = SplitMix64(seed: 1)
    let saltA = EncryptionHeader.makeSalt(using: &first)
    let nonceA = EncryptionHeader.makeNonce(using: &first)
    #expect(saltA.count == 16)
    #expect(nonceA.count == 12)
    #expect(EncryptionHeader.makeSalt(using: &second) == saltA)
    #expect(EncryptionHeader.makeSalt(using: &third) != saltA)

    let builder = try sampleBuilder()
    var source = SplitMix64(seed: 7)
    let sealed = try builder.build(
      password: "пароль", cipher: TestCipher(), random: &source, iterations: iterations)
    let header = try EncryptionHeader.decode(sealed)
    #expect(header.iterations == iterations)
    #expect(header.salt.count == 16)
    #expect(header.nonce.count == 12)
    let archive = try ArchiveOpener.open(
      sealed, password: "пароль", cipher: TestCipher(), supportedSchemaVersion: supported)
    #expect(archive.manifest == builder.manifest())
  }

  @Test func aNewerSchemaIsStillRefusedInsideAnEncryptedArchive() throws {
    let sealed = try sampleBuilder(schemaVersion: 99).build(
      password: "пароль", cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)
    #expect(throws: CoreError.unsupportedSchemaVersion(found: 99, supported: supported)) {
      try ArchiveOpener.open(
        sealed, password: "пароль", cipher: TestCipher(), supportedSchemaVersion: supported)
    }
  }

  @Test func aHeaderCutShortAtAnyLengthIsReportedAsTruncated() throws {
    let encoded = try EncryptionHeader(salt: salt, nonce: nonce).encoded()
    for length in 8..<EncryptionHeader.byteCount {
      #expect(throws: CoreError.invalidArchive(reason: .truncated)) {
        try EncryptionHeader.decode(Data(encoded.prefix(length)))
      }
    }
    // Below the magic there is nothing to recognise at all.
    for length in 0..<8 {
      #expect(throws: CoreError.invalidArchive(reason: .notAZipContainer)) {
        try EncryptionHeader.decode(Data(encoded.prefix(length)))
      }
    }
  }

  @Test func aForeignMagicIsNotThisFormat() throws {
    var encoded = try EncryptionHeader(salt: salt, nonce: nonce).encoded()
    encoded[encoded.startIndex + 7] = UInt8(ascii: "2")  // "OHMYARC2"
    #expect(!EncryptionHeader.looksEncrypted(encoded))
    #expect(throws: CoreError.invalidArchive(reason: .notAZipContainer)) {
      try EncryptionHeader.decode(encoded)
    }
  }

  @Test func aHeaderVersionThisBuildDoesNotKnowIsRefused() throws {
    var encoded = try EncryptionHeader(salt: salt, nonce: nonce).encoded()
    encoded[encoded.startIndex + 8] = 2  // header version 2
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try EncryptionHeader.decode(encoded)
    }
  }

  @Test func theReservedFieldHasToBeZero() throws {
    var encoded = try EncryptionHeader(salt: salt, nonce: nonce).encoded()
    encoded[encoded.startIndex + 14] = 1
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try EncryptionHeader.decode(encoded)
    }
  }

  /// The archive format lets a reader accept any count from 1 to 50 000 000.
  @Test func theIterationCountIsAcceptedOnlyInsideTheDocumentedRange() throws {
    #expect(EncryptionHeader.iterationBounds == 1...50_000_000)
    for count in [1, 600_000, 50_000_000] {
      let header = try EncryptionHeader(iterations: count, salt: salt, nonce: nonce)
      #expect(try EncryptionHeader.decode(header.encoded()).iterations == count)
    }
    for count in [0, 50_000_001, Int(UInt32.max)] {
      var encoded = try EncryptionHeader(salt: salt, nonce: nonce).encoded()
      let value = UInt32(count)
      for offset in 0..<4 {
        encoded[encoded.startIndex + 16 + offset] = UInt8(truncatingIfNeeded: value >> (8 * offset))
      }
      #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
        try EncryptionHeader.decode(encoded)
      }
    }
  }

  @Test func theHeaderSitsAtTheDocumentedOffsets() throws {
    let header = try EncryptionHeader(iterations: 600_000, salt: salt, nonce: nonce)
    let bytes = [UInt8](header.encoded())
    #expect([UInt8](bytes[0..<8]) == [UInt8]("OHMYARC1".utf8))
    #expect(bytes[8] == 1 && bytes[9] == 0)  // header version, little-endian
    #expect(bytes[10] == 1 && bytes[11] == 0)  // PBKDF2-HMAC-SHA256
    #expect(bytes[12] == 1 && bytes[13] == 0)  // AES-256-GCM
    #expect(bytes[14] == 0 && bytes[15] == 0)  // reserved
    #expect([UInt8](bytes[16..<20]) == [0xC0, 0x27, 0x09, 0x00])  // 600000, little-endian
    #expect([UInt8](bytes[20..<36]) == salt)
    #expect([UInt8](bytes[36..<48]) == nonce)
  }

  @Test func anEmptyPasswordStillSealsAndOpens() throws {
    let builder = try sampleBuilder()
    let sealed = try builder.build(
      password: "", cipher: TestCipher(), salt: salt, nonce: nonce, iterations: iterations)
    let archive = try ArchiveOpener.open(
      sealed, password: "", cipher: TestCipher(), supportedSchemaVersion: supported)
    #expect(archive.manifest == builder.manifest())
    #expect(throws: CoreError.invalidArchive(reason: .wrongPassword)) {
      try ArchiveOpener.open(
        sealed, password: " ", cipher: TestCipher(), supportedSchemaVersion: supported)
    }
  }

  @Test func passwordsWithNullBytesAndEmojiAreTakenAsUTF8() throws {
    let password = "па\u{0000}роль🙂"
    let builder = try sampleBuilder()
    let sealed = try builder.build(
      password: password, cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)
    let archive = try ArchiveOpener.open(
      sealed, password: password, cipher: TestCipher(), supportedSchemaVersion: supported)
    #expect(archive.manifest == builder.manifest())
    // The null byte is part of the password, not a terminator.
    #expect(throws: CoreError.invalidArchive(reason: .wrongPassword)) {
      try ArchiveOpener.open(
        sealed, password: "па", cipher: TestCipher(), supportedSchemaVersion: supported)
    }
  }

  @Test func theSealedFileIsExactlyHeaderCiphertextAndTag() throws {
    let builder = try sampleBuilder()
    let plain = try builder.build()
    let sealed = try builder.build(
      password: "пароль", cipher: TestCipher(), salt: salt, nonce: nonce,
      iterations: iterations)
    #expect(
      sealed.count == EncryptionHeader.byteCount + plain.count + EncryptionHeader.tagByteCount)
    let header = try EncryptionHeader(iterations: iterations, salt: salt, nonce: nonce)
    #expect(Data(sealed.prefix(EncryptionHeader.byteCount)) == header.encoded())
    // Nothing of the container leaks through the envelope.
    #expect(!sealed.dropFirst(EncryptionHeader.byteCount).starts(with: [0x50, 0x4B, 0x03, 0x04]))
  }
}
