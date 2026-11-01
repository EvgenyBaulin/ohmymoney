import Foundation

/// The recovery code of the sync key: 24 words of BIP-39 (English), printed once on a sheet
/// beside a QR code that holds the same words. The 256 bits of the key are the entropy, the
/// first byte of their SHA-256 the checksum: 264 bits, 24 words of 11 bits each. The words are
/// the key itself — whoever holds the sheet holds the key —, so the code is never logged,
/// stored or sent anywhere by the app.
public enum RecoveryCode {
  public static let wordCount = 24
  public static let entropyByteCount = 32

  /// Why typed words are not a recovery code. `index` counts from 0.
  public enum Problem: Error, Hashable, Sendable {
    case wrongCount(found: Int)
    case unknownWord(index: Int)
    /// Every word is known but the last bits do not match: a word is wrong or two are swapped.
    case checksum
  }

  /// The 24 words of `entropy` (exactly 32 bytes; `nil` otherwise).
  public static func words(for entropy: [UInt8]) -> [String]? {
    guard entropy.count == entropyByteCount else { return nil }
    let checksum = SHA256.hash(entropy)[0]
    let bits = entropy + [checksum]
    let list = RecoveryWordList.words
    return (0..<wordCount).map { index in list[value(of: bits, at: index * 11)] }
  }

  /// The 32 bytes the words stand for. Spaces, line breaks, commas and case do not matter; a
  /// word may be typed by its first four letters, which in this list name exactly one word.
  public static func entropy(from text: String) -> Result<[UInt8], Problem> {
    let typed = text.lowercased()
      .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "-" })
      .map(String.init)
    guard typed.count == wordCount else { return .failure(.wrongCount(found: typed.count)) }
    var values: [Int] = []
    for (index, word) in typed.enumerated() {
      guard let value = Self.value(of: word) else { return .failure(.unknownWord(index: index)) }
      values.append(value)
    }
    var bits = [UInt8](repeating: 0, count: entropyByteCount + 1)
    for (index, value) in values.enumerated() {
      for bit in 0..<11 where value & (1 << (10 - bit)) != 0 {
        let position = index * 11 + bit
        bits[position / 8] |= UInt8(0x80 >> (position % 8))
      }
    }
    let entropy = Array(bits.prefix(entropyByteCount))
    guard SHA256.hash(entropy)[0] == bits[entropyByteCount] else { return .failure(.checksum) }
    return .success(entropy)
  }

  /// The place of a word in the list, by the whole word or by its first four letters.
  static func value(of word: String) -> Int? {
    if let exact = index[word] { return exact }
    guard word.count >= 4 else { return nil }
    return prefixIndex[String(word.prefix(4))]
  }

  private static let index: [String: Int] = Dictionary(
    uniqueKeysWithValues: RecoveryWordList.words.enumerated().map { ($0.element, $0.offset) })

  private static let prefixIndex: [String: Int] = Dictionary(
    RecoveryWordList.words.enumerated().map { (String($0.element.prefix(4)), $0.offset) },
    uniquingKeysWith: { first, _ in first })

  /// The 11 bits of `bytes` that start at bit `offset`, the most significant first.
  private static func value(of bytes: [UInt8], at offset: Int) -> Int {
    var value = 0
    for bit in offset..<(offset + 11) {
      let set = bytes[bit / 8] & UInt8(0x80 >> (bit % 8)) != 0
      value = value << 1 | (set ? 1 : 0)
    }
    return value
  }
}
