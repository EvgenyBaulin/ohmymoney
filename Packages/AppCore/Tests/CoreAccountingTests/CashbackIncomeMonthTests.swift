import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The month a new cashback income is for: a bank that pays a month's cashback by a day of the
/// next one pays the month before.
@Suite("The month of a cashback income")
struct CashbackIncomeMonthTests {
  let tBank = id(1)
  let bonus = id(2)
  let alfa = id(3)
  let cashback = id(10)
  let cashbackCard = id(11)
  let salary = id(12)

  var tree: CategoryTree {
    CategoryTree([
      CoreKit.Category(id: cashback, kind: .income, name: "Cashback"),
      CoreKit.Category(id: cashbackCard, parentId: cashback, kind: .income, name: "Black"),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    ])
  }

  func accounts(
    _ payout: CashbackPayout?, points: UUID? = nil, bonusPayout: CashbackPayout? = nil
  )
    -> [PaymentMethod]
  {
    [
      PaymentMethod(
        id: tBank, name: "T-Bank", cashbackPayout: payout, cashbackPointsAccountId: points),
      PaymentMethod(id: bonus, name: "Bonus", cashbackPayout: bonusPayout),
      PaymentMethod(id: alfa, name: "Alfa"),
    ]
  }

  func month(
    _ day: String, _ payout: CashbackPayout?, category: UUID? = nil, account: UUID? = nil,
    points: UUID? = nil, bonusPayout: CashbackPayout? = nil, categories: [UUID?]? = nil
  ) -> String {
    CashbackIncomeMonth.month(
      forIncomeOn: DateOnly(iso: day)!, categoryIds: categories ?? [category ?? cashback],
      accountId: account ?? tBank, cashbackCategoryId: cashback, tree: tree,
      accounts: accounts(payout, points: points, bonusPayout: bonusPayout), calendar: .utc
    ).iso
  }

  /// «By the 10th»: the 8th and the 10th of October are September's, the 11th is October's.
  @Test func onOrBeforeThePayoutDayItIsTheMonthBefore() {
    let later = CashbackPayout.later(day: 10)
    #expect(month("2026-10-08", later) == "2026-09")
    #expect(month("2026-10-10", later) == "2026-09")
    #expect(month("2026-10-01", later) == "2026-09")
    #expect(month("2026-10-11", later) == "2026-10")
  }

  /// «By the end of the month»: every day of October is September's — and of February, whose
  /// last day is the 28th, January's.
  @Test func theEndOfTheMonthCoversTheWholeMonth() {
    let end = CashbackPayout.later(day: 31)
    #expect(month("2026-10-31", end) == "2026-09")
    #expect(month("2026-10-15", end) == "2026-09")
    #expect(month("2027-02-28", end) == "2027-01")
    // The 30th in February is February's last day as well.
    #expect(month("2027-02-28", CashbackPayout.later(day: 30)) == "2027-01")
  }

  @Test func januaryIsForDecemberOfTheYearBefore() {
    #expect(month("2027-01-05", CashbackPayout.later(day: 10)) == "2026-12")
  }

  @Test func aBankThatPaysWithThePurchaseOrHasNotSaidKeepsTheMonthOfTheDate() {
    #expect(month("2026-10-08", .immediately) == "2026-10")
    #expect(month("2026-10-08", nil) == "2026-10")
  }

  /// Only cashback: a salary on the same day stays in its month; a subcategory of cashback is
  /// cashback; a split with anything else is not.
  @Test func onlyCashbackMovesBack() {
    let later = CashbackPayout.later(day: 10)
    #expect(month("2026-10-08", later, category: salary) == "2026-10")
    #expect(month("2026-10-08", later, category: cashbackCard) == "2026-09")
    #expect(month("2026-10-08", later, categories: [cashback, salary]) == "2026-10")
    #expect(month("2026-10-08", later, categories: [nil]) == "2026-10")
    #expect(month("2026-10-08", later, categories: []) == "2026-10")
  }

  /// No cashback category set, no account: the month of the date.
  @Test func withoutTheSettingOrAnAccountNothingMoves() {
    let later = CashbackPayout.later(day: 10)
    #expect(
      CashbackIncomeMonth.month(
        forIncomeOn: DateOnly(iso: "2026-10-08")!, categoryIds: [cashback], accountId: tBank,
        cashbackCategoryId: nil, tree: tree, accounts: accounts(later), calendar: .utc
      ).iso == "2026-10")
    #expect(
      CashbackIncomeMonth.month(
        forIncomeOn: DateOnly(iso: "2026-10-08")!, categoryIds: [cashback], accountId: nil,
        cashbackCategoryId: cashback, tree: tree, accounts: accounts(later), calendar: .utc
      ).iso == "2026-10")
  }

  /// Points that come to a points account are the cashback of the account that earned them: its
  /// bank decides, not the points account's.
  @Test func onAPointsAccountTheEarningAccountDecides() {
    let later = CashbackPayout.later(day: 10)
    #expect(month("2026-10-08", later, account: bonus, points: bonus) == "2026-09")
    #expect(
      month("2026-10-08", .immediately, account: bonus, points: bonus, bonusPayout: later)
        == "2026-10")
    // Not named as anybody's points account: its own setting.
    #expect(month("2026-10-08", nil, account: bonus, bonusPayout: later) == "2026-09")
    #expect(month("2026-10-08", later, account: alfa) == "2026-10")
  }
}
