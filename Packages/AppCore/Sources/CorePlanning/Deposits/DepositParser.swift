import CoreKit
import Foundation

/// The one switch for taking deposit rates from banki.ru (`deposits.parserEnabled` in the database
/// settings, so it travels in the archive). Off unless the owner switched it on: the built-in list
/// and the owner's own offers are the default.
public enum DepositParserSetting {
  public static let key = "deposits.parserEnabled"

  public static func isEnabled(from stored: String?) -> Bool { stored == "1" }
  public static func stored(_ enabled: Bool) -> String { enabled ? "1" : "0" }
}

/// Turns the body of a public page of deposits into showcase entries. A line that cannot be read
/// is skipped; a page with nothing readable gives an empty list, which callers treat as
/// «could not update», never as «no deposits exist».
public protocol DepositPageParsing: Sendable {
  func parse(_ data: Data, on day: DateOnly) -> [DepositShowcaseEntry]
}

/// banki.ru. Its deposit pages answer an automated request with a script challenge, not the page
/// (checked on 2026-10-29), so no real markup could be captured and nothing here guesses one: until
/// a captured page is added as a fixture and read, this parser gives an empty list and the
/// built-in list stays. `entry(...)` is the one place where a read line becomes an entry.
public struct BankiRuDepositParser: DepositPageParsing {
  public init() {}

  public func parse(_ data: Data, on day: DateOnly) -> [DepositShowcaseEntry] { [] }

  /// A read line as an entry; `nil` when the bank or the rate is missing or the rate is not a
  /// sane percent. Rates are `Decimal`, read from text without binary floating point.
  public static func entry(
    bank: String, product: String = "", rateText: String, termMinMonths: Int? = nil,
    termMaxMonths: Int? = nil, minAmountE4: AmountE4? = nil, topup: Bool? = nil, on day: DateOnly
  ) -> DepositShowcaseEntry? {
    let name = bank.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = rateText.replacingOccurrences(of: ",", with: ".")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      let rate = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
      rate > 0, rate < 100
    else { return nil }
    return DepositShowcaseEntry(
      id: "banki:\(DepositShowcase.bankKey(name)):\(product.lowercased())", origin: .bankiRu,
      bankName: name, product: product, ratePercent: rate, rateIsMaximum: true,
      termMinMonths: termMinMonths, termMaxMonths: termMaxMonths, minAmountE4: minAmountE4,
      topup: topup, rateOn: day)
  }
}

/// Once a day at most: the result of the last attempt with the day it was made, kept so a restart
/// does not ask again. A failed attempt is kept too (empty `entries`) so the page is not hammered.
public struct DepositFetchCache: Codable, Hashable, Sendable {
  public var day: DateOnly
  public var entries: [DepositShowcaseEntry]

  public init(day: DateOnly, entries: [DepositShowcaseEntry]) {
    self.day = day
    self.entries = entries
  }

  /// Whether a new request is due on `today`.
  public static func isDue(_ cache: DepositFetchCache?, today: DateOnly) -> Bool {
    guard let cache else { return true }
    return cache.day != today
  }
}
