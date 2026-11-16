import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Net worth with and without the debts owed to me")
struct NetWorthOwedToMeTests {
  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }
  private let day = DateOnly(year: 2026, month: 11, day: 5)

  @Test func theTwoFiguresDifferByExactlyTheDebtsOwedToMe() {
    let point = CapitalPoint(
      day: day, isNow: true, accountsRub: rub(700_000), assetsRub: rub(500_000),
      owedToMeRub: rub(300_000), iOweRub: rub(100_000))
    #expect(point.netRub == rub(1_400_000))
    #expect(point.netWithoutOwedToMeRub == rub(1_100_000))
    #expect(point.netRub - point.netWithoutOwedToMeRub == point.owedToMeRub)
    #expect(point.hasOwedToMe)
  }

  @Test func withNothingOwedToMeTheFiguresAreOne() {
    let point = CapitalPoint(day: day, isNow: true, accountsRub: rub(10), iOweRub: rub(4))
    #expect(point.netWithoutOwedToMeRub == point.netRub)
    #expect(!point.hasOwedToMe)
  }

  @Test func theOwedMoneyIsNotInTheFigureWithoutIt() {
    let point = CapitalPoint(day: day, isNow: true, owedToMeRub: rub(300_000))
    #expect(point.netWithoutOwedToMeRub == .zero)
    #expect(point.netRub == rub(300_000))
  }
}
