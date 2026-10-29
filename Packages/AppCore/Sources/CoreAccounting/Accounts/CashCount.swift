import CoreKit
import Foundation

/// One banknote or coin a wallet can hold.
public struct CashDenomination: Hashable, Sendable {
  public enum Form: String, Hashable, Sendable { case note, coin }

  /// The face value in whole units of the currency.
  public let value: Int64
  public let form: Form

  public init(_ value: Int64, _ form: Form) {
    self.value = value
    self.form = form
  }

  /// A stable name, telling a ten-ruble note from a ten-ruble coin: «note10», «coin10».
  public var id: String { "\(form.rawValue)\(value)" }
}

/// The wallet counted by the bill: how many of each denomination, and what they add up to.
/// Only a way to type the balance of a cash account faster — what is counted is the sum, and the
/// number of bills is kept nowhere.
public struct CashCount: Equatable, Sendable {
  /// The most of one denomination a field takes: far more than any wallet, and small enough that
  /// the sum of every field stays inside `AmountE4.inputLimit`.
  public static let maxPerDenomination = 1_000_000

  /// The denominations of `currency`, largest first, notes before coins of the same value;
  /// `nil` for a currency without a table (the owner's own currencies).
  public static func denominations(for currency: CurrencyCode) -> [CashDenomination]? {
    switch currency {
    case .rub:
      return [5000, 2000, 1000, 500, 200, 100, 50, 10].map { CashDenomination($0, .note) }
        + [10, 5, 2, 1].map { CashDenomination($0, .coin) }
    case .usd:
      return [100, 50, 20, 10, 5, 2, 1].map { CashDenomination($0, .note) }
    case .eur:
      return [500, 200, 100, 50, 20, 10, 5].map { CashDenomination($0, .note) }
    default:
      return nil
    }
  }

  public let currency: CurrencyCode
  /// How many of each denomination; absent means none.
  public private(set) var counts: [CashDenomination: Int]

  public init(currency: CurrencyCode, counts: [CashDenomination: Int] = [:]) {
    self.currency = currency
    self.counts = [:]
    for (denomination, count) in counts { set(denomination, count) }
  }

  /// Sets the number of `denomination`, clamped to `0...maxPerDenomination`; a denomination the
  /// currency does not have is ignored.
  public mutating func set(_ denomination: CashDenomination, _ count: Int) {
    guard Self.denominations(for: currency)?.contains(denomination) == true else { return }
    let clamped = min(max(count, 0), Self.maxPerDenomination)
    if clamped == 0 { counts[denomination] = nil } else { counts[denomination] = clamped }
  }

  public func count(of denomination: CashDenomination) -> Int { counts[denomination] ?? 0 }

  public var isEmpty: Bool { counts.isEmpty }

  /// The sum of the wallet.
  public var total: AmountE4 {
    AmountE4(
      raw: counts.reduce(Int64(0)) { sum, entry in
        sum + entry.key.value * Int64(entry.value) * AmountE4.unitsPerWhole
      })
  }

  /// The filled denominations in table order, as «5000 × 2»; the words around the sum are the
  /// screen's.
  public var terms: [String] {
    (Self.denominations(for: currency) ?? []).compactMap { denomination in
      let count = self.count(of: denomination)
      return count == 0 ? nil : "\(denomination.value) × \(count)"
    }
  }
}
