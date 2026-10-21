import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// The rule of a match in the corners: the price of the due date's own day decides the
/// tolerance, the whole operation is compared though one part is enough for the category, an
/// operation the app wrote for something else never pays a payment, and a dollar subscription
/// typed in rubles is compared in rubles at the rate of the operation's day.
@Suite("Paying a scheduled payment by an ordinary operation: the corners of the rule")
struct ScheduledMatchingRuleTests {
  typealias Fx = CashFx

  func matches(_ fx: CashFx, dayRates: DayRates = .empty) -> ScheduledMatches {
    ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: Fx.today, rejections: [], dayRates: dayRates,
      rubPerUnit: fx.rubPerUnit)
  }

  /// A gym of 1 000 on the 15th, 1 500 from 15 September. 1 480 on 16 August pays nothing — the
  /// price of August's due was 1 000; 1 050 on 14 September would have paid the old price and
  /// pays nothing now; 1 480 on 14 September pays September's.
  @Test func theToleranceIsThePriceOfTheDueDatesDay() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Gym", "1000", day: 15, next: "2026-08-15")]
    fx.prices = [
      SubscriptionPrice(paymentId: Fx.id(1), date: Fx.day("2026-09-15"), amountE4: Fx.money("1500"))
    ]
    let august = fx.add(.expense, "1480", at: Fx.at("2026-08-16", 10), category: Fx.housing)
    var found = matches(fx)
    #expect(found.operation(for: Fx.id(1), Fx.day("2026-08-15")) == nil)
    #expect(found.operation(for: Fx.id(1), Fx.day("2026-09-15")) == nil)

    fx.entries.removeAll { $0.id == august }
    let old = fx.add(.expense, "1050", at: Fx.at("2026-09-14", 10), category: Fx.housing)
    found = matches(fx)
    #expect(found.operation(for: Fx.id(1), Fx.day("2026-09-15")) == nil)
    fx.entries.removeAll { $0.id == old }
    let new = fx.add(.expense, "1480", at: Fx.at("2026-09-14", 10), category: Fx.housing)
    found = matches(fx)
    #expect(found.operation(for: Fx.id(1), Fx.day("2026-09-15")) == new)
  }

  /// One operation of 1 000 split into 700 of Housing and 300 of Fun pays the rent of 1 000:
  /// one part in the category is enough, and the whole operation is the payment. One of 1 500 —
  /// 1 000 of Housing and 500 of Groceries — pays nothing: the whole is compared.
  @Test func aSplitOperationIsComparedWhole() {
    func split(_ parts: [(UUID, String)]) -> CashFx {
      var fx = Fx()
      fx.scheduled = [Fx.payment(1, "Rent", "1000", day: 15, next: "2026-09-15")]
      let total = parts.reduce(Decimal(0)) { $0 + (Decimal(string: $1.1) ?? 0) }
      let id = fx.add(.expense, "\(total)", at: Fx.at("2026-09-15", 10), category: Fx.housing)
      if let index = fx.entries.firstIndex(where: { $0.id == id }) {
        let template = fx.entries[index].parts[0]
        fx.entries[index].parts = parts.enumerated().map { number, part in
          var copy = template
          copy.id = Fx.id(95_000 + number)
          copy.categoryId = part.0
          copy.amountE4 = Fx.money(part.1)
          copy.amountRubE4 = Fx.money(part.1)
          return copy
        }
      }
      return fx
    }
    let pays = split([(Fx.housing, "700"), (Fx.fun, "300")])
    #expect(matches(pays).isPaid(Fx.id(1), Fx.day("2026-09-15")))
    let tooMuch = split([(Fx.housing, "1000"), (Fx.groceries, "500")])
    #expect(!matches(tooMuch).isPaid(Fx.id(1), Fx.day("2026-09-15")))
  }

  /// Operations the app wrote for something else — the fee of a transfer, a shortfall of money
  /// back, «Провести» of another payment, the difference of a count — never pay a payment,
  /// however well they fit; nor does a refund, an income or a deleted expense.
  @Test func anOperationWrittenForSomethingElsePaysNothing() {
    let links: [OperationLink] = [
      .transferFee(Fx.id(801)), .shortfall(reimbursement: "r", part: "p"),
      .scheduled(paymentId: Fx.id(2), due: Fx.day("2026-09-15")),
      .reconciledBalance(reconciliation: Fx.id(802), balance: Fx.id(803)),
    ]
    for link in links {
      var fx = Fx()
      fx.scheduled = [Fx.payment(1, "Rent", "1000", day: 15, next: "2026-09-15")]
      fx.add(.expense, "1000", at: Fx.at("2026-09-15", 10), category: Fx.housing, link: link)
      #expect(!matches(fx).isPaid(Fx.id(1), Fx.day("2026-09-15")), "\(link)")
    }
    for kind in [TransactionKind.refund, .income] {
      var fx = Fx()
      fx.scheduled = [Fx.payment(1, "Rent", "1000", day: 15, next: "2026-09-15")]
      fx.add(kind, "1000", at: Fx.at("2026-09-15", 10), category: Fx.housing)
      #expect(!matches(fx).isPaid(Fx.id(1), Fx.day("2026-09-15")), "\(kind)")
    }
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "1000", day: 15, next: "2026-09-15")]
    fx.add(.expense, "1000", at: Fx.at("2026-09-15", 10), category: Fx.housing)
    fx.entries[0].transaction.deletedAt = Fx.now
    #expect(!matches(fx).isPaid(Fx.id(1), Fx.day("2026-09-15")))
  }

  /// A dollar subscription of the 10th, dollar rates on some days only, and at most one
  /// operation in rubles typed near each due date — the bank's message at the day's rate, a
  /// little more or less; with the due dates it pays by the plain rule.
  static func dollarBook(seed: UInt64) -> (fx: CashFx, rates: DayRates, model: [DateOnly: UUID]) {
    var random = SeededRandom(seed: seed &* 41 &+ 5)
    var fx = Fx()
    let price = AmountE4(raw: Int64(random.int(in: 100...5_000)) * 100)
    var payment = Fx.payment(
      1, "Cloud", price.decimal.description, day: 10, next: "2026-05-10", currency: .usd)
    payment.kind = .subscription
    fx.scheduled = [payment]
    var series: [DayRate] = []
    for offset in stride(from: 0, through: 150, by: random.int(in: 1...4)) {
      series.append(
        DayRate(
          day: Fx.day("2026-05-01").adding(days: offset),
          perUnit: Decimal(random.int(in: 8_000...10_000)) / 100))
    }
    func rate(on day: DateOnly) -> Decimal {
      series.last { $0.day <= day }?.perUnit ?? series[0].perUnit
    }
    var model: [DateOnly: UUID] = [:]
    for month in 5...9 {
      let due = DateOnly(year: 2026, month: month, day: 10)
      guard random.chance(3, outOf: 4) else { continue }
      let day = min(Fx.today, due.adding(days: random.int(in: -7...7)))
      let priceRub = SubscriptionMath.rounded(price.decimal * rate(on: day))
      let typed = SubscriptionMath.rounded(
        priceRub.decimal * Decimal(100 + random.int(in: -15...15)) / 100)
      let id = fx.add(
        .expense, typed.decimal.description, at: Fx.at(day.iso, 11), category: Fx.housing)
      let tolerance = max(AmountE4(whole: 1), SubscriptionMath.rounded(priceRub.decimal / 10))
      if abs(day.days(to: due)) <= 5, (typed - priceRub).magnitude <= tolerance {
        model[due] = id
      }
    }
    return (fx, DayRates(series: [.usd: series]), model)
  }

  /// Such an operation pays its due date exactly when its rubles are within max(1 ₽, 10 %) of
  /// the price at the rate of the operation's own day (the latest rate on or before it) and it
  /// is within five days of the due date, not after today.
  @Test(arguments: Array(UInt64(1)...40))
  func aDollarSubscriptionTypedInRublesIsComparedInRubles(_ seed: UInt64) {
    let book = Self.dollarBook(seed: seed)
    let found = matches(book.fx, dayRates: book.rates)
    #expect(found.matchedDues(of: Fx.id(1)) == book.model, "seed \(seed)")
  }

  /// The dollar books reach both sides: operations that pay and operations that do not.
  @Test func theDollarBooksReachBothSides() {
    var paying = 0
    var typed = 0
    for seed in UInt64(1)...40 {
      let book = Self.dollarBook(seed: seed)
      paying += book.model.count
      typed += book.fx.entries.count
    }
    #expect(paying >= 30)
    #expect(typed - paying >= 30)
  }
}
