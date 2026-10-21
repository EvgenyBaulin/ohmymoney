import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// What the cashback sheet of an account holds besides the rules, read from the account and put
/// back on it.
@Suite("The cashback settings of an account, as the sheet holds them")
struct CashbackAccountSettingsTests {
  @Test func anAccountStartsWithTheDefaults() {
    let settings = CashbackAccountSettings(PaymentMethod(name: "Sber"))
    #expect(settings == CashbackAccountSettings())
    #expect(settings.rounding == .standard)
    #expect(settings.payout == nil && settings.pointsAccountId == nil)
  }

  @Test func theSettingsAreReadFromTheAccount() {
    let points = UUID()
    let account = PaymentMethod(
      name: "Black", cashbackRounding: CashbackRounding(precision: .cents, direction: .up),
      cashbackPayout: CashbackPayout.later(day: 10), cashbackPointsAccountId: points)
    let settings = CashbackAccountSettings(account)
    #expect(settings.rounding == account.cashbackRounding)
    #expect(settings.payout == CashbackPayout.later(day: 10))
    #expect(settings.pointsAccountId == points)
    #expect(!settings.differs(from: account))
  }

  /// Putting them on an account changes the three fields and nothing else.
  @Test func theyAreAppliedToAnAccountAndNothingElseChanges() {
    let account = PaymentMethod(
      name: "Black", kind: .account, currency: .usd, aliases: ["blk"], isDefault: true,
      sort: 3, otherCurrencies: [.rub], bankId: UUID())
    var settings = CashbackAccountSettings(account)
    settings.rounding.direction = .down
    settings.payout = .immediately
    #expect(settings.differs(from: account))
    let applied = settings.applied(to: account)
    #expect(applied.cashbackRounding.direction == .down)
    #expect(applied.cashbackPayout == .immediately)
    var restored = applied
    restored.cashbackRounding = account.cashbackRounding
    restored.cashbackPayout = account.cashbackPayout
    #expect(restored == account, "only the cashback fields differ")
    #expect(!settings.differs(from: applied))
  }
}
