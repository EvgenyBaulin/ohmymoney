import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The capital before the books began: purchases, loans and the rough cash the owner named.
@Suite("Capital before the books")
struct CapitalPastTests {
  typealias Fx = CapitalFx

  let main = Fx.id(1)

  func accounts() -> [PaymentMethod] { [PaymentMethod(id: main, name: "Main", isDefault: true)] }

  func point(_ capital: CapitalSnapshot, _ iso: String) -> CapitalPoint? {
    capital.points.first { $0.day == Fx.day(iso) }
  }

  // MARK: Assets

  func carDataset(
    price: String = "900", valued: String? = "1800", cash: PastCash? = nil
  )
    -> Dataset
  {
    let (count, rows) = Fx.count(1, "2026-03-10", [(main, .rub, "100000")])
    let car = Asset(
      id: Fx.id(10), name: "Car", kind: .vehicle, purchasedOn: Fx.day("2026-01-01"),
      purchasePriceE4: Fx.rub(price))
    var dataset = Dataset(
      paymentMethods: accounts(),
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows), assets: [car],
      assetValuations: valued.map {
        [AssetValuation(assetId: car.id, day: Fx.day("2026-04-01"), valueE4: Fx.rub($0))]
      } ?? [])
    dataset.capitalSettings = CapitalSettings(pastCash: cash)
    return dataset
  }

  @Test func anAssetIsWorthItsPriceFromItsPurchaseThenAStraightLineToItsNextValuation() {
    let capital = Fx.capital(carDataset(), today: Fx.day("2026-06-11"), months: nil)
    #expect(capital.points.first?.day == Fx.day("2026-01-31"))
    let january = point(capital, "2026-01-31")
    // 30 of the 90 days from 1 January to 1 April.
    #expect(january?.assetsRub == Fx.rub("1200"))
    #expect(january?.straightLineAssets == true)
    #expect(january?.beforeBooks == true)
    // Once valued it is the valuation, no line.
    let april = point(capital, "2026-04-30")
    #expect(april?.assetsRub == Fx.rub("1800"))
    #expect(april?.straightLineAssets == false)
    // «Now» is still the last valuation.
    #expect(capital.now.assetsRub == Fx.rub("1800"))
  }

  @Test func anAssetWithNoLaterValuationStaysAtItsPrice() {
    let capital = Fx.capital(carDataset(valued: nil), today: Fx.day("2026-06-11"), months: nil)
    let march = point(capital, "2026-03-31")
    #expect(march?.assetsRub == Fx.rub("900"))
    #expect(march?.straightLineAssets == false)
    // At «now» the purchase price is shown as a price, not as a valuation.
    #expect(capital.now.assetsRub == Fx.rub("900"))
    #expect(capital.now.unvalued.isEmpty)
    let car = capital.breakdown.have.first { $0.source == .asset(Fx.id(10)) }
    #expect(car?.amount == Fx.rub("900"))
    #expect(car?.amountRub == Fx.rub("900"))
    let chart = NetWorthChartModel(capital.points)
    #expect(chart.points.last?.notes.contains(.purchasePrice) == true)
  }

  @Test func halfAPurchaseIsNoPurchase() {
    var dataset = carDataset()
    dataset.assets[0].purchasePriceE4 = nil
    let capital = Fx.capital(dataset, today: Fx.day("2026-06-11"), months: nil)
    #expect(capital.points.first?.day == Fx.day("2026-03-31"))
    #expect(capital.pastCashDay == nil)
  }

  // MARK: Loans

  func loanDataset(interest: Decimal? = nil, payment: String? = "100000") -> Dataset {
    let (count, rows) = Fx.count(1, "2025-09-10", [(main, .rub, "100000")])
    let loan = Debt(
      id: Fx.id(20), direction: .iOwe, type: .loan, name: "Loan", interestRate: interest,
      monthlyPaymentE4: payment.map(Fx.rub), paymentDay: 15, openedOn: Fx.day("2025-01-15"),
      originalAmountE4: Fx.rub("1200000"))
    let line = DebtEntry(
      id: Fx.id(21), debtId: loan.id, date: Fx.day("2025-07-20"),
      amountE4: Fx.rub("612000"), kind: .borrowed)
    return Dataset(
      paymentMethods: accounts(), debts: [loan],
      planning: PlanningBook(
        reconciliations: [count], debtEntries: [line], reconciledBalances: rows))
  }

  @Test func aLoanBeforeItsJournalFollowsTheScheduleBentToTheFirstBalance() {
    let capital = Fx.capital(loanDataset(), today: Fx.day("2025-12-11"), months: nil)
    #expect(capital.points.first?.day == Fx.day("2025-01-31"))
    // Taken out: the sum borrowed, no payment yet.
    #expect(point(capital, "2025-01-31")?.iOweRub == Fx.rub("1200000"))
    // The schedule gives 600 000 on 20 July; the journal says 612 000: 12 000 spread over six
    // months, 2 000 for each.
    #expect(point(capital, "2025-04-30")?.iOweRub == Fx.rub("906000"))
    #expect(point(capital, "2025-06-30")?.iOweRub == Fx.rub("710000"))
    #expect(point(capital, "2025-06-30")?.restoredDebts == true)
    // From the first line of the journal on, only the records.
    #expect(point(capital, "2025-07-31")?.iOweRub == Fx.rub("612000"))
    #expect(point(capital, "2025-07-31")?.restoredDebts == false)
    #expect(capital.pastCashDay == Fx.day("2025-01-15"))
  }

  @Test func aLoanWithoutPaymentOrTermIsAStraightLineToTheFirstBalance() {
    let capital = Fx.capital(loanDataset(payment: nil), today: Fx.day("2025-12-11"), months: nil)
    // 1 200 000 to 612 000 in six months: 98 000 a month.
    #expect(point(capital, "2025-01-31")?.iOweRub == Fx.rub("1200000"))
    #expect(point(capital, "2025-04-30")?.iOweRub == Fx.rub("906000"))
  }

  @Test func interestOnlyGraceKeepsThePrincipalUntilTheMainScheduleStarts() {
    var dataset = loanDataset(interest: 12)
    dataset.debts[0].grace = DebtGrace(
      mainFrom: Fx.day("2025-03-01"), payment: .interest)
    dataset.planning.debtEntries = [
      DebtEntry(
        id: Fx.id(22), debtId: Fx.id(20), date: Fx.day("2025-03-01"),
        amountE4: Fx.rub("1200000"), kind: .borrowed)
    ]

    let capital = Fx.capital(dataset, today: Fx.day("2025-12-11"), months: nil)

    #expect(point(capital, "2025-02-28")?.iOweRub == Fx.rub("1200000"))
  }

  @Test func aPaymentPauseSkipsItsDuesAndMovesTheRestOfTheSchedule() {
    var dataset = loanDataset(interest: 0)
    dataset.debts[0].pause = DebtPause(
      from: Fx.day("2025-02-15"), to: Fx.day("2025-03-15"), kind: .holiday)
    dataset.planning.debtEntries = [
      DebtEntry(
        id: Fx.id(22), debtId: Fx.id(20), date: Fx.day("2025-06-01"),
        amountE4: Fx.rub("1000000"), kind: .borrowed)
    ]

    let capital = Fx.capital(dataset, today: Fx.day("2025-12-11"), months: nil)

    #expect(point(capital, "2025-05-31")?.iOweRub == Fx.rub("1000000"))
  }

  @Test func typedPaymentStepsReconstructDifferentiatedPrincipalPayments() {
    var dataset = loanDataset(interest: 12, payment: nil)
    let rows = DebtAmortization.differentiatedSchedule(
      principal: Fx.rub("1200000"), percent: 12, months: 4,
      firstDue: Fx.day("2025-02-01"), paymentDay: 15)
    #expect(AmountE4.sum(rows.map(\.principalE4)) == Fx.rub("1200000"))
    dataset.debtInstalments = rows.map {
      DebtInstalmentStep(debtId: Fx.id(20), fromIndex: $0.index, amountE4: $0.paymentE4)
    }
    dataset.planning.debtEntries = [
      DebtEntry(
        id: Fx.id(22), debtId: Fx.id(20), date: Fx.day("2025-05-01"),
        amountE4: Fx.rub("300000"), kind: .borrowed)
    ]

    let capital = Fx.capital(dataset, today: Fx.day("2025-12-11"), months: nil)

    // Equal principal parts of 300,000 add to the original amount after rounding.
    #expect(point(capital, "2025-02-28")?.iOweRub == Fx.rub("900000"))
    #expect(point(capital, "2025-04-30")?.iOweRub == Fx.rub("300000"))
  }

  @Test func theTermStandsInForAPayment() {
    var dataset = loanDataset(payment: nil)
    dataset.debts[0].repayMonths = 12
    let capital = Fx.capital(dataset, today: Fx.day("2025-12-11"), months: nil)
    // Twelve equal payments of 100 000 without interest: the same schedule as above.
    #expect(point(capital, "2025-04-30")?.iOweRub == Fx.rub("906000"))
  }

  @Test func aLoanIsNotRestoredWhenItsJournalHasADaylessLine() {
    var dataset = loanDataset()
    dataset.planning.debtEntries.append(
      DebtEntry(id: Fx.id(22), debtId: Fx.id(20), amountE4: Fx.rub("1"), kind: .borrowed))
    let capital = Fx.capital(dataset, today: Fx.day("2025-12-11"), months: nil)
    #expect(capital.points.first?.day == Fx.day("2025-09-30"))
  }

  // MARK: Cash

  @Test func theRoughCashRunsInAStraightLineToTheFirstCount() {
    let cash = PastCash(day: Fx.day("2026-01-01"), amountE4: Fx.rub("50000"))
    let capital = Fx.capital(carDataset(cash: cash), today: Fx.day("2026-06-11"), months: nil)
    // 30 of the 89 days from 1 January to the 31 March count of 100 000.
    let january = point(capital, "2026-01-31")
    let expected = 50_000 + 50_000 * 30.0 / 89.0
    #expect(abs(Double(january?.estimatedCashRub.raw ?? 0) / 10_000 - expected) < 1)
    #expect(january?.withoutCash == false)
    #expect(
      january?.haveRub == (january?.assetsRub ?? .zero) + (january?.estimatedCashRub ?? .zero))
    // The books count the cash from then on and never read the sum again.
    let april = point(capital, "2026-04-30")
    #expect(april?.estimatedCashRub == .zero)
    #expect(april?.accountsRub == Fx.rub("100000"))
  }

  @Test func withoutAnAnswerThePointsBeforeTheBooksHoldNoCash() {
    let capital = Fx.capital(carDataset(), today: Fx.day("2026-06-11"), months: nil)
    for iso in ["2026-01-31", "2026-02-28"] {
      #expect(point(capital, iso)?.withoutCash == true)
      #expect(point(capital, iso)?.estimatedCashRub == .zero)
    }
    #expect(point(capital, "2026-03-31")?.withoutCash == false)
  }

  @Test func twelveMonthsDoNotReachBeforeTheBooksWhenTheyAreOlder() {
    let capital = Fx.capital(carDataset(), today: Fx.day("2027-06-11"))
    #expect(capital.points.allSatisfy { !$0.beforeBooks })
  }

  // MARK: The chart

  @Test func theChartCutsTheLineIntoRunsDrawnOneWayAndNamesWhyEachIsNotARecord() {
    let capital = Fx.capital(carDataset(), today: Fx.day("2026-06-11"), months: nil)
    let model = NetWorthChartModel(
      capital.points, pastCashDay: capital.pastCashDay)
    #expect(model.cashQuestionDay == Fx.day("2026-01-01"))
    // January and February: grey; March and the rest: the books, with the line to the valuation
    // in March marked on its own.
    let lines = model.segments.map(\.line)
    #expect(lines.first == .withoutCash)
    #expect(lines.last == .recorded)
    // The run that begins where the grey one ends repeats its last point: the line is whole.
    for (left, right) in zip(model.segments, model.segments.dropFirst()) {
      #expect(left.points.last == right.points.first)
    }
    #expect(model.segments.flatMap(\.points).count >= model.points.count)
    #expect(model.notes.contains(.straightLine))
    #expect(model.notes.contains(.withoutCash))
  }

  @Test func anAnswerMakesTheEarlyRunDashedAndNoQuestionIsAskedWithoutThePast() {
    let cash = PastCash(day: Fx.day("2026-01-01"), amountE4: Fx.rub("50000"))
    let capital = Fx.capital(carDataset(cash: cash), today: Fx.day("2026-06-11"), months: nil)
    let model = NetWorthChartModel(
      capital.points, pastCashDay: capital.pastCashDay, pastCash: cash)
    #expect(model.segments.first?.line == .reconstructed)
    #expect(model.notes.contains(.cashEstimated))
    #expect(!model.notes.contains(.withoutCash))
    #expect(model.pastCash == cash)

    let recent = Fx.capital(carDataset(), today: Fx.day("2027-06-11"))
    let plain = NetWorthChartModel(recent.points, pastCashDay: recent.pastCashDay)
    #expect(plain.cashQuestionDay == nil)
    #expect(plain.segments.count == 1)
  }
}
