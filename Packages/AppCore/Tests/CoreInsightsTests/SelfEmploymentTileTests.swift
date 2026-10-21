import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

@Suite("«Почему так» of the tiles of 1.9")
struct SelfEmploymentTileTests {
  let today = DateOnly(year: 2026, month: 11, day: 2)

  func book(deduction: Bool) -> Dataset {
    let individuals = CoreKit.Category(
      kind: .income, name: "от физлиц", tax: IncomeTax(rate: 4, npd: true))
    let organizations = CoreKit.Category(
      kind: .income, name: "от организаций", tax: IncomeTax(rate: 6, npd: true))
    func income(_ rubles: Int64, _ category: UUID, day: Int) -> TransactionEntry {
      let id = UUID()
      let amount = AmountE4(whole: rubles)
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: .income,
          occurredAt: CalendarContext.utc.noon(of: DateOnly(year: 2026, month: 10, day: day)),
          amountE4: amount),
        parts: [TransactionPart(transactionId: id, categoryId: category, amountE4: amount)])
    }
    return Dataset(
      entries: [income(6000, individuals.id, day: 5), income(50000, organizations.id, day: 12)],
      categories: [individuals, organizations],
      paymentMethods: [PaymentMethod(name: "Основной", isDefault: true)],
      selfEmployment: SelfEmploymentSettings(
        enabled: true, deductionLeftE4: deduction ? AmountE4(whole: 10_000) : nil,
        deductionLeftOn: DateOnly(year: 2026, month: 9, day: 30)))
  }

  func inputs(_ dataset: Dataset) -> TileInputs {
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: CalendarContext.utc.noon(of: today), rubPerUnit: [:])
    return TileInputs(
      ledger: ledger, summary: OverviewSummary(ledger: ledger, today: today), planning: planning,
      today: today)
  }

  @Test(arguments: [true, false])
  func theTaxAddsUp(_ deduction: Bool) {
    let explanation = TileExplanations.explain(.selfEmployment, inputs(book(deduction: deduction)))
    #expect(explanation.state == .ready)
    #expect(explanation.sections.first?.addsUp == true)
    #expect(
      explanation.figure
        == .money(AmountE4(whole: deduction ? 2_180 : 3_240), .rub))
  }

  @Test func offSaysSo() {
    var dataset = book(deduction: false)
    dataset.selfEmployment.enabled = false
    #expect(
      TileExplanations.explain(.selfEmployment, inputs(dataset)).state
        == .empty(TilePhrase("why.selfEmployed.off")))
  }

  @Test func noInstalmentsSaysSo() {
    #expect(
      TileExplanations.explain(.installments, inputs(book(deduction: false))).state
        == .empty(TilePhrase("why.instalments.none")))
  }

  @Test func theTaxIsALineOfTheFreeSum() {
    let free = TileExplanations.freeMoney(
      FreeMoney(
        accounts: .empty, plan: CashPlan(npdTax: AmountE4(whole: 400)), stillExpected: .zero,
        today: today, until: today))
    #expect(free.state == .empty(TilePhrase("why.free.noReconciliation")))
    #expect(TileExplanations.freeKey(FreeMoney.Key.npdTax) == "why.free.npdTax")
    #expect(TileExplanations.freeKey(FreeMoney.Key.creditCards) == "why.free.creditCards")
  }

  @Test func theTaxIsWorthALookThreeDaysBeforeItsDay() {
    func notes(on day: DateOnly) -> [WorthALookNote] {
      let dataset = book(deduction: false)
      let ledger = Ledger(dataset: dataset, calendar: .utc)
      let planning = PlanningSnapshot.build(
        ledger: ledger, today: day, now: CalendarContext.utc.noon(of: day), rubPerUnit: [:])
      return WorthALook.notes(planning: planning, ledger: ledger, today: day)
    }
    #expect(
      !notes(on: DateOnly(year: 2026, month: 11, day: 24)).contains { $0.id == "npdDue:2026-10" })
    #expect(
      notes(on: DateOnly(year: 2026, month: 11, day: 25)).contains { $0.id == "npdDue:2026-10" })
    #expect(
      notes(on: DateOnly(year: 2026, month: 12, day: 1)).contains { $0.id == "npdDue:2026-10" })
  }

  @Test func burnoutOnlyOnceAWeek() {
    let dataset = book(deduction: false)
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: CalendarContext.utc.noon(of: today), rubPerUnit: [:])
    let signal = BurnoutCheck.signal(
      BurnoutSignal(lastWeekCount: 14, usualCount: 6, from: today, through: today))
    let shown = WorthALook.notes(planning: planning, ledger: ledger, today: today, burnout: signal)
    #expect(shown.contains { if case .burnout = $0 { true } else { false } })
    let again = WorthALook.notes(
      planning: planning, ledger: ledger, today: today, burnout: signal,
      burnoutLastShownWeek: Burnout.weekKey(today))
    #expect(!again.contains { if case .burnout = $0 { true } else { false } })
  }

  /// Less than a gigabyte free where the copies lie is a line of «Стоит посмотреть»; exactly a
  /// gigabyte, or a disk that could not be asked, is not.
  @Test func littleRoomForCopiesIsAWorthALookLineBelowAGigabyteOnly() {
    let dataset = book(deduction: false)
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: CalendarContext.utc.noon(of: today), rubPerUnit: [:])
    func ids(_ free: Int64?) -> [String] {
      WorthALook.notes(planning: planning, ledger: ledger, today: today, copyFreeBytes: free)
        .map(\.id)
    }
    #expect(ids(999_999_999).contains("lowCopySpace"))
    #expect(!ids(1_000_000_000).contains("lowCopySpace"))
    #expect(!ids(nil).contains("lowCopySpace"))
  }

  /// The check of the database that found something is a line; one that found nothing is not.
  @Test func problemsFoundInTheDatabaseAreAWorthALookLine() {
    let dataset = book(deduction: false)
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: CalendarContext.utc.noon(of: today), rubPerUnit: [:])
    func ids(_ problems: Int) -> [String] {
      WorthALook.notes(planning: planning, ledger: ledger, today: today, databaseProblems: problems)
        .map(\.id)
    }
    #expect(ids(2).contains("databaseProblems"))
    #expect(!ids(0).contains("databaseProblems"))
  }
}
