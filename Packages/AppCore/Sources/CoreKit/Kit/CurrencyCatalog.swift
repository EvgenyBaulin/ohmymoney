import Foundation

/// Why a custom currency cannot be written as it is.
public enum CustomCurrencyRefusal: Hashable, Sendable {
  /// Not three capital Latin letters.
  case notThreeCapitalLetters
  /// A code of ISO 4217.
  case isoCode
  /// A custom currency of that code is there already.
  case alreadyThere
  /// The name is empty.
  case emptyName
  /// The digits after the point are not 0…4.
  case fractionDigits
  /// The symbol is one a currency of the Bank of Russia is known by — «$», «€», «₽» — or the
  /// code of one: an amount written with it would read as that currency.
  case symbolOfBankCurrency
  /// Another custom currency goes by that symbol, or by it as a code.
  case symbolTaken
  /// The symbol has a digit or a space: next to a number it would read as part of the amount.
  case symbolNotASign
}

/// The currencies outside the Bank of Russia list next to the ones it knows: their names,
/// symbols and digits.
///
/// A custom currency is three capital Latin letters that are not an ISO 4217 code; its name and
/// symbol are the owner's. For every other currency the catalog has nothing of its own to say —
/// no symbol, no name — and its digits are two: the interface names those currencies itself.
public struct CurrencyCatalog: Hashable, Sendable {
  /// Archived ones included, in the owner's order.
  public var custom: [CustomCurrency]

  public init(custom: [CustomCurrency] = []) {
    self.custom = custom
  }

  public static let empty = CurrencyCatalog()

  /// The custom currency of that code, archived or not.
  public func currency(_ code: CurrencyCode) -> CustomCurrency? {
    custom.first { $0.code == code }
  }

  public func isCustom(_ code: CurrencyCode) -> Bool { currency(code) != nil }

  /// The custom currencies a new amount may be in: the archived ones are only read.
  public var active: [CustomCurrency] { custom.filter { !$0.archived } }

  /// Digits after the point an amount in the currency is written with; two for every currency
  /// the bank knows.
  public func fractionDigits(_ code: CurrencyCode) -> Int {
    currency(code)?.fractionDigits ?? 2
  }

  /// The owner's symbol of a custom currency; `nil` for one without a symbol and for every
  /// other currency.
  public func symbol(_ code: CurrencyCode) -> String? {
    currency(code).flatMap { Self.cleaned($0.symbol) }
  }

  /// The owner's name of a custom currency, whatever the language: it is written once, in the
  /// owner's words. `nil` for every other currency.
  public func name(_ code: CurrencyCode, language: String) -> String? {
    guard let name = currency(code)?.name.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    else { return nil }
    return name
  }

  /// The custom currency a symbol stands for, among the ones not archived: «★» for a currency
  /// written «100 ★». Letters are compared without case.
  public func code(forSymbol symbol: String) -> CurrencyCode? {
    guard let wanted = Self.cleaned(symbol)?.lowercased() else { return nil }
    return active.first { Self.cleaned($0.symbol)?.lowercased() == wanted }?.code
  }

  /// The currencies a list of choices offers: the enabled ones of the bank in their order, then
  /// the custom ones not archived, in the owner's order. A custom one already among the enabled
  /// stays where it is; nothing comes twice. There is no limit to how many.
  public func choices(enabled: [CurrencyCode]) -> [CurrencyCode] {
    var seen = Set<CurrencyCode>()
    var all: [CurrencyCode] = []
    for code in enabled + active.map(\.code) where seen.insert(code).inserted {
      all.append(code)
    }
    return all
  }

  /// Why `newCode` cannot be a custom currency next to `existing`; `nil` — it can. The code is
  /// read as typed: «usd» is not three capital letters.
  public static func refusal(
    newCode: String, existing: [CustomCurrency]
  ) -> CustomCurrencyRefusal? {
    let code = newCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard code.count == 3, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
      return .notThreeCapitalLetters
    }
    if ISOCurrencies.codes.contains(code) { return .isoCode }
    if existing.contains(where: { $0.code.code == code }) { return .alreadyThere }
    return nil
  }

  /// Why `currency` cannot be written next to `existing` — the custom currencies there now —;
  /// `nil` — it can. A currency of `existing` with the same code is the one being edited: its
  /// code is not taken, and its own symbol is not a clash.
  public static func refusal(
    for currency: CustomCurrency, existing: [CustomCurrency]
  ) -> CustomCurrencyRefusal? {
    let others = existing.filter { $0.code != currency.code }
    if let refusal = refusal(newCode: currency.code.code, existing: others) { return refusal }
    if currency.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
    guard CustomCurrency.fractionDigitsRange.contains(currency.fractionDigits) else {
      return .fractionDigits
    }
    return symbolRefusal(currency.symbol, code: currency.code, existing: others)
  }

  /// Why `symbol` cannot be the symbol of the custom currency `code` next to `existing`; `nil` —
  /// it can, and so can no symbol at all.
  public static func symbolRefusal(
    _ symbol: String?, code: CurrencyCode, existing: [CustomCurrency]
  ) -> CustomCurrencyRefusal? {
    guard let symbol = cleaned(symbol) else { return nil }
    if symbol.unicodeScalars.contains(where: {
      CharacterSet.decimalDigits.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
    }) {
      return .symbolNotASign
    }
    let folded = symbol.lowercased()
    if bankSymbols.contains(where: { $0.lowercased() == folded })
      || ISOCurrencies.codes.contains(symbol.uppercased())
    {
      return .symbolOfBankCurrency
    }
    for other in existing where other.code != code {
      if cleaned(other.symbol)?.lowercased() == folded || other.code.code.lowercased() == folded {
        return .symbolTaken
      }
    }
    return nil
  }

  /// Signs a currency of the Bank of Russia is known by — the ones the interface writes and the
  /// entry line reads, and the other signs everyone reads as one currency —, and the words for
  /// the ruble a receipt writes. A custom currency never takes one. Rarer signs of currencies
  /// the bank also publishes stay free: «₮» is the sign the owner knows Tether by.
  public static let bankSymbols: Set<String> = [
    "₽", "руб", "руб.", "р.", "$", "€", "£", "¥", "₸", "₺", "₾", "֏", "฿", "₹", "₩", "₴", "₼",
    "₫", "zł", "Kč", "лв",
  ]

  /// The symbol trimmed; `nil` when nothing is left.
  private static func cleaned(_ symbol: String?) -> String? {
    guard let trimmed = symbol?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}
