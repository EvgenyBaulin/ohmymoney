import Foundation

/// What the model sees of an operation.
///
/// Everything here is part of the model file: change how a word is cut and every count in
/// every saved model means something else. So it is frozen, `featureVersion` says which
/// freezing this is, and a file made under another one is refused rather than misread.
public enum CategoryFeatures {
  /// Bumped whenever anything in this file changes what it produces.
  public static let version = 1

  /// A note is a line, not a document. These bound what one operation can cost.
  public static let wordLimit = 40
  public static let gramLimit = 120

  /// One shape for text before anything is counted:
  ///
  /// * composed form, so «ё» typed two ways is one letter;
  /// * lower case — Swift's is not locale-dependent, so the Turkish `I` is no trap here;
  /// * `ё` folded to `е`, as the rest of the app folds it;
  /// * anything that is not a letter or an ASCII digit becomes a space, so punctuation,
  ///   currency signs and emoji cannot make two spellings of one word;
  /// * every run of digits becomes `#`, so «заказ 12345» and «заказ 67» are the same order.
  public static func normalize(_ text: String) -> String {
    var folded = ""
    folded.reserveCapacity(text.count)
    var inNumber = false
    for character in text.precomposedStringWithCanonicalMapping.lowercased() {
      if character.isNumber, character.isASCII {
        if !inNumber {
          folded.append("#")
          inNumber = true
        }
        continue
      }
      inNumber = false
      if character == "ё" {
        folded.append("е")
      } else if character.isLetter {
        folded.append(character)
      } else {
        folded.append(" ")
      }
    }
    return folded.split(separator: " ").joined(separator: " ")
  }

  /// The words of a note, each counted once however often it is repeated: a word said three
  /// times is not three times the evidence.
  public static func words(in text: String) -> [String] {
    var seen = Set<String>()
    var words: [String] = []
    for word in normalize(text).split(separator: " ") {
      let word = String(word)
      guard !seen.contains(word) else { continue }
      seen.insert(word)
      words.append(word)
      if words.count == wordLimit { break }
    }
    return words
  }

  /// Three-letter grams inside each word, with the edges of the word marked. Inside a word
  /// and not across the whole line, so word order means nothing and an ending cannot hide a
  /// word from itself — «кофе» and «кофею» still share three grams of four.
  public static func grams(in text: String) -> [String] {
    var seen = Set<String>()
    var grams: [String] = []
    for word in normalize(text).split(separator: " ") {
      let padded = Array("_\(word)_")
      guard padded.count >= 3 else { continue }
      for start in 0...(padded.count - 3) {
        let gram = String(padded[start..<(start + 3)])
        guard !seen.contains(gram) else { continue }
        seen.insert(gram)
        grams.append(gram)
        if grams.count == gramLimit { return grams }
      }
    }
    return grams
  }

  /// Thresholds in whole rubles, about three to a decade. A bucket is found by comparing, not
  /// by taking a logarithm: the same amount gives the same bucket on every platform, for ever.
  static let amountThresholds: [Int64] = [
    50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000,
  ]

  public static func amountBucket(whole: Int64) -> Int {
    var bucket = 0
    for threshold in amountThresholds where whole >= threshold { bucket += 1 }
    return bucket
  }

  /// Every key of one example, sorted and without repeats. Sorted because the order the model
  /// walks its features in must never depend on how a dictionary happened to hash.
  public static func keys(
    text: String, place: UUID?, paymentMethod: UUID?, forWhom: String, person: UUID?,
    weekday: Int, amountWhole: Int64
  ) -> [String] {
    var keys: Set<String> = []
    for word in words(in: text) { keys.insert("w:\(word)") }
    for gram in grams(in: text) { keys.insert("c:\(gram)") }
    keys.insert("p:\(place?.uuidString ?? "none")")
    keys.insert("m:\(paymentMethod?.uuidString ?? "none")")
    keys.insert("f:\(forWhom)")
    if let person { keys.insert("fp:\(person.uuidString)") }
    keys.insert("d:\(weekday)")
    keys.insert("a:\(amountBucket(whole: amountWhole))")
    return keys.sorted()
  }
}
