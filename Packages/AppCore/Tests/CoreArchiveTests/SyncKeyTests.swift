import Foundation
import Testing

@testable import CoreArchive

// Synthetic data only; the vectors are the published ones.

private func bytes(_ hex: String) -> [UInt8] {
  var out: [UInt8] = []
  var index = hex.startIndex
  while index < hex.endIndex {
    let next = hex.index(index, offsetBy: 2)
    out.append(UInt8(hex[index..<next], radix: 16)!)
    index = next
  }
  return out
}

/// The seeded generator of this target as a `RandomNumberGenerator`.
private struct Seeded: RandomNumberGenerator {
  var inner: SplitMix64
  init(seed: UInt64) { inner = SplitMix64(seed: seed) }
  mutating func next() -> UInt64 { inner.nextUInt64() }
}

private func hex(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}

/// HKDF-SHA256 against RFC 5869, appendix A (test cases 1 and 3).
@Suite("HKDF-SHA256")
struct HKDFTests {
  @Test func rfc5869TestCase1() {
    let ikm = [UInt8](repeating: 0x0b, count: 22)
    let salt = bytes("000102030405060708090a0b0c")
    let info = bytes("f0f1f2f3f4f5f6f7f8f9")
    let prk = HKDF.extract(salt: salt, inputKeyMaterial: ikm)
    #expect(hex(prk) == "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
    let okm = HKDF.expand(pseudorandomKey: prk, info: info, length: 42)
    #expect(
      okm.map(hex)
        == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
    )
  }

  @Test func rfc5869TestCase3EmptySaltAndInfo() {
    let ikm = [UInt8](repeating: 0x0b, count: 22)
    let prk = HKDF.extract(salt: [], inputKeyMaterial: ikm)
    #expect(hex(prk) == "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04")
    let okm = HKDF.deriveKey(inputKeyMaterial: ikm, salt: [], info: [], length: 42)
    #expect(
      okm.map(hex)
        == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
    )
  }

  @Test func theLengthIsBounded() {
    let prk = [UInt8](repeating: 1, count: 32)
    #expect(HKDF.expand(pseudorandomKey: prk, info: [], length: 0) == [])
    #expect(HKDF.expand(pseudorandomKey: prk, info: [], length: 255 * 32)?.count == 255 * 32)
    #expect(HKDF.expand(pseudorandomKey: prk, info: [], length: 255 * 32 + 1) == nil)
    #expect(HKDF.expand(pseudorandomKey: prk, info: [], length: -1) == nil)
  }
}

/// The recovery code is BIP-39 with 256 bits: the published list and the published vectors.
@Suite("Recovery code")
struct RecoveryCodeTests {
  /// The 24-word vectors of the reference implementation (trezor/python-mnemonic, English).
  static let vectors: [(String, String)] = [
    (
      "0000000000000000000000000000000000000000000000000000000000000000",
      "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
    ),
    (
      "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
      "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
    ),
    (
      "8080808080808080808080808080808080808080808080808080808080808080",
      "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"
    ),
    (
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
    ),
    (
      "68a79eaca2324873eacc50cb9c6eca8cc68ea5d936f98787c60c7ebc74e6ce7c",
      "hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length"
    ),
    (
      "9f6a2878b2520799a44ef18bc7df394e7061a224d2c33cd015b157d746869863",
      "panda eyebrow bullet gorilla call smoke muffin taste mesh discover soft ostrich alcohol speed nation flash devote level hobby quick inner drive ghost inside"
    ),
    (
      "066dca1a2bb7e8a1db2832148ce9933eea0f3ac9548d793112d9a95c9407efad",
      "all hour make first leader extend hole alien behind guard gospel lava path output census museum junior mass reopen famous sing advance salt reform"
    ),
    (
      "f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f",
      "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold"
    ),
  ]

  @Test func theWordListIsThePublishedOne() {
    let words = RecoveryWordList.words
    #expect(words.count == 2048)
    #expect(words.first == "abandon")
    #expect(words.last == "zoo")
    // SHA-256 of bip-0039/english.txt (one word per line, a newline after each).
    let file = words.map { $0 + "\n" }.joined()
    #expect(
      SHA256.hexDigest(file)
        == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
    // Four letters name one word: what lets the owner type a word short.
    #expect(Set(words.map { $0.prefix(4) }).count == 2048)
  }

  @Test func thePublishedVectors() throws {
    for (entropy, phrase) in Self.vectors {
      #expect(RecoveryCode.words(for: bytes(entropy))?.joined(separator: " ") == phrase)
      #expect(try RecoveryCode.entropy(from: phrase).get() == bytes(entropy))
    }
  }

  @Test func typingIsForgiving() throws {
    let (entropy, phrase) = Self.vectors[4]
    let shouted = phrase.uppercased().replacingOccurrences(of: " ", with: ",\n  ")
    #expect(try RecoveryCode.entropy(from: shouted).get() == bytes(entropy))
    let short = phrase.split(separator: " ").map { String($0.prefix(4)) }.joined(separator: " ")
    #expect(try RecoveryCode.entropy(from: short).get() == bytes(entropy))
  }

  @Test func whatIsNotACode() {
    let words = Self.vectors[4].1.split(separator: " ").map(String.init)
    #expect(
      RecoveryCode.entropy(from: words.dropLast().joined(separator: " "))
        == .failure(.wrongCount(found: 23)))
    var unknown = words
    unknown[5] = "bitcoinz"
    #expect(
      RecoveryCode.entropy(from: unknown.joined(separator: " "))
        == .failure(.unknownWord(index: 5)))
    var shortWord = words
    shortWord[2] = "abc"
    #expect(
      RecoveryCode.entropy(from: shortWord.joined(separator: " "))
        == .failure(.unknownWord(index: 2)))
    var swapped = words
    swapped.swapAt(0, 1)
    #expect(RecoveryCode.entropy(from: swapped.joined(separator: " ")) == .failure(.checksum))
    #expect(RecoveryCode.words(for: [1, 2, 3]) == nil)
  }
}

/// The sync key: random, given back by its words, and never sealing anything itself.
@Suite("Sync key")
struct SyncKeyTests {
  @Test func aKeyComesBackFromItsWords() throws {
    var generator = Seeded(seed: 2026)
    for _ in 0..<50 {
      let key = SyncKey.generate(using: &generator)
      #expect(key.bytes.count == 32)
      #expect(key.recoveryWords.count == 24)
      let back = try SyncKey.recover(from: key.recoveryWords.joined(separator: " ")).get()
      #expect(back == key)
      #expect(back.fingerprint == key.fingerprint)
    }
  }

  @Test func theSameSeedGivesTheSameKeyAndTheSystemGivesNewOnes() {
    var a = Seeded(seed: 7)
    var b = Seeded(seed: 7)
    #expect(SyncKey.generate(using: &a) == SyncKey.generate(using: &b))
    #expect(SyncKey.generate() != SyncKey.generate())
  }

  @Test func eachUseHasItsOwnKey() throws {
    let key = try #require(SyncKey(bytes: bytes(RecoveryCodeTests.vectors[4].0)))
    let journal = key.key(for: .journal)
    let snapshot = key.key(for: .snapshot)
    #expect(journal.count == 32)
    #expect(snapshot.count == 32)
    #expect(journal != snapshot)
    #expect(journal != key.data)
    // Fixed by the format: the same key always seals with the same derived keys.
    let expected = HKDF.deriveKey(
      inputKeyMaterial: key.bytes, salt: Array("OhMyMoney sync key".utf8),
      info: Array("ohmymoney sync journal v1".utf8), length: 32)
    #expect(Array(journal) == expected)
    #expect(key.fingerprint.count == 8)
  }

  @Test func theDescriptionNamesNoByte() throws {
    let key = try #require(SyncKey(bytes: [UInt8](repeating: 0xab, count: 32)))
    #expect(!key.description.contains("ab, "))
    #expect(key.description.hasPrefix("SyncKey("))
    #expect(SyncKey(bytes: [1, 2]) == nil)
    #expect(SyncKey(data: Data(repeating: 0, count: 32)) != nil)
  }
}
