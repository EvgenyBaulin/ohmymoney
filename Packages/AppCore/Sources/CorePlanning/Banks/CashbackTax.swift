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

  /// The cashback of `today`'s year in rubles: what the rules of the cards promise or the owner
  /// typed for the purchases, or what was received as income, whichever is more
  /// (`CashbackReport`).
  public static func note(ledger: Ledger, today: DateOnly) -> CashbackTaxNote? {
    let report = CashbackReport(ledger: ledger, period: .year(today.year))
    let months = report.byMonth()
    let expected = AmountE4.sum(months.map(\.expectedRub))
    let received = AmountE4.sum(months.map(\.receivedRub))
    let total = max(expected, received)
    guard total >= largeYearlyE4 else { return nil }
    return CashbackTaxNote(year: today.year, totalRub: total)
  }
}
