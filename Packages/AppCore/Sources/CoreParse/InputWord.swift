import CoreKit
import Foundation

/// One word of the entry line, remembered together with the offset it starts at so tokens
/// can be highlighted later.
struct InputWord {
  /// Exactly as typed — this is what ends up in the note.
  let original: String
  /// Lower case, "ё" folded into "е", punctuation trimmed off both ends. Used for every
  /// dictionary and keyword comparison.
  let normalized: String
  /// The part that may still be read as a number. The currency pass shortens it when the
  /// currency is glued to the amount ("250р" → "250").
  var amountText: String
  /// Offset of the first character in the line, in characters.
  let start: Int
  var claimed = false
  /// A currency glued to the number but switched off in the settings ("250usd" with the
  /// dollar off). The number is still read; this text stays in the note, as the word "usd"
  /// would in "250 usd".
  var ignoredCurrency: String?

  init(original: String, start: Int) {
    self.original = original
    self.normalized = TextNormalizer.normalized(original)
    self.amountText = TextNormalizer.amountText(original)
    self.start = start
  }

  /// Spaces people paste as a thousand separator: `1 250,50` must stay one amount.
  private static let hardSpaces: Set<Character> = ["\u{00A0}", "\u{202F}", "\u{2009}"]
  /// Characters that take no room and say nothing, brought in by pasted text: a zero-width
  /// space, a word joiner, a byte order mark, a soft hyphen. «1250» with a zero-width space
  /// inside is 1250, «Пятёрочка» with a soft hyphen is the place.
  private static let invisible: Set<Character> = ["\u{200B}", "\u{2060}", "\u{FEFF}", "\u{00AD}"]

  /// Splits a line into words. A non-breaking or thin space breaks a word everywhere but
  /// between two digits, where it groups thousands: «вчера» with a non-breaking space pasted
  /// behind it is still «вчера».
  static func split(_ text: String) -> [InputWord] {
    var words: [InputWord] = []
    var buffer = ""
    var bufferStart = 0
    let characters = Array(text)
    for (offset, character) in characters.enumerated() {
      if invisible.contains(character) { continue }
      let breaks =
        hardSpaces.contains(character)
        ? !(buffer.last.map(ExpressionLexer.isDigit) ?? false)
          || !(nextVisible(after: offset, in: characters).map(ExpressionLexer.isDigit) ?? false)
        : character.isWhitespace
      if breaks {
        if !buffer.isEmpty {
          words.append(InputWord(original: buffer, start: bufferStart))
          buffer = ""
        }
        continue
      }
      if buffer.isEmpty { bufferStart = offset }
      buffer.append(character)
    }
    if !buffer.isEmpty {
      words.append(InputWord(original: buffer, start: bufferStart))
    }
    return words
  }

  private static func nextVisible(after offset: Int, in characters: [Character]) -> Character? {
    characters[(offset + 1)...].first { !invisible.contains($0) }
  }
}

/// Text folding shared by the parser and the dictionaries.
enum TextNormalizer {
  private static let edgePunctuation: Set<Character> = [
    ".", ",", ";", ":", "!", "?", "\"", "'", "\u{00AB}", "\u{00BB}", "(", ")", "[", "]",
    "\u{2026}", "\u{2014}", "-",
  ]
  /// Every quote that may stand on either side of a number, whichever way round a language
  /// writes it: «250», »250«, "250", “250” (the quotes a Mac puts in by itself), „250“, ‚250‘,
  /// ‹250›. None of them is ever part of a number.
  private static let quotes: Set<Character> = [
    "\"", "'", "\u{00AB}", "\u{00BB}", "\u{201C}", "\u{201D}", "\u{201E}", "\u{2018}",
    "\u{2019}", "\u{201A}", "\u{2039}", "\u{203A}",
  ]
  /// What may close a number without being part of it: the punctuation of a sentence, and
  /// every quote.
  private static let amountTrailing: Set<Character> = quotes.union([
    ".", ",", ";", ":", "!", "?", "\u{2026}",
  ])
  private static let amountLeading: Set<Character> = quotes
  /// Endings a Russian word may change when it is declined. Only the last one is dropped.
  private static let softEndings: Set<Character> = [
    "а", "е", "и", "о", "у", "ы", "э", "ю", "я", "ь", "й",
  ]

  static func normalized(_ text: String) -> String {
    var folded = ""
    folded.reserveCapacity(text.count)
    for character in text.lowercased() {
      folded.append(character == "ё" ? "е" : character)
    }
    return trimming(folded, leading: edgePunctuation, trailing: edgePunctuation)
  }

  static func amountText(_ text: String) -> String {
    trimming(text, leading: amountLeading, trailing: amountTrailing)
  }

  static func trimmingEdgePunctuation(_ text: String) -> String {
    trimming(text, leading: edgePunctuation, trailing: edgePunctuation)
  }

  /// "Ани" and "Аня", "Пятёрочке" and "Пятёрочка": one changed ending is still the same
  /// name. Used only right after a marker word ("для", "в"), never for a blind scan.
  ///
  /// The one two-letter ending read is «-ой» of a feminine surname behind «для»: «Петровой»
  /// is «Петрова», as «Анны» is «Анна».
  static func looselyEqual(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    guard lhs.count >= 3, rhs.count >= 3 else { return false }
    let right = stems(rhs)
    return stems(lhs).contains { right.contains($0) }
  }

  /// A person's name in any case after «с», «за» and the like: «Машей», «Петей», «Андреем» —
  /// the instrumental endings `looselyEqual` does not read — as well as «Машу», «Маше».
  static func samePerson(_ lhs: String, _ rhs: String) -> Bool {
    if looselyEqual(lhs, rhs) { return true }
    guard lhs.count >= 4, rhs.count >= 3 else { return false }
    let right = stems(rhs)
    for ending in ["ей", "ем", "ём", "ом"] where lhs.hasSuffix(ending) {
      if right.contains(String(lhs.dropLast(2))) { return true }
    }
    return false
  }

  private static func stems(_ text: String) -> [String] {
    var stems: [String] = []
    if let last = text.last, softEndings.contains(last) {
      stems.append(String(text.dropLast()))
    } else {
      stems.append(text)
    }
    if text.hasSuffix("ой") { stems.append(String(text.dropLast(2))) }
    return stems.filter { $0.count >= 2 }
  }

  private static func trimming(
    _ text: String, leading: Set<Character>, trailing: Set<Character>
  ) -> String {
    var characters = Array(text)
    while let first = characters.first, leading.contains(first) {
      characters.removeFirst()
    }
    while let last = characters.last, trailing.contains(last) {
      characters.removeLast()
    }
    return String(characters)
  }
}
