import CoreKit
import Foundation

/// English half of the entry-line vocabulary.
extension Lexicon {
  static let englishKindPhrases: [Phrase<TransactionKind>] = [
    Phrase("money back", .reimbursement),
    Phrase("paid me back", .reimbursement),
    Phrase("reimbursement", .reimbursement),
    Phrase("reimbursed", .reimbursement),
    Phrase("refund", .refund),
    Phrase("refunded", .refund),
    Phrase("income", .income),
    Phrase("salary", .income),
    Phrase("paycheck", .income),
  ]

  /// Offsets in days from "today".
  static let englishDatePhrases: [Phrase<Int>] = [
    Phrase("day before yesterday", -2),
    Phrase("today", 0),
    Phrase("yesterday", -1),
  ]

  static let englishForWhomWords: [String: ForWhom] = [
    "me": .me,
    "myself": .me,
    "self": .me,
    "partner": .partner,
    "girlfriend": .partner,
    "boyfriend": .partner,
    "wife": .partner,
    "husband": .partner,
    "spouse": .partner,
    "friend": .friends,
    "friends": .friends,
    "family": .family,
    "parents": .family,
    "mom": .family,
    "dad": .family,
    "kids": .family,
  ]

  static let englishCurrencyWords: [String: String] = [
    "rub": "RUB", "ruble": "RUB", "rubles": "RUB", "rouble": "RUB", "roubles": "RUB",
    "usd": "USD", "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD",
    "eur": "EUR", "euro": "EUR", "euros": "EUR",
    "kzt": "KZT", "tenge": "KZT",
    "cny": "CNY", "yuan": "CNY", "yuans": "CNY", "rmb": "CNY",
    "try": "TRY", "lira": "TRY", "liras": "TRY",
    "aed": "AED", "dirham": "AED", "dirhams": "AED",
    "gel": "GEL", "lari": "GEL",
    "amd": "AMD", "dram": "AMD", "drams": "AMD",
    "thb": "THB", "baht": "THB", "bahts": "THB",
  ]

  /// Codes that are everyday English words too — "try", "gel", and the processor brand
  /// "amd". Standing alone they are a currency only in capitals right after the amount
  /// ("250 TRY"); glued to it ("250try") they always are.
  static let englishWordlikeCurrencyCodes: Set<String> = ["try", "gel", "amd"]

  /// Currency names that are everyday English words as well — to rub, a dram of whisky, a
  /// buck: a currency only right after a number ("250 rub") or glued to it, and "RUB" — the
  /// code in capitals — anywhere.
  static let englishWordlikeCurrencyNames: Set<String> = ["rub", "dram", "drams", "buck"]

  /// Possessives and articles that stand between a marker and the word it introduces:
  /// "for my wife", "at the Ritz".
  static let englishDeterminers: Set<String> = [
    "my", "our", "your", "his", "her", "their", "the", "a", "an", "this", "that", "these",
    "those",
  ]

  /// When, not where: "at noon", "in January", "in the morning" is not a place.
  static let englishTimeWords: Set<String> = [
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "weekend",
    "january", "february", "march", "april", "may", "june", "july", "august", "september",
    "october", "november", "december",
    "morning", "afternoon", "evening", "night", "noon", "midnight", "breakfast", "lunch",
    "dinner",
  ]

  /// Words that make the number in front of them a count or a day, not money: "2 pcs",
  /// "3 lbs", "2 nights", "8 March".
  static let englishWordsAfterACount: Set<String> = [
    "pcs", "pc", "piece", "pieces", "pack", "packs", "bottles", "kg", "g", "lb", "lbs", "oz",
    "l", "ml", "liter", "liters", "litre", "litres",
    "hour", "hours", "min", "mins", "minutes", "days", "nights", "weeks", "months",
    "january", "february", "march", "april", "may", "june", "july", "august", "september",
    "october", "november", "december",
  ]

  /// A month written before the day: "March 8".
  static let englishMonthsBeforeADay: Set<String> = [
    "january", "february", "march", "april", "may", "june", "july", "august", "september",
    "october", "november", "december",
  ]

  static let englishPersonMarkers: Set<String> = ["for"]
  /// Whom money back came from: "money back 1700 from Anya". Only money back reads it.
  static let englishFromMarkers: Set<String> = ["from"]
  /// «от» / "from": the person money back came from, in both languages.
  static let fromMarkers: Set<String> = englishFromMarkers.union(russianFromMarkers)
  static let englishPlaceMarkers: Set<String> = ["at", "in"]
  /// The cashback the bank gave for the purchase: "cashback 9.76", "cash back 3%".
  static let englishCashbackWords: Set<String> = ["cashback", "cash-back"]
  static let englishCashbackPhrases: [[String]] = [["cash", "back"]]
  /// "cashback 5 percent".
  static let englishPercentWords: Set<String> = ["%", "percent", "pct"]
  /// "at 6:09pm": the word in front of a time goes with it.
  static let englishTimeMarkers: Set<String> = ["at"]
  static let englishHalfWords: Set<String> = ["split", "halves"]
  static let englishWithWords: Set<String> = ["with"]
  static let englishGiftWords: Set<String> = ["treated"]
  static let englishTransferWords: Set<String> = ["transfer", "transferred", "moved"]
  static let englishTransferFromMarkers: Set<String> = ["from"]
  static let englishTransferToMarkers: Set<String> = ["to", "into"]
  static let englishGoalMarkers: Set<String> = ["goal", "goals"]
  /// "coffee 250 from account": the money leaves the account itself, not its card.
  static let englishWithoutCardPhrases: [[String]] = [
    ["from", "account"], ["from", "the", "account"], ["by", "account"],
  ]
  static let englishDebtMarkers: Set<String> = ["loan", "loans", "credit", "debt", "mortgage"]
}
