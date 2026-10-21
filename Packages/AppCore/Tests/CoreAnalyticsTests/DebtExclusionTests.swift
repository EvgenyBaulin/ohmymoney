import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The balances of debts are never part of the Overview or the Analytics.
///
/// The golden set is taken twice: as it is, and burdened with debts of millions — both
/// directions, open and closed, in rubles and dollars — and long journals on them and on the
/// golden set's own debts, some lines pointing at the golden payments. Not one operation is
/// added. Every figure of the Overview, the Reports tables and the Analytics sections must come
/// out identical: a balance is not spending, and the journal is not an operation.
@Suite("Debt balances never reach the Overview, Reports or Analytics")
struct DebtExclusionTests {
  let golden: Golden
  let plain: Ledger
  let burdened: Ledger
  let today: DateOnly

  let july = Period.month(MonthKey(year: 2026, month: 7))
  let august = Period.month(MonthKey(year: 2026, month: 8))
  var periods: [Period] {
    [july, august, .year(2026), .twelveMonths(endingWith: MonthKey(year: 2026, month: 8))]
  }

  init() throws {
    golden = try Golden.load()
    today = golden.todayDay
    let dataset = golden.dataset()
    plain = Ledger(dataset: dataset, calendar: .utc)
    burdened = Ledger(dataset: Self.withDebts(dataset), calendar: .utc)
  }

  /// Four new debts, and 12 months of lines of every kind on every debt: 6 lines a month on
  /// each of the 8 debts, plus an undated opening line each.
  static func withDebts(_ dataset: Dataset) -> Dataset {
    var copy = dataset
    copy.debts += [
      Debt(
        id: id(9001), direction: .iOwe, type: .loan, name: "Mortgage",
        interestRate: Decimal(string: "11.5"), monthlyPaymentE4: nil, paymentDay: nil),
      Debt(
        id: id(9002), direction: .owedToMe, type: .personal, name: "Loan to a friend",
        personId: id(40)),
      Debt(
        id: id(9003), direction: .iOwe, type: .creditCard, name: "Card", currency: .usd,
        closed: true),
      Debt(
        id: id(9004), direction: .owedToMe, type: .personal, name: "Loan to family",
        personId: id(41), currency: .usd, paymentsAreExpenses: false),
    ]
    var journal: [DebtEntry] = []
    var next = 950_000
    func add(_ debtId: UUID, _ kind: DebtEntryKind, _ amount: String, _ iso: String?, tx: Int?) {
      next += 1
      journal.append(
        DebtRules.makeEntry(
          id: id(next), debtId: debtId, kind: kind, amountE4: money(amount),
          date: iso.map(day), groupName: next % 3 == 0 ? "Renovation" : nil,
          transactionId: tx.map(id)))
    }
    for debt in copy.debts {
      add(debt.id, .borrowed, "25000000", nil, tx: nil)
      for month in 1...12 {
        let prefix = String(format: "2026-%02d", month)
        add(debt.id, .borrowed, "1000000", "\(prefix)-01", tx: nil)
        add(debt.id, .payment, "50000", "\(prefix)-15", tx: nil)
        add(debt.id, .offset, "7000", "\(prefix)-18", tx: nil)
        add(debt.id, .adjustment, "-1234.5678", "\(prefix)-20", tx: nil)
        add(debt.id, .transferIn, "300000", "\(prefix)-21", tx: nil)
        add(debt.id, .transferOut, "300000", "\(prefix)-22", tx: nil)
      }
    }
    // Lines written by the golden payments themselves: the operation counts once, as the
    // operation it is, whatever its journal line says.
    add(id(90), .payment, "7000", "2026-07-25", tx: 117)
    add(id(91), .payment, "2000", "2026-08-05", tx: 126)
    add(id(91), .borrowed, "12000", "2026-07-10", tx: 109)
    add(id(92), .payment, "3000", "2026-07-03", tx: 103)
    copy.planning.debtEntries = journal
    return copy
  }

  @Test func theBurdenIsReal() {
    #expect(burdened.dataset.debts.count == plain.dataset.debts.count + 4)
    #expect(burdened.dataset.planning.debtEntries.count == 8 * (1 + 12 * 6) + 4)
    let balances = DebtRules.balances(
      debts: burdened.dataset.debts, entries: burdened.dataset.planning.debtEntries)
    #expect((balances[.iOwe] ?? .zero) > AmountE4(whole: 10_000_000))
    #expect((balances[.owedToMe] ?? .zero) > AmountE4(whole: 10_000_000))
  }

  @Test func theLedgerIsTheSame() {
    #expect(burdened.rows == plain.rows)
    #expect(burdened.firstDay == plain.firstDay)
    for day in Period.year(2026).range.days {
      let ids = Set(plain.rows(in: DayRange(day, day)).map(\.transactionId))
      #expect(burdened.rowTotals(of: ids) == plain.rowTotals(of: ids), "\(day)")
    }
  }

  @Test func theOverviewIsTheSame() {
    for asOf in [today, day("2026-07-31"), day("2026-08-01"), day("2026-12-31")] {
      #expect(
        OverviewSummary(ledger: burdened, today: asOf)
          == OverviewSummary(ledger: plain, today: asOf), "\(asOf)")
    }
  }

  @Test func theReportsAreTheSame() {
    let before = ReportBuilder(ledger: plain, today: today)
    let after = ReportBuilder(ledger: burdened, today: today)
    for period in periods {
      for kind in ReportTable.Kind.allCases {
        for grouping in ReportGrouping.allCases {
          let table = after.table(kind, period: period, grouping: grouping)
          #expect(table == before.table(kind, period: period, grouping: grouping))
          #expect(
            ReportCSV.data(table, label: golden.label)
              == ReportCSV.data(
                before.table(kind, period: period, grouping: grouping), label: golden.label))
        }
      }
    }
  }

  @Test func theAnalyticsAreTheSame() {
    for period in periods {
      for kind in [CategoryKind.expense, .income] {
        #expect(
          CategoryBreakdown(ledger: burdened, period: period, kind: kind)
            == CategoryBreakdown(ledger: plain, period: period, kind: kind))
      }
      for step in TimeSeries.Step.allCases {
        for measure in SeriesMeasure.allCases {
          #expect(
            TimeSeries(ledger: burdened, period: period, step: step, measure: measure, today: today)
              == TimeSeries(
                ledger: plain, period: period, step: step, measure: measure, today: today))
        }
      }
      #expect(
        IncomeVsExpense(ledger: burdened, period: period)
          == IncomeVsExpense(ledger: plain, period: period))
      #expect(
        IncomeSources(ledger: burdened, period: period)
          == IncomeSources(ledger: plain, period: period))
      #expect(
        PeriodComparison(ledger: burdened, period: period, today: today)
          == PeriodComparison(ledger: plain, period: period, today: today))
      #expect(
        WeekdayProfile(ledger: burdened, period: period, today: today)
          == WeekdayProfile(ledger: plain, period: period, today: today))
      #expect(
        QualityReport(ledger: burdened, period: period, today: today)
          == QualityReport(ledger: plain, period: period, today: today))
      #expect(
        OthersReport(ledger: burdened, period: period)
          == OthersReport(ledger: plain, period: period))
      #expect(
        ForWhomReport(ledger: burdened, period: period)
          == ForWhomReport(ledger: plain, period: period))
      #expect(
        PlacesReport(ledger: burdened, period: period)
          == PlacesReport(ledger: plain, period: period))
      #expect(
        EventsReport(ledger: burdened, period: period)
          == EventsReport(ledger: plain, period: period))
      #expect(
        PaymentMethodsReport(ledger: burdened, period: period)
          == PaymentMethodsReport(ledger: plain, period: period))
    }
  }

  /// The forecast reads the monthly payments of the debts, never their balances: the new
  /// debts have no payment, and of the journals only a `payment` line counts — a month paid
  /// on the debt card alone is paid (`DebtSchedule.isPaid`, `PlannedMonth`) — while the
  /// millions borrowed, offset, adjusted and moved change nothing.
  @Test func theForecastIsTheSame() {
    var paymentsOnly = plain.dataset
    paymentsOnly.planning.debtEntries = burdened.dataset.planning.debtEntries.filter {
      $0.kind == .payment
    }
    let paid = Ledger(dataset: paymentsOnly, calendar: .utc)
    #expect(
      PlannedPayments(ledger: burdened, today: today, rubPerUnit: golden.rubPerUnit)
        == PlannedPayments(ledger: paid, today: today, rubPerUnit: golden.rubPerUnit))
    #expect(
      MonthForecast.remainder(ledger: burdened, today: today)
        == MonthForecast.remainder(ledger: plain, today: today))
  }

  @Test func theTransactionsFilterIsTheSame() {
    for filter in [
      EntryFilter.none, EntryFilter(period: july), EntryFilter(period: august, kind: .expense),
    ] {
      #expect(filter.apply(to: burdened) == filter.apply(to: plain))
    }
  }
}
