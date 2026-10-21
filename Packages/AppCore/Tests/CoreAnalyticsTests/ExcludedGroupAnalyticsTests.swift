import CoreAccounting
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreAnalytics

/// A group of accounts left out of the summary hides its money only — its balance from «Всего»
/// and the free sum. What is spent and earned on its accounts still counts everywhere: Overview,
/// Analytics, Reports, limits, the forecast. And money moved between accounts is never income
/// or spending, whatever the groups.
@Suite("Spending on accounts left out of the summary still counts")
struct ExcludedGroupAnalyticsTests {
  static let kzt = CurrencyCode("KZT")
  let groceries = id(10)
  let cafe = id(11)
  let salary = id(31)
  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: cafe, kind: .expense, name: "Cafe", quality: .bad),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    ]
  }
  let card = PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
  let kaspi = PaymentMethod(id: id(2), name: "Kaspi", currency: kzt, groupId: id(90))
  let freedom = PaymentMethod(
    id: id(3), name: "Freedom", currency: kzt, groupId: id(90), otherCurrencies: [.usd, .rub])
  var accounts: [PaymentMethod] { [card, kaspi, freedom] }
  let budget = Budget(id: id(70), scope: .category, categoryId: id(11), amountE4: money("20000"))

  struct Book {
    var entries: [TransactionEntry] = []
    var transfers: [Transfer] = []
  }

  /// Purchases and income in rubles, tenge and dollars on every account, over five months, and
  /// transfers between the accounts, exchanges inside Freedom included.
  func book(seed: UInt64) -> Book {
    var dice = MoneyDice(seed: seed)
    var book = Book()
    let start = CalendarContext.utc.startOfDay(day("2026-01-01"))
    for number in 1...dice.int(20...80) {
      let at = start.addingTimeInterval(TimeInterval(dice.below(150) * 86_400 + dice.below(86_400)))
      let account = dice.pick(accounts)
      let currency = dice.pick(account.currencies)
      let rate: Decimal? =
        currency == .rub ? nil : currency == .usd ? 90 : Decimal(dice.int(15...25)) / 100
      let income = dice.chance(20)
      let amount = currency == Self.kzt ? dice.amount(upTo: 60_000) : dice.amount(upTo: 9_000)
      let rub = rate.map { (try? AmountE4(decimal: amount.decimal * $0)) ?? amount } ?? amount
      book.entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id(1000 + number), kind: income ? .income : .expense, occurredAt: at,
            currency: currency, amountE4: amount, rate: rate, amountRubE4: rub,
            paymentMethodId: account.id, createdAt: at, updatedAt: at),
          parts: [
            TransactionPart(
              id: id(10_000 + number), transactionId: id(1000 + number),
              categoryId: income ? salary : dice.pick([groceries, cafe]), amountE4: amount,
              amountRubE4: rub)
          ]))
    }
    for number in 1...dice.int(1...15) {
      let at = start.addingTimeInterval(TimeInterval(dice.below(150) * 86_400))
      let from = dice.pick(accounts)
      let to = dice.chance(30) ? freedom : dice.pick(accounts)
      let fromCurrency = dice.pick(from.currencies)
      let toCurrency = dice.pick(to.currencies)
      let sent = dice.amount(upTo: 50_000)
      book.transfers.append(
        Transfer(
          id: id(5000 + number), occurredAt: at, fromAccountId: from.id, fromCurrency: fromCurrency,
          fromAmountE4: sent, toAccountId: to.id, toCurrency: toCurrency,
          toAmountE4: fromCurrency == toCurrency ? sent : dice.amount(upTo: 50_000),
          createdAt: at, updatedAt: at))
    }
    return book
  }

  func ledger(_ book: Book, inSummary: Bool, transfers: Bool = true) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: book.entries, categories: categories, paymentMethods: accounts,
        transfers: transfers ? book.transfers : [],
        accountGroups: [AccountGroup(id: id(90), name: "Kazakhstan", inSummary: inSummary)]),
      calendar: .utc)
  }

  /// What every screen shows of the money spent and earned, month by month and over the period.
  func figures(_ ledger: Ledger) -> [String] {
    let months = (0..<6).map { MonthKey(year: 2026, month: 1).adding(months: $0) }
    let period = Period.days(DayRange(day("2026-01-01"), day("2026-06-30")))
    let reports = ReportBuilder(ledger: ledger, today: day("2026-05-20"))
    var result: [String] = []
    for month in months {
      let range = Period.month(month).range
      result.append(
        "\(month) spent \(ledger.expenses(in: range)) earned \(ledger.income(in: .month(month)))")
      result.append("\(month) limit \(LimitRules.spent(of: budget, in: month, ledger: ledger))")
    }
    result.append("\(CategoryBreakdown(ledger: ledger, period: period, kind: .expense))")
    result.append("\(CategoryBreakdown(ledger: ledger, period: period, kind: .income))")
    for kind in ReportTable.Kind.allCases {
      result.append("\(reports.table(kind, period: period))")
    }
    result.append("\(PaymentMethodsReport(ledger: ledger, period: period))")
    result.append("\(QualityReport(ledger: ledger, period: period, today: day("2026-05-20")))")
    result.append("\(OverviewSummary(ledger: ledger, today: day("2026-05-20")))")
    result.append("\(MonthForecast.remainder(ledger: ledger, today: day("2026-05-20")))")
    return result
  }

  /// Taking the Kazakh group out of the summary changes no figure of spending or income, and
  /// neither does any transfer between the accounts: the screens show the same numbers either
  /// way.
  @Test(arguments: Array(1...25) as [UInt64])
  func theSummaryAndTransfersChangeNoSpendingOrIncome(seed: UInt64) {
    let book = book(seed: seed)
    let apart = figures(ledger(book, inSummary: false))
    #expect(apart == figures(ledger(book, inSummary: true)), "seed \(seed)")
    #expect(apart == figures(ledger(book, inSummary: false, transfers: false)), "seed \(seed)")
  }

  /// And the spending on the accounts apart is in the figures, not merely equal to nothing on both
  /// sides: every month spends the rubles of every purchase of the month and earns every income,
  /// Kaspi and Freedom included, and the accounts report names them with their spending.
  @Test(arguments: Array(1...25) as [UInt64])
  func theAccountsApartSpendAndEarnInEveryFigure(seed: UInt64) {
    let book = book(seed: seed)
    let ledger = ledger(book, inSummary: false)
    for month in (0..<6).map({ MonthKey(year: 2026, month: 1).adding(months: $0) }) {
      let of = book.entries.filter {
        CalendarContext.utc.day(of: $0.transaction.occurredAt).monthKey == month
      }
      let spent = AmountE4.sum(
        of.filter { $0.transaction.kind == .expense }.map(\.transaction.amountRubE4))
      let earned = AmountE4.sum(
        of.filter { $0.transaction.kind == .income }.map(\.transaction.amountRubE4))
      #expect(ledger.expenses(in: Period.month(month).range) == spent, "seed \(seed), \(month)")
      #expect(ledger.income(in: .month(month)) == earned, "seed \(seed), \(month)")
      let cafe = AmountE4.sum(
        of.filter { $0.transaction.kind == .expense && $0.parts[0].categoryId == self.cafe }
          .map(\.transaction.amountRubE4))
      #expect(LimitRules.spent(of: budget, in: month, ledger: ledger) == cafe, "seed \(seed)")
    }
    let methods = PaymentMethodsReport(
      ledger: ledger, period: .days(DayRange(day("2026-01-01"), day("2026-06-30")))
    ).methods
    for account in [kaspi, freedom] {
      let spent = AmountE4.sum(
        book.entries.filter {
          $0.transaction.kind == .expense && $0.transaction.paymentMethodId == account.id
        }.map(\.transaction.amountRubE4))
      let line = methods.first { $0.key == .paymentMethod(account.id) }
      #expect((line?.mySpending ?? .zero) == spent, "seed \(seed), \(account.name)")
    }
  }
}
