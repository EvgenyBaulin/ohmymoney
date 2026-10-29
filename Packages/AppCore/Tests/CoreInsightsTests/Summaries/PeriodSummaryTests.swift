import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("«Итоги»: months and years")
struct PeriodSummaryTests {
  let today = DateOnly(year: 2026, month: 10, day: 26)
  static let september = MonthKey(year: 2026, month: 9)

  /// June to September 2026: a steady life, with cafés jumping in September.
  func book() -> SummaryBook {
    var book = SummaryBook()
    for month in 6...9 {
      let key = MonthKey(year: 2026, month: month)
      book.earn(100_000, on: DateOnly(year: 2026, month: month, day: 5))
      book.add(
        SummaryBook.Spec(amount: 7_000, category: book.cashback.id, kind: .income),
        on: DateOnly(year: 2026, month: month, day: 6))
      for day in [3, 9, 15, 21, 27] {
        let date = DateOnly(year: 2026, month: month, day: day)
        book.add(SummaryBook.Spec(amount: 3_000, place: book.shopA.id), on: date)
        book.add(SummaryBook.Spec(amount: 1_000, category: book.transport.id), on: date)
        book.add(
          SummaryBook.Spec(
            amount: key == Self.september ? 4_000 : 1_000, place: book.shopB.id,
            category: book.cafe.id), on: date)
      }
    }
    return book
  }

  func summary(_ id: SummaryID, _ book: SummaryBook, moods: [WeekMood] = []) -> PeriodSummary {
    SummaryBuilder.summary(id: id, ledger: book.ledger, today: today, moods: moods)!
  }

  @Test func totalsAreTheOnesOfTheReports() {
    let book = book()
    let ledger = book.ledger
    let reports = ReportBuilder(ledger: ledger, today: today)
    for id in [SummaryID.month(Self.september), .year(2026)] {
      let made = summary(id, book)
      let table = reports.table(.periodTotal, period: made.period)
      #expect(made.income == table.rows[0].amount)
      #expect(made.expenses == table.rows[1].amount)
      #expect(made.net == table.total.amount)
      #expect(made.expenses == ledger.expenses(in: made.period.range))
      #expect(made.income == ledger.income(in: made.period))
    }
  }

  @Test func categoriesAreTheOnesOfTheBreakdown() {
    let book = book()
    let made = summary(.month(Self.september), book)
    let breakdown = CategoryBreakdown(
      ledger: book.ledger, period: .month(Self.september), kind: .expense)
    for item in made.topCategories {
      let node = breakdown.nodes.first { $0.key == .category(item.categoryId) }
      #expect(node?.amount == item.amount)
      #expect(node?.share == item.shareBP)
    }
    #expect(made.topCategories.first?.categoryId == book.cafe.id)
    #expect(AmountE4.sum(made.topCategories.map(\.amount)) == made.expenses)
  }

  @Test func theSurpriseIsTheCategoryFurthestFromTheUsual() {
    let book = book()
    let made = summary(.month(Self.september), book)
    #expect(made.surprise?.categoryId == book.cafe.id)
    #expect(made.surprise?.amount == AmountE4(whole: 20_000))
    #expect(made.surprise?.usual == AmountE4(whole: 5_000))
    #expect(made.surprise?.moreBP == 30_000)
    // In August nothing stood out.
    #expect(summary(.month(MonthKey(year: 2026, month: 8)), book).surprise == nil)
  }

  @Test func theSurpriseNeedsTwoMonthsOfHistory() {
    let book = book()
    #expect(summary(.month(MonthKey(year: 2026, month: 7)), book).surprise == nil)
  }

  @Test func theDifferenceOfACountIsNotASurprise() {
    var book = book()
    book.add(
      SummaryBook.Spec(
        amount: 90_000, category: book.recount.id,
        externalId: "reconcile:\(UUID().uuidString.lowercased())"),
      on: DateOnly(year: 2026, month: 9, day: 28))
    let made = summary(.month(Self.september), book)
    #expect(made.surprise?.categoryId == book.cafe.id)
    // The totals stay the Reports' own: they add it, as the Reports do.
    let table = ReportBuilder(ledger: book.ledger, today: today)
      .table(.periodTotal, period: .month(Self.september))
    #expect(made.expenses == table.rows[1].amount)
  }

  @Test func cashbackIsWhatCameInTheCashbackCategory() {
    var book = book()
    book.settings = AnalyticsSettings(cashbackCategoryId: book.cashback.id)
    let made = summary(.month(Self.september), book)
    #expect(made.cashback == AmountE4(whole: 7_000))
    let year = summary(.year(2026), book)
    #expect(year.cashback == AmountE4(whole: 28_000))
    #expect(
      year.cashback
        == AmountE4.sum(
          CashbackReport(ledger: book.ledger, period: .year(2026)).cells.map(\.receivedRub)))
    #expect(summary(.month(Self.september), self.book()).cashback == .zero)
  }

  @Test func theBestMonthOfAYearIsTheOneThatKeptTheMost() {
    let book = book()
    let made = summary(.year(2026), book)
    // September's cafés cost 15,000 ₽ more than any other month.
    #expect(made.bestMonth?.month == MonthKey(year: 2026, month: 6))
    let monthly = ReportBuilder(ledger: book.ledger, today: today).table(
      .monthly, period: .year(2026))
    let nets = monthly.rows.compactMap { $0.values.count == 3 ? $0.values[2] : nil }
    #expect(made.bestMonth?.net == nets.max())
    #expect(summary(.month(Self.september), book).bestMonth == nil)
  }

  @Test func closedDebtsAreThoseWhoseJournalEndedInThePeriod() {
    var book = book()
    let paid = Debt(direction: .iOwe, type: .loan, name: "Рассрочка", closed: true)
    let old = Debt(direction: .iOwe, type: .loan, name: "Старый", closed: true)
    let open = Debt(direction: .iOwe, type: .loan, name: "Открытый")
    book.debts = [paid, old, open]
    book.debtEntries = [
      DebtEntry(
        debtId: paid.id, date: DateOnly(year: 2026, month: 9, day: 10),
        amountE4: -AmountE4(whole: 1), kind: .payment),
      DebtEntry(
        debtId: old.id, date: DateOnly(year: 2026, month: 5, day: 10),
        amountE4: -AmountE4(whole: 1), kind: .payment),
      DebtEntry(
        debtId: open.id, date: DateOnly(year: 2026, month: 9, day: 10),
        amountE4: -AmountE4(whole: 1), kind: .payment),
    ]
    #expect(summary(.month(Self.september), book).closedDebts.map(\.name) == ["Рассрочка"])
    #expect(summary(.year(2026), book).closedDebts.map(\.name) == ["Рассрочка", "Старый"])
  }

  @Test func theMoodOfAMonthIsReadFromItsWeeks() {
    let book = book()
    let moods = [
      WeekMood(
        week: WeekKey(containing: DateOnly(year: 2026, month: 9, day: 8)), mood: 4,
        answeredAt: Date(timeIntervalSince1970: 0)),
      WeekMood(
        week: WeekKey(containing: DateOnly(year: 2026, month: 9, day: 15)), mood: 3,
        answeredAt: Date(timeIntervalSince1970: 0)),
      WeekMood(
        week: WeekKey(containing: DateOnly(year: 2026, month: 8, day: 11)), mood: 1,
        answeredAt: Date(timeIntervalSince1970: 0)),
    ]
    let made = summary(.month(Self.september), book, moods: moods)
    #expect(made.moods.count == 2)
    #expect(made.moodTimesTen == 35)
    #expect(summary(.month(Self.september), book).moodTimesTen == nil)
  }

  @Test func theChangeAgainstTheMonthBefore() {
    let book = book()
    let made = summary(.month(Self.september), book)
    // 40,000 ₽ in September against 25,000 ₽ in August.
    #expect(made.expensesChangeBP == 6_000)
  }

  @Test func aWeekHasNoPeriodSummary() {
    #expect(
      SummaryBuilder.summary(
        id: .week(WeekKey(year: 2026, week: 1)), ledger: book().ledger, today: today) == nil)
  }

  // MARK: The words

  func fullSummary() -> PeriodSummary {
    var book = book()
    book.settings = AnalyticsSettings(cashbackCategoryId: book.cashback.id)
    let paid = Debt(direction: .iOwe, type: .loan, name: "Рассрочка", closed: true)
    book.debts = [paid]
    book.debtEntries = [
      DebtEntry(
        debtId: paid.id, date: DateOnly(year: 2026, month: 9, day: 10),
        amountE4: -AmountE4(whole: 1), kind: .payment)
    ]
    let moods = [
      WeekMood(
        week: WeekKey(containing: DateOnly(year: 2026, month: 9, day: 8)), mood: 4,
        answeredAt: Date(timeIntervalSince1970: 0))
    ]
    return summary(.month(Self.september), book, moods: moods)
  }

  @Test func withHiddenAmountsNoCardSaysMoney() {
    let made = fullSummary()
    let hidden = SummaryCards.cards(for: made, hideAmounts: true)
    #expect(hidden.count >= 5)
    for card in hidden {
      #expect(!card.showsMoney)
      for line in card.lines { #expect(!line.showsMoney) }
    }
    let shown = SummaryCards.cards(for: made, hideAmounts: false)
    #expect(shown.contains { $0.showsMoney })
    #expect(shown.map(\.id).contains("cashback"))
    #expect(!hidden.map(\.id).contains("cashback"))
  }

  @Test func hiddenCardsKeepSharesAndCategories() {
    let hidden = SummaryCards.cards(for: fullSummary(), hideAmounts: true)
    let categories = hidden.first { $0.id == "categories" }
    #expect(categories?.lines.first?.key == "summaries.line.category")
    #expect(
      categories?.lines.first?.args.contains { if case .percent = $0 { true } else { false } }
        == true)
    #expect(hidden.first { $0.id == "surprise" }?.lines.first?.key == "summaries.line.surpriseMore")
    #expect(hidden.first { $0.id == "totals" }?.lines.first?.key == "summaries.line.saved")
  }

  @Test func weekCardsHaveFiveCardsAndHideMoney() {
    var book = SummaryBook.flat { _, day, book in
      book.spend(day.weekday == 3 ? 3000 : 1000, on: day)
      return true
    }
    book.earn(5_000, on: SummaryBook.end)
    let week = WeekKey(containing: SummaryBook.end)
    let cards = WeekCards.build(week: week, ledger: book.ledger)
    #expect(cards.total.expenses == book.ledger.expenses(in: week.range))
    #expect(cards.dearestDay?.day.weekday == 3)
    #expect(cards.topCategory?.categoryId == book.food.id)
    #expect(
      cards.comparison.changeBP
        == SummaryMath.changeBP(
          cards.total.expenses.decimal, base: cards.comparison.previousExpenses.decimal))
    #expect(SummaryCards.cards(for: cards, hideAmounts: false).count == 5)
    for card in SummaryCards.cards(for: cards, hideAmounts: true) {
      #expect(!card.showsMoney)
    }
    #expect(SummaryCards.cards(for: cards, hideAmounts: false).contains { $0.showsMoney })
  }

  @Test func aQuietWeekStillMakesFiveCards() {
    var book = SummaryBook()
    book.spend(1000, on: DateOnly(year: 2026, month: 8, day: 3))
    let cards = WeekCards.build(week: WeekKey(containing: SummaryBook.end), ledger: book.ledger)
    #expect(!cards.hasData)
    #expect(cards.dearestDay == nil && cards.topCategory == nil && cards.knowYou == nil)
    #expect(SummaryCards.cards(for: cards, hideAmounts: true).count == 5)
  }
}
