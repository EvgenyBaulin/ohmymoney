import CoreAnalytics
import CoreKit
import Foundation

/// A note, not a calculation: ordinary cashback is not taxed, but a large cashback of a year or a
/// prize or a gift from a bank over 4 000 rubles a year may be. The app never works the tax out.
public struct CashbackTaxNote: Hashable, Sendable {
  public var year: Int
  /// The cashback written on the year's operations, in rubles.
  public var totalRub: AmountE4

  public init(year: Int, totalRub: AmountE4) {
    self.year = year
    self.totalRub = totalRub
  }
}

public enum CashbackTax {
  /// Prizes and gifts past this sum in a year are taxed by law.
  public static let giftFreeYearlyE4 = AmountE4(whole: 4_000)
  /// From this much cashback in a year the note shows. The law has no such figure; it is only
  /// where «large» starts for the hint.
  public static let largeYearlyE4 = AmountE4(whole: 100_000)

  /// The cashback the owner wrote on this year's operations, in rubles at today's rates; an
  /// operation in a currency without a rate is left out.
  public static func note(
    ledger: Ledger, today: DateOnly, rubPerUnit: [CurrencyCode: Decimal]
  ) -> CashbackTaxNote? {
    var total = AmountE4.zero
    for entry in ledger.dataset.entries where !entry.transaction.isDeleted {
      let transaction = entry.transaction
      guard let cashback = transaction.cashback, cashback.amount.raw > 0,
        ledger.calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId).year
          == today.year,
        let rubles = DebtRubles.convert(
          cashback.amount, from: cashback.currency, rubPerUnit: rubPerUnit)
      else { continue }
      total += rubles
    }
    guard total >= largeYearlyE4 else { return nil }
    return CashbackTaxNote(year: today.year, totalRub: total)
  }
}
