import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// Random books of purchases, split purchases, refunds taken back from them — later, in
/// another month, onto another account — refunds of no purchase and income. Every section of
/// Analytics and Reports must tell the same story about my spending in every month, and the
/// turnover of the accounts only ever moves money, never makes or loses it.
@Suite("Refunds counted in their purchases, on random books")
struct RefundFoldPropertyTests {
  static let groceries = id(10)
  static let clothes = id(11)
  static let transport = id(12)
  static let bus = id(13)
  static let salary = id(31)
  static let accounts = [id(60), id(61), id(62)]
  static let places = [id(50), id(51)]
  static let categories = [
    CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
    CoreKit.Category(id: clothes, kind: .expense, name: "Clothes", quality: .bad),
    CoreKit.Category(id: transport, kind: .expense, name: "Transport", quality: .neutral),
    CoreKit.Category(
      id: bus, parentId: transport, kind: .expense, name: "Bus", quality: .good),
    CoreKit.Category(id: salary, kind: .income, name: "Salary"),
  ]
  static let months = (1...9).map { MonthKey(year: 2026, month: $0) }

  struct Book {
    var entries: [TransactionEntry] = []
    /// Σ of every purchase and of every refund, in rubles.
    var purchased = AmountE4.zero
    var refunded = AmountE4.zero
    var unlinked = 0
  }

  /// Purchases from January to June, each part refunded at most in full, a refund up to two
  /// months after its purchase; `unlinked` refunds of no purchase among them when asked for.
  static func book(seed: UInt64, withUnlinked: Bool) -> Book {
    var dice = MoneyDice(seed: seed)
    var book = Book()
    let start = CalendarContext.utc.startOfDay(day("2026-01-01"))
    var number = 0
    func next() -> Int {
      number += 1
      return number
    }
    for _ in 1...dice.int(10...40) {
      let at = start.addingTimeInterval(
        TimeInterval(dice.below(181) * 86_400 + 3_600 * dice.int(8...20)))
      let account = dice.pick(accounts)
      let place: UUID? = dice.chance(60) ? dice.pick(places) : nil
      let count = dice.chance(30) ? 2 : 1
      let purchase = id(10_000 + next())
      var parts: [TransactionPart] = []
      for _ in 0..<count {
        let amount = dice.amount(upTo: 20_000)
        parts.append(
          TransactionPart(
            id: id(20_000 + next()), transactionId: purchase,
            categoryId: dice.pick([groceries, clothes, transport, bus]), amountE4: amount))
      }
      let total = AmountE4.sum(parts.map(\.amountE4))
      book.purchased += total
      book.entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: purchase, kind: .expense, occurredAt: at, amountE4: total, placeId: place,
            paymentMethodId: account),
          parts: parts))

      for part in parts where dice.chance(45) {
        var left = part.amountE4
        for _ in 1...dice.int(1...2) where left.raw > 0 {
          let whole = dice.chance(30)
          let amount =
            whole ? left : AmountE4(raw: max(100, Int64(dice.below(Int(left.raw)) + 1) / 100 * 100))
          let taken = min(amount, left)
          left = left - taken
          let refund = id(30_000 + next())
          let when = at.addingTimeInterval(TimeInterval(dice.int(0...60) * 86_400))
          book.refunded += taken
          book.entries.append(
            TransactionEntry(
              transaction: Transaction(
                id: refund, kind: .refund, occurredAt: when, amountE4: taken, placeId: place,
                paymentMethodId: dice.chance(70) ? account : dice.pick(accounts)),
              parts: [
                TransactionPart(
                  id: id(40_000 + next()), transactionId: refund, categoryId: part.categoryId,
                  amountE4: taken, refundOfPartId: part.id)
              ]))
        }
      }
    }
    if withUnlinked {
      for _ in 1...dice.int(1...4) {
        let refund = id(50_000 + next())
        let amount = dice.amount(upTo: 5_000)
        let when = start.addingTimeInterval(TimeInterval(dice.below(200) * 86_400 + 43_200))
        book.refunded += amount
        book.unlinked += 1
        book.entries.append(
          TransactionEntry(
            transaction: Transaction(
              id: refund, kind: .refund, occurredAt: when, amountE4: amount,
              paymentMethodId: dice.pick(accounts)),
            parts: [
              TransactionPart(
                id: id(60_000 + next()), transactionId: refund,
                categoryId: dice.pick([groceries, clothes, bus]), amountE4: amount)
            ]))
      }
    }
    for month in 1...6 where dice.chance(80) {
      let salary = id(70_000 + next())
      let when = start.addingTimeInterval(TimeInterval((month - 1) * 30 * 86_400 + 43_200))
      let amount = dice.amount(upTo: 150_000)
      book.entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: salary, kind: .income, occurredAt: when, amountE4: amount,
            paymentMethodId: dice.pick(accounts)),
          parts: [
            TransactionPart(
              id: id(80_000 + next()), transactionId: salary, categoryId: Self.salary,
              amountE4: amount)
          ]))
    }
    return book
  }

  static func ledger(_ book: Book) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: book.entries, categories: categories,
        places: places.map { Place(id: $0, name: "Place") },
        paymentMethods: accounts.enumerated().map {
          PaymentMethod(id: $0.element, name: "Account \($0.offset)", isDefault: $0.offset == 0)
        }),
      calendar: .utc)
  }

  /// Every month: the account section, the category tables of every grouping, «for whom», the
  /// qualities and the monthly table all say the same my-spending figure.
  @Test(arguments: Array(1...30) as [UInt64])
  func everySectionSaysTheSameSpendingEveryMonth(seed: UInt64) {
    let ledger = Self.ledger(Self.book(seed: seed, withUnlinked: seed.isMultiple(of: 2)))
    let builder = ReportBuilder(ledger: ledger, today: day("2026-10-15"))
    let monthly = builder.table(.monthly, period: .year(2026))
    for (index, month) in Self.months.enumerated() {
      let period = Period.month(month)
      let spent = ledger.expenses(in: period.range)
      let accounts = PaymentMethodsReport(ledger: ledger, period: period)
      #expect(AmountE4.sum(accounts.methods.map(\.mySpending)) == spent, "seed \(seed), \(month)")
      for grouping in ReportGrouping.allCases {
        for kind in [ReportTable.Kind.expensesByCategory, .expensesByCategoryAndSubcategory] {
          #expect(
            builder.table(kind, period: period, grouping: grouping).total.amount == spent,
            "seed \(seed), \(month), \(kind), \(grouping)")
        }
      }
      let forWhom = ForWhomReport(ledger: ledger, period: period)
      #expect(AmountE4.sum(forWhom.values.map(\.amount)) == spent, "seed \(seed), \(month)")
      let quality = QualityReport(ledger: ledger, period: period, today: day("2026-10-15"))
      #expect(
        AmountE4.sum(quality.months.flatMap(\.qualities).map(\.amount)) == spent,
        "seed \(seed), \(month)")
      #expect(monthly.rows[index].values.first == spent, "seed \(seed), \(month)")
    }
  }

  /// With nothing but my own purchases and refunds taken back from them, an account's turnover
  /// in a month IS my spending with it: never below zero, and never a line for a refund alone.
  @Test(arguments: Array(1...30) as [UInt64])
  func anAccountsTurnoverIsMySpendingWithItWhenEveryRefundHasItsPurchase(seed: UInt64) {
    let ledger = Self.ledger(Self.book(seed: seed, withUnlinked: false))
    for month in Self.months {
      for line in PaymentMethodsReport(ledger: ledger, period: .month(month)).methods {
        #expect(line.turnover == line.mySpending, "seed \(seed), \(month), \(line.key)")
        #expect(line.turnover.raw > 0, "seed \(seed), \(month), \(line.key)")
      }
    }
  }

  /// Over the whole history the turnover only moves: Σ of it over every account is every
  /// purchase less every refund, linked or not.
  @Test(arguments: Array(1...30) as [UInt64])
  func theTurnoverOfTheWholeHistoryIsPurchasesLessRefunds(seed: UInt64) {
    let book = Self.book(seed: seed, withUnlinked: true)
    let ledger = Self.ledger(book)
    let year = PaymentMethodsReport(ledger: ledger, period: .year(2026))
    #expect(
      AmountE4.sum(year.methods.map(\.turnover)) == book.purchased - book.refunded, "seed \(seed)")
  }
}
