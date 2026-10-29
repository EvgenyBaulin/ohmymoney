import CoreKit
import Foundation

/// Words the entry line understands. English and Russian are merged into one table on
/// purpose: both languages are recognised at the same time, whatever the interface
/// language is.
///
/// The two halves live in `Lexicon+EN.swift` and `Lexicon+RU.swift`; this file only joins
/// them and holds the shapes.
enum Lexicon {
  /// A phrase is stored already normalised and split into words, longest phrases first,
  /// so "возврат денег" is tried before "возврат".
  struct Phrase<Meaning: Sendable>: Sendable {
    let words: [String]
    let meaning: Meaning

    init(_ text: String, _ meaning: Meaning) {
      self.words = text.split(separator: " ").map(String.init)
      self.meaning = meaning
    }
  }

  static let kindPhrases: [Phrase<TransactionKind>] =
    sorted(englishKindPhrases + russianKindPhrases)

  static let datePhrases: [Phrase<Int>] =
    sorted(englishDatePhrases + russianDatePhrases)

  static let forWhomWords: [String: ForWhom] =
    englishForWhomWords.merging(russianForWhomWords) { first, _ in first }

  /// Declined forms read only right after «для» / «for». English words do not decline.
  static let declinedForWhomWords: [String: ForWhom] = russianDeclinedForWhomWords

  static let currencyWords: [String: String] =
    englishCurrencyWords.merging(russianCurrencyWords) { first, _ in first }

  static let wordlikeCurrencyCodes: Set<String> = englishWordlikeCurrencyCodes
  static let wordlikeCurrencyNames: Set<String> =
    englishWordlikeCurrencyNames.union(russianWordlikeCurrencyNames)

  /// Symbols of the ten currencies enabled out of the box. The dirham has no single-rune
  /// symbol, so only its code and name are recognised.
  static let currencySymbols: [Character: String] = [
    "\u{20BD}": "RUB",  // ₽
    "$": "USD",
    "\u{20AC}": "EUR",  // €
    "\u{20B8}": "KZT",  // ₸
    "\u{00A5}": "CNY",  // ¥
    "\u{20BA}": "TRY",  // ₺
    "\u{20BE}": "GEL",  // ₾
    "\u{058F}": "AMD",  // ֏
    "\u{0E3F}": "THB",  // ฿
  ]

  /// Read as part of the marker in front of them, never as a name of their own.
  static let determiners: Set<String> = englishDeterminers.union(russianDeterminers)
  static let timeWords: Set<String> = englishTimeWords.union(russianTimeWords)
  /// A count or a day is not the amount while another number is there.
  static let wordsAfterACount: Set<String> =
    englishWordsAfterACount.union(russianWordsAfterACount)
  static let monthsBeforeADay: Set<String> = englishMonthsBeforeADay
  static let personMarkers: Set<String> = englishPersonMarkers.union(russianPersonMarkers)
  static let placeMarkers: Set<String> = englishPlaceMarkers.union(russianPlaceMarkers)
  static let halfWords: Set<String> = englishHalfWords.union(russianHalfWords)
  static let withWords: Set<String> = englishWithWords.union(russianWithWords)
  static let giftWords: Set<String> = englishGiftWords.union(russianGiftWords)
  static let paidForMarkers: Set<String> = russianPaidForMarkers
  static let transferWords: Set<String> = englishTransferWords.union(russianTransferWords)
  static let transferFromMarkers: Set<String> =
    englishTransferFromMarkers.union(russianTransferFromMarkers)
  static let transferToMarkers: Set<String> =
    englishTransferToMarkers.union(russianTransferToMarkers)
  static let cashbackWords: Set<String> = englishCashbackWords.union(russianCashbackWords)
  static let cashbackPhrases: [[String]] = englishCashbackPhrases
  static let percentWords: Set<String> = englishPercentWords.union(russianPercentWords)
  static let timeMarkers: Set<String> = englishTimeMarkers.union(russianTimeMarkers)
  /// Longest first, so «со своего счёта» is tried before «со счёта».
  static let withoutCardPhrases: [[String]] =
    (englishWithoutCardPhrases + russianWithoutCardPhrases).sorted { $0.count > $1.count }
  static let warrantyWords: Set<String> = englishWarrantyWords.union(russianWarrantyWords)
  static let returnWords: Set<String> = englishReturnWords.union(russianReturnWords)
  static let termPrepositions: Set<String> = englishTermPrepositions.union(russianTermPrepositions)
  static let termUnits: [String: TermReading.Unit] =
    englishTermUnits.merging(russianTermUnits) { first, _ in first }
  static let selfEmployedWords: Set<String> = russianSelfEmployedWords
  static let goalMarkers: Set<String> = englishGoalMarkers.union(russianGoalMarkers)
  static let debtMarkers: Set<String> = englishDebtMarkers.union(russianDebtMarkers)

  private static func sorted<Meaning: Sendable>(
    _ phrases: [Phrase<Meaning>]
  ) -> [Phrase<Meaning>] {
    phrases.sorted { $0.words.count > $1.words.count }
  }
}
