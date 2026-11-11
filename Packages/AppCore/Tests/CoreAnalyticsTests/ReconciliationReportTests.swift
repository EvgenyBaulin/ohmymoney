import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

private enum ReportAdjustment: CaseIterable, Sendable {
  case legacyLink, balanceLink, uncategorizedLink, category, subcategory
}

private struct ReconciliationReportBook {
  let food = CoreKit.Category(kind: .expense, name: "Food")
  let transport = CoreKit.Category(kind: .expense, name: "Transport")
  let salary = CoreKit.Category(kind: .income, name: "Salary")
  let counts = CoreKit.Category(kind: .expense, name: "Reconciliation")
  let childId = UUID()
  let person = UUID()
  let adjustmentPerson = UUID()
  let account = UUID()
  let adjustmentAccount = UUID()
  let place = UUID()
  let month = MonthKey(year: 2026, month: 9)
  let today = DateOnly(year: 2026, month: 10, day: 1)

  func entry(
    _ whole: Int64, kind: TransactionKind = .expense, categoryId: UUID?,
    adjustment: Bool = false, link: OperationLink? = nil, month: Int = 9
  ) -> TransactionEntry {
    let moment = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: month, day: 10))
    let transaction = Transaction(
      kind: kind, occurredAt: moment, amountE4: AmountE4(whole: whole),
      amountRubE4: AmountE4(whole: whole),
      placeId: place,
      paymentMethodId: adjustment ? adjustmentAccount : account,
      externalId: link?.externalId, createdAt: moment, updatedAt: moment)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, categoryId: categoryId,
          amountE4: AmountE4(whole: whole), amountRubE4: AmountE4(whole: whole),
          forWhom: .family, forPersonId: adjustment ? adjustmentPerson : person)
      ])
  }

  func ledger(
    _ representation: ReportAdjustment, includeAdjustment: Bool = true,
    onlyAdjustment: Bool = false, adjustmentMonth: Int = 9
  ) -> Ledger {
    let child = CoreKit.Category(id: childId, parentId: counts.id, kind: .expense, name: "Cash")
    var entries: [TransactionEntry] =
      onlyAdjustment
      ? []
      : [
        entry(1_000, categoryId: food.id),
        entry(500, categoryId: transport.id, link: .transferFee(UUID())),
        entry(100, kind: .refund, categoryId: food.id),
        entry(5_000, kind: .income, categoryId: salary.id),
      ]
    if includeAdjustment {
      let categoryId: UUID?
      let link: OperationLink?
      switch representation {
      case .legacyLink:
        categoryId = food.id
        link = .reconciliation(UUID())
      case .balanceLink:
        categoryId = food.id
        link = .reconciledBalance(reconciliation: UUID(), balance: UUID())
      case .uncategorizedLink:
        categoryId = nil
        link = .reconciledBalance(reconciliation: UUID(), balance: UUID())
      case .category:
        categoryId = counts.id
        link = .reconciliation(UUID())
      case .subcategory:
        categoryId = child.id
        link = .reconciledBalance(reconciliation: UUID(), balance: UUID())
      }
      entries.append(
        entry(
          9_000, categoryId: categoryId, adjustment: true, link: link, month: adjustmentMonth))
    }
    var planning = PlanningBook()
    planning.settings.reconcileExpenseCategoryId = counts.id
    return Ledger(
      dataset: Dataset(
        entries: entries, categories: [food, transport, salary, counts, child], planning: planning),
      calendar: .utc)
  }
}

@Suite("Reconciliation adjustments are not report spending")
struct ReconciliationReportTests {
  @Test(arguments: [TransactionKind.expense, .income])
  func bothSignsOfReconciliationOnlyChangeBalances(_ kind: TransactionKind) {
    let book = ReconciliationReportBook()
    var data = book.ledger(.category, includeAdjustment: false).dataset
    let baseline = Ledger(dataset: data, calendar: .utc)
    data.entries.append(
      book.entry(
        700, kind: kind, categoryId: book.salary.id,
        link: .reconciliation(UUID())))
    data.entries.append(
      book.entry(
        50, kind: kind, categoryId: nil,
        link: .reconciledBalance(reconciliation: UUID(), balance: UUID())))
    let ledger = Ledger(dataset: data, calendar: .utc)
    let period = Period.month(book.month)
    #expect(ledger.income(in: period) == baseline.income(in: period))
    #expect(ledger.income(in: .days(period.range)) == baseline.income(in: period))
    #expect(ledger.incomeRows(in: period) == baseline.incomeRows(in: period))
    #expect(
      ledger.rowTotals(of: ledger.entries.map(\.id))
        == baseline.rowTotals(of: baseline.entries.map(\.id)))
    #expect(
      OverviewSummary(ledger: ledger, today: period.end).income
        == OverviewSummary(ledger: baseline, today: period.end).income)
    #expect(
      OverviewSummary(ledger: ledger, today: period.end).reconciliationDifference
        == AmountE4(whole: kind == .income ? 750 : -750))
    for step in TimeSeries.Step.allCases {
      #expect(
        TimeSeries(ledger: ledger, period: period, step: step, measure: .income, today: book.today)
          .total == AmountE4(whole: 5_000))
    }
    #expect(
      IncomeSources(ledger: ledger, period: period)
        == IncomeSources(ledger: baseline, period: period))
    let actual = ReportBuilder(ledger: ledger, today: book.today)
    let expected = ReportBuilder(ledger: baseline, today: book.today)
    for kind in [ReportTable.Kind.incomeByCategory, .monthly, .periodTotal] {
      #expect(actual.table(kind, period: period) == expected.table(kind, period: period))
      #expect(
        ReportCSV.data(actual.table(kind, period: period), label: { $0.description })
          == ReportCSV.data(expected.table(kind, period: period), label: { $0.description }))
    }
  }

  @Test func surplusAloneDoesNotStartAnAverageOrCreateReportData() {
    let book = ReconciliationReportBook()
    let ledger = Ledger(
      dataset: Dataset(entries: [
        book.entry(700, kind: .income, categoryId: nil, link: .reconciliation(UUID()))
      ]), calendar: .utc)
    let monthly = ReportBuilder(ledger: ledger, today: book.today).table(
      .monthly, period: .year(2026))
    #expect(!monthly.hasData)
    #expect(monthly.averageMonths.isEmpty)
    #expect(
      TimeSeries(
        ledger: ledger, period: .month(book.month), step: .day,
        measure: .income, today: book.today
      ).average == nil)
  }

  @Test func separateDifferenceNetsBothSignsAndOnlyIncludesTheDisplayedDays() {
    let book = ReconciliationReportBook()
    let ledger = Ledger(
      dataset: Dataset(entries: [
        book.entry(700, kind: .income, categoryId: nil, link: .reconciliation(UUID())),
        book.entry(
          50, categoryId: nil, link: .reconciledBalance(reconciliation: UUID(), balance: UUID())),
        book.entry(900, kind: .income, categoryId: nil, link: .reconciliation(UUID()), month: 8),
      ]), calendar: .utc)
    #expect(
      OverviewSummary(ledger: ledger, today: book.month.lastDay).reconciliationDifference
        == AmountE4(whole: 650))
    #expect(
      OverviewSummary(ledger: ledger, today: book.month.firstDay).reconciliationDifference == .zero)
  }

  @Test(arguments: [false, true])
  func aManualPurchaseInTheReconciliationCategoryIsSpending(_ subcategory: Bool) {
    let book = ReconciliationReportBook()
    var dataset = book.ledger(.category).dataset
    let categoryId = subcategory ? book.childId : book.counts.id
    dataset.entries.append(book.entry(300, categoryId: categoryId))
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let period = Period.month(book.month)
    let spent = AmountE4(whole: 1_700)
    #expect(ledger.expenses(in: period.range) == spent)
    #expect(ledger.rowTotals(of: ledger.entries.map(\.id)).myExpenses == spent)
    #expect(MyExpensesRule.total(entries: dataset.entries) == spent)
    #expect(
      SpendingComparison(
        ledger: ledger,
        periods: ComparisonPeriods(current: period.range, baseline: period.previous.range),
        choice: .totals
      ).total.current == spent)
    let builder = ReportBuilder(ledger: ledger, today: book.today)
    for grouping in ReportGrouping.allCases {
      for kind in [ReportTable.Kind.expensesByCategory, .expensesByCategoryAndSubcategory] {
        #expect(builder.table(kind, period: period, grouping: grouping).total.amount == spent)
      }
    }
    #expect(builder.table(.monthly, period: .year(2026)).total.values[0] == spent)
    #expect(
      builder.table(.periodTotal, period: period).rows.first { $0.key == .expenses }?.amount
        == spent)
  }

  @Test(arguments: ReportAdjustment.allCases)
  fileprivate func everySpendingTotalUsesTheSameRule(_ representation: ReportAdjustment) {
    let book = ReconciliationReportBook()
    let ledger = book.ledger(representation)
    let period = Period.month(book.month)
    let expected = AmountE4(whole: 1_400)
    #expect(ledger.expenses(in: period.range) == expected)
    #expect(
      ledger.rows.filter { $0.paymentMethodId == book.adjustmentAccount }.allSatisfy {
        $0.contribution == .zero
      })
    #expect(ledger.rowTotals(of: ledger.entries.map(\.id)).myExpenses == expected)
    #expect(
      RowTotals(entries: ledger.dataset.entries, refunds: ledger.refundIndex).myExpenses == expected
    )
    #expect(
      MyExpensesRule.total(entries: ledger.dataset.entries) == expected)
    let comparison = SpendingComparison(
      ledger: ledger,
      periods: ComparisonPeriods(current: period.range, baseline: period.previous.range),
      choice: .totals)
    #expect(comparison.total.current == expected)
    let withoutAdjustment = book.ledger(representation, includeAdjustment: false)
    #expect(
      CashbackChoiceAdvisor.monthlySpending(ledger: ledger, before: book.today.monthKey)
        == CashbackChoiceAdvisor.monthlySpending(
          ledger: withoutAdjustment, before: book.today.monthKey))
    #expect(
      PlacesReport(ledger: ledger, period: period)
        == PlacesReport(ledger: withoutAdjustment, period: period))
    #expect(
      ReceiptHistory(ledger: ledger, range: period.range)
        == ReceiptHistory(ledger: withoutAdjustment, range: period.range))
    #expect(CategoryBreakdown(ledger: ledger, period: period, kind: .expense).total == expected)
    #expect(
      QualityReport(ledger: ledger, period: period, today: book.today).months
        .flatMap(\.qualities).map(\.amount).reduce(.zero, +) == expected)
  }

  @Test(arguments: ReportAdjustment.allCases)
  fileprivate func spendingTablesExcludeReconciliation(_ representation: ReportAdjustment) {
    let book = ReconciliationReportBook()
    let actual = ReportBuilder(ledger: book.ledger(representation), today: book.today)
    let expected = ReportBuilder(
      ledger: book.ledger(representation, includeAdjustment: false), today: book.today)
    let periods: [Period] = [
      .month(book.month), .year(2026),
      .days(DayRange(DateOnly(year: 2026, month: 9, day: 5), book.today)),
    ]
    for period in periods {
      for grouping in ReportGrouping.allCases {
        for kind: ReportTable.Kind in [.expensesByCategory, .expensesByCategoryAndSubcategory] {
          let table = actual.table(kind, period: period, grouping: grouping)
          #expect(table == expected.table(kind, period: period, grouping: grouping))
          #expect(table.total.amount == AmountE4(whole: 1_400))
        }
      }
    }
  }

  @Test(arguments: ReportAdjustment.allCases)
  fileprivate func monthlyAndPeriodTotalsExcludeReconciliation(_ representation: ReportAdjustment) {
    let book = ReconciliationReportBook()
    let actual = ReportBuilder(ledger: book.ledger(representation), today: book.today)
    let expected = ReportBuilder(
      ledger: book.ledger(representation, includeAdjustment: false), today: book.today)
    let monthly = actual.table(.monthly, period: .year(2026))
    #expect(monthly == expected.table(.monthly, period: .year(2026)))
    #expect(
      monthly.rows.first { $0.key == .month(book.month) }?.values[0] == AmountE4(whole: 1_400))
    #expect(
      monthly.total.values == [
        AmountE4(whole: 1_400), AmountE4(whole: 5_000), AmountE4(whole: 3_600),
      ])
    for period in [Period.month(book.month), .year(2026)] {
      let total = actual.table(.periodTotal, period: period)
      #expect(total == expected.table(.periodTotal, period: period))
      #expect(total.rows.first { $0.key == .expenses }?.amount == AmountE4(whole: 1_400))
      #expect(total.total.amount == AmountE4(whole: 3_600))
    }
  }

  @Test(arguments: ReportAdjustment.allCases)
  fileprivate func categoryPersonAndAccountReportsExcludeReconciliation(
    _ representation: ReportAdjustment
  ) {
    let book = ReconciliationReportBook()
    let actual = book.ledger(representation)
    let expected = book.ledger(representation, includeAdjustment: false)
    let period = Period.month(book.month)
    #expect(
      CategoryBreakdown(ledger: actual, period: period, kind: .expense)
        == CategoryBreakdown(ledger: expected, period: period, kind: .expense))
    #expect(
      ForWhomReport(ledger: actual, period: period)
        == ForWhomReport(ledger: expected, period: period))
    #expect(
      PaymentMethodsReport(ledger: actual, period: period)
        == PaymentMethodsReport(ledger: expected, period: period))
    #expect(
      CashbackReport(ledger: actual, period: period).cells
        == CashbackReport(ledger: expected, period: period).cells)
  }

  @Test(arguments: ReportAdjustment.allCases)
  fileprivate func reconciliationAloneIsNotSpendingData(_ representation: ReportAdjustment) {
    let book = ReconciliationReportBook()
    let builder = ReportBuilder(
      ledger: book.ledger(representation, onlyAdjustment: true), today: book.today)
    for kind: ReportTable.Kind in [
      .expensesByCategory, .expensesByCategoryAndSubcategory, .periodTotal,
    ] {
      let table = builder.table(kind, period: .month(book.month))
      #expect(!table.hasData)
      #expect(table.total.amount == .zero)
    }
    let monthly = builder.table(.monthly, period: .year(2026))
    #expect(!monthly.hasData)
    #expect(monthly.averageMonths.isEmpty)
    #expect(monthly.average == nil)
    #expect(monthly.total.values == [.zero, .zero, .zero])
  }

  @Test func reconciliationDoesNotStartTheMonthlyAverage() {
    let book = ReconciliationReportBook()
    let builder = ReportBuilder(
      ledger: book.ledger(.balanceLink, adjustmentMonth: 1), today: book.today)
    let monthly = builder.table(.monthly, period: .year(2026))
    #expect(monthly.averageMonths == [book.month])
    #expect(
      monthly.average?.values == [
        AmountE4(whole: 1_400), AmountE4(whole: 5_000), AmountE4(whole: 3_600),
      ])
  }
}
