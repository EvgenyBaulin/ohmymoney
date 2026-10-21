import Foundation
import Testing

@testable import CoreArchive

/// The RFC 6070 vectors, run through HMAC-SHA-256 instead of HMAC-SHA-1: the same
/// passwords, salts and iteration counts, with the digests that PBKDF2-HMAC-SHA256
/// produces for them. This is the set every implementation is checked against.
@Suite("PBKDF2-HMAC-SHA256 matches the RFC 6070 vectors")
struct PBKDF2Tests {
  private func derive(
    _ password: String, _ salt: String, _ iterations: Int, _ length: Int
  ) -> String {
    SHA256.hexString(
      PBKDF2.deriveKey(
        password: password, salt: [UInt8](salt.utf8), iterations: iterations,
        keyByteCount: length))
  }

  @Test func oneIteration() {
    #expect(
      derive("password", "salt", 1, 32)
        == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
  }

  @Test func twoIterations() {
    #expect(
      derive("password", "salt", 2, 32)
        == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
  }

  @Test func fourThousandNinetySixIterations() {
    #expect(
      derive("password", "salt", 4096, 32)
        == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
  }

  @Test func longPasswordAndSaltWithFortyByteKey() {
    // dkLen 40 needs two blocks of the pseudorandom function, which is the part of the
    // construction the shorter vectors never reach.
    #expect(
      derive("passwordPASSWORDpassword", "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, 40)
        == "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1"
        + "c635518c7dac47e9")
  }

  @Test func embeddedNullBytesAreSignificant() {
    let key = PBKDF2.deriveKey(
      password: [UInt8]("pass".utf8) + [0x00] + [UInt8]("word".utf8),
      salt: [UInt8]("sa".utf8) + [0x00] + [UInt8]("lt".utf8),
      iterations: 4096, keyByteCount: 16)
    #expect(SHA256.hexString(key) == "89b69d0516f829893c696226650a8687")
  }

  @Test func keyLengthIsHonouredBetweenBlockBoundaries() {
    let full = PBKDF2.deriveKey(
      password: "password", salt: [UInt8]("salt".utf8), iterations: 2, keyByteCount: 64)
    for length in [1, 31, 32, 33, 64] {
      let short = PBKDF2.deriveKey(
        password: "password", salt: [UInt8]("salt".utf8), iterations: 2,
        keyByteCount: length)
      #expect(short == [UInt8](full[0..<length]))
    }
  }

  @Test func differentSaltsGiveDifferentKeys() {
    let first = PBKDF2.deriveKey(
      password: "password", salt: repeated(0x01, 16), iterations: 100, keyByteCount: 32)
    let second = PBKDF2.deriveKey(
      password: "password", salt: repeated(0x02, 16), iterations: 100, keyByteCount: 32)
    #expect(first != second)
  }

  @Test func anAllZeroSaltAndAnEmptySaltAreDifferentInputs() {
    let zeroSalt = PBKDF2.deriveKey(
      password: "password", salt: repeated(0x00, 16), iterations: 10, keyByteCount: 32)
    let emptySalt = PBKDF2.deriveKey(
      password: "password", salt: [], iterations: 10, keyByteCount: 32)
    #expect(zeroSalt.count == 32)
    #expect(emptySalt.count == 32)
    #expect(zeroSalt != emptySalt)
  }

  @Test func aPasswordWithAnEmojiIsTakenAsItsUTF8Bytes() {
    let viaString = PBKDF2.deriveKey(
      password: "пароль🙂", salt: repeated(0x01, 16), iterations: 10, keyByteCount: 32)
    let viaBytes = PBKDF2.deriveKey(
      password: [UInt8]("пароль🙂".utf8), salt: repeated(0x01, 16), iterations: 10,
      keyByteCount: 32)
    #expect(viaString == viaBytes)
  }

  @Test func oneIterationIsJustThePseudorandomFunctionOverSaltAndCounter() {
    let salt = repeated(0x2A, 16)
    var seed = salt
    seed.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
    let expected = HMACSHA256.code(key: [UInt8]("password".utf8), message: seed)
    #expect(
      PBKDF2.deriveKey(password: "password", salt: salt, iterations: 1, keyByteCount: 32)
        == expected)
  }
}
