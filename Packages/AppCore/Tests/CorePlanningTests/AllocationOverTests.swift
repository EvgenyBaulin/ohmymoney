import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The sheet says so when the lines ask for more than is left, asks a second time only for what
/// is still unallocated, and says «нет курса» instead of a silent zero.
@Suite("The allocation sheet: more than there is, a second visit, a missing rate")
struct AllocationOverTests {
  typealias B = B3Book

  private func setup(income amount: String, currency: CurrencyCode = .rub, rub: String? = nil)
    -> (AllocationTests.Setup, UUID)
  {
    var setup = AllocationTests.Setup()
    let income = setup.book.operation(
      .income, amount, on: B.day(10, 5), category: setup.salary, currency: currency,
      rub: rub, account: setup.main)
    return (setup, income)
  }

  @Test func theLinesAskingMoreThanIsLeftAreOverspent() {
    var (setup, income) = setup(income: "100000")
    setup.book.scheduled = [
      ScheduledPayment(
        name: "Аренда", amountE4: B.rub("40000"), freq: .monthly, day: 20,
        nextDate: B.day(10, 20))
    ]
    let sheet = setup.sheet(income, today: B.day(10, 5))
    #expect(sheet.unallocatedE4 == B.rub("60000"))
    #expect(sheet.overspentE4(chosenE4: B.rub("90000")) == B.rub("30000"))
    #expect(sheet.overspentE4(chosenE4: B.rub("60000")) == nil)
    #expect(sheet.overspentE4(chosenE4: .zero) == nil)
  }

  @Test func aSecondVisitTakesThePercentsOfWhatIsStillUnallocated() {
    var (setup, income) = setup(income: "100000")
    setup.book.rules = [AllocationRule(target: .goal(setup.trip.id), amount: .percent(30))]
    #expect(
      setup.sheet(income, today: B.day(10, 5)).lines.first?.suggestedE4 == B.rub("30000"))
    setup.book.transfers.append(
      Transfer(
        occurredAt: Date(), fromAccountId: setup.main, fromCurrency: .rub,
        fromAmountE4: B.rub("30000"), toAccountId: setup.savings, toCurrency: .rub,
        toAmountE4: B.rub("30000"),
        externalId: Allocation.externalId(incomeId: income, uuid: UUID())))
    let again = setup.sheet(income, today: B.day(10, 5))
    #expect(again.earlierE4 == B.rub("30000"))
    #expect(again.lines.first?.suggestedE4 == B.rub("21000"))
  }

  @Test func aFixedSumWithoutARateIsMarkedNotZeroedInSilence() {
    var (setup, income) = setup(income: "1500", currency: .usd, rub: "135000")
    setup.book.rules = [
      AllocationRule(
        target: .account(setup.savings), amount: .fixed(B.rub("5000"), .rub), sort: 0)
    ]
    let sheet = setup.sheet(income, today: B.day(10, 5))
    let line = sheet.lines.first { $0.kind == .account(setup.savings) }
    #expect(line?.suggestedE4 == .zero)
    #expect(line?.note == .noRate)
  }
}
