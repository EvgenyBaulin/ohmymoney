import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// How the words of the entry line hand a number to the amount: spaces that group thousands
/// keep a number whole, characters that take no room vanish, and the punctuation around a
/// number — quotes, a full stop, an ellipsis — is not part of it.
@Suite("The number inside a word of the entry line")
struct AmountWordTests {
  /// Quotes around an amount are writing, not the number: the opening quote was always left
  /// out, the closing one stayed and the word never read — «кофе «250»» had no amount, and no
  /// reason for it either.
  @Test(
    "Quotes and closing punctuation around a number are not part of it",
    arguments: [
      ("«250»", "250"), ("\"250\"", "250"), ("'250'", "250"), ("«2,5k»", "2,5k"),
      ("250…", "250"), ("250.", "250"), ("250,", "250"), ("250!", "250"), ("250?", "250"),
      ("250;", "250"), ("250:", "250"), ("«1 250,50»", "1 250,50"), ("(100+50).", "(100+50)"),
      ("250»,", "250"), ("\"250\".", "250"), ("\u{201C}250\u{201D}", "250"),
      ("\u{201E}250\u{201C}", "250"), ("\u{2018}250\u{2019}", "250"),
      // The single low quote with its closing one, single guillemets either way round, and
      // guillemets the German way round.
      ("\u{201A}250\u{2018}", "250"), ("\u{2039}250\u{203A}", "250"),
      ("\u{203A}250\u{2039}", "250"), ("\u{00BB}250\u{00AB}", "250"),
      ("\u{201D}250\u{201D}", "250"), ("\u{2019}250\u{2019}", "250"),
    ])
  func quotesAreNotPartOfTheNumber(word: String, number: String) {
    #expect(TextNormalizer.amountText(word) == number)
  }

  /// A bracket belongs to a formula, a sign to the number: neither is trimmed away.
  @Test(
    "Brackets and signs stay with the number",
    arguments: [("(250)", "(250)"), ("-250", "-250"), ("+250", "+250"), ("250-", "250-")])
  func bracketsAndSignsStay(word: String, number: String) {
    #expect(TextNormalizer.amountText(word) == number)
  }

  @Test("A quoted amount in the line is the amount")
  func aQuotedAmountIsTheAmount() {
    for line in [
      "кофе «250»", "кофе \"250\"", "кофе '250'", "кофе 250…", "кофе \u{201C}250\u{201D}",
      "кофе \u{201A}250\u{2018}", "кофе \u{2039}250\u{203A}", "кофе \u{00BB}250\u{00AB}",
    ] {
      let result = Fixture.parse(line)
      #expect(result.amount == dec("250"), "«\(line)»")
      #expect(result.note == "кофе", "«\(line)»")
    }
  }

  /// A no-break, narrow or thin space between digits groups thousands and keeps the number one
  /// word; anywhere else it breaks words like any space. Characters that take no room — a
  /// zero-width space, a word joiner, a byte order mark, a soft hyphen — are dropped.
  @Test("Spaces between digits keep a number whole; invisible characters vanish")
  func spacesAndInvisibleCharacters() {
    func words(_ text: String) -> [String] { InputWord.split(text).map(\.original) }
    #expect(words("кофе 1\u{00A0}250,50") == ["кофе", "1\u{00A0}250,50"])
    #expect(words("кофе 1\u{202F}250\u{2009}000") == ["кофе", "1\u{202F}250\u{2009}000"])
    #expect(words("вчера\u{00A0}кофе 250") == ["вчера", "кофе", "250"])
    #expect(words("кофе 250\u{00A0}") == ["кофе", "250"])
    #expect(words("кофе 12\u{200B}50") == ["кофе", "1250"])
    #expect(words("ко\u{00AD}фе 2\u{2060}5\u{FEFF}0") == ["кофе", "250"])
    #expect(words("  кофе   250  ") == ["кофе", "250"])
    #expect(words("") == [])
    // A plain space between digits splits the words; the amount joins them back when they
    // group thousands.
    #expect(words("1 250") == ["1", "250"])
    // Where each word starts, in characters of the line.
    #expect(InputWord.split("кофе  250").map(\.start) == [0, 6])
  }

  /// On random lines of letters, digits and every kind of space: no word is empty or holds a
  /// plain space; a no-break, narrow or thin space stays inside a word only between two digits;
  /// every word starts where the line has it, and the words come in the order of the line.
  @Test("Words of random lines keep their place and their spaces")
  func wordsOfRandomLines() {
    var state: UInt64 = 1_250
    func below(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    let alphabet: [Character] = [
      "1", "2", "5", "0", "к", "о", "ф", "е", "a", ",", ".", "+", " ", " ", "\u{00A0}",
      "\u{202F}", "\u{2009}", "\t",
    ]
    let hardSpaces: Set<Character> = ["\u{00A0}", "\u{202F}", "\u{2009}"]
    for _ in 0..<20_000 {
      let line = String((0..<(1 + below(16))).map { _ in alphabet[below(alphabet.count)] })
      let characters = Array(line)
      let words = InputWord.split(line)
      var previousEnd = 0
      for word in words {
        let letters = Array(word.original)
        #expect(!letters.isEmpty, "«\(line)»")
        #expect(!letters.contains { $0 == " " || $0 == "\t" }, "«\(line)»")
        for (index, letter) in letters.enumerated() where hardSpaces.contains(letter) {
          let between =
            index > 0 && index + 1 < letters.count && ExpressionLexer.isDigit(letters[index - 1])
            && ExpressionLexer.isDigit(letters[index + 1])
          #expect(between, "«\(line)»: «\(word.original)»")
        }
        #expect(word.start >= previousEnd, "«\(line)»")
        #expect(
          Array(characters[word.start..<(word.start + letters.count)]) == letters, "«\(line)»")
        previousEnd = word.start + letters.count
      }
    }
  }
}
