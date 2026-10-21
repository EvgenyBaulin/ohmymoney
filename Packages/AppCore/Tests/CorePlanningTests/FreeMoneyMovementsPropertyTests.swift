import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// The money now on random books of every movement a balance knows — not only operations in
/// the account's own currencies and transfers, but money charged to an account in another
/// currency («Списано со счёта»), money back from a person, a purchase refunded, money borrowed
/// or lent through a debt's journal alone — against a model of each movement written out
/// plainly. What moves no money — a payment written on a debt's card, money put into a goal
/// from any account — never shows.
@Suite("The money now: every kind of movement against a plain model")
struct FreeMoneyMovementsPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...25)
  static let count = CashFx.at("2026-09-01", 10)
  static let mainRub = BalanceKey(accountId: CashFx.main, currency: .rub)
  static let cardRub = BalanceKey(accountId: CashFx.card, currency: .rub)
  static let cardUsd = BalanceKey(accountId: CashFx.card, currency: .usd)
  static let freedomKzt = BalanceKey(accountId: CashFx.freedom, currency: CashFx.tenge)
  static let inSummary = [mainRub, cardRub, cardUsd]

  static let loan = Debt(
    id: CashFx.id(311), direction: .iOwe, type: .loan, name: "Loan from a friend")
  static let lent = Debt(
    id: CashFx.id(312), direction: .owedToMe, type: .loan, name: "Lent to a friend")

  struct Book {
    var fx = CashFx()
    var counted: [BalanceKey: AmountE4] = [:]
    /// Signed movements in the key's currency, by moment.
    var moves: [(key: BalanceKey, at: Date, amount: AmountE4)] = []
    /// What happened, by kind, to see that the books reach every kind.
    var kinds: [String: Int] = [:]
    private var number = 80_000

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      func amount(_ most: Int) -> AmountE4 {
        AmountE4(raw: Int64(random.int(in: 1...(most * 100))) * 100)
      }
      var balances: [(UUID, CurrencyCode, String)] = []
      for key in FreeMoneyMovementsPropertyTests.inSummary + [
        FreeMoneyMovementsPropertyTests
          .freedomKzt
      ] {
        let value = AmountE4(raw: Int64(random.int(in: 0...50_000_000)) * 100)
        counted[key] = value
        balances.append((key.accountId, key.currency, value.decimal.description))
      }
      fx.count(balances, at: FreeMoneyMovementsPropertyTests.count)
      fx.debts = [FreeMoneyMovementsPropertyTests.loan, FreeMoneyMovementsPropertyTests.lent]

      let start = CashFx.at("2026-08-25", 0)
      let span = Int(CashFx.now.timeIntervalSince(start) / 60)
      for _ in 0..<random.int(in: 10...40) {
        let at = start.addingTimeInterval(TimeInterval(random.int(in: 0...span) * 60))
        switch random.int(in: 0...8) {
        case 0:
          // Dollars or euros spent from Main, which holds rubles only: the bank charged rubles.
          let charged = amount(20_000)
          let currency: CurrencyCode = random.chance(1, outOf: 2) ? .usd : .eur
          add(
            .expense, amount(200), currency, at: at, account: CashFx.main,
            charged: (.rub, charged))
          moves.append((FreeMoneyMovementsPropertyTests.mainRub, at, -charged))
          kinds["charged", default: 0] += 1
        case 1:
          // Euros spent from Card, which holds rubles and dollars: charged in its first, rubles.
          let charged = amount(20_000)
          add(.expense, amount(200), .eur, at: at, account: CashFx.card, charged: (.rub, charged))
          moves.append((FreeMoneyMovementsPropertyTests.cardRub, at, -charged))
          kinds["charged", default: 0] += 1
        case 2:
          // Money back from a person, onto Main or Card, in a currency the account holds.
          let key = random.choice(from: FreeMoneyMovementsPropertyTests.inSummary)
          let value = amount(5_000)
          add(.reimbursement, value, key.currency, at: at, account: key.accountId)
          moves.append((key, at, value))
          kinds["money back", default: 0] += 1
        case 3:
          // A purchase and, a little later, some or all of it refunded onto the same account:
          // the refund moves the money at its own moment.
          let key = random.choice(from: FreeMoneyMovementsPropertyTests.inSummary)
          let price = amount(10_000)
          let part = add(.expense, price, key.currency, at: at, account: key.accountId)
          moves.append((key, at, -price))
          let back = AmountE4(raw: max(100, price.raw * Int64(random.int(in: 10...100)) / 100))
          let later = at.addingTimeInterval(TimeInterval(random.int(in: 1...20_000) * 60))
          add(.refund, back, key.currency, at: later, account: key.accountId, refundOf: part)
          moves.append((key, later, back))
          kinds["refund", default: 0] += 1
        case 4:
          // Money borrowed or lent through the journal alone, dated a day or a moment.
          let borrowed = random.chance(1, outOf: 2)
          let key = random.choice(from: [
            FreeMoneyMovementsPropertyTests.mainRub, FreeMoneyMovementsPropertyTests.cardRub,
          ])
          let value = amount(30_000)
          let day = CalendarContext.utc.day(of: at)
          let dated = random.chance(1, outOf: 2)
          fx.debtEntries.append(
            DebtEntry(
              id: next(),
              debtId: borrowed
                ? FreeMoneyMovementsPropertyTests.loan.id : FreeMoneyMovementsPropertyTests.lent.id,
              date: day, amountE4: value, kind: .borrowed, paymentMethodId: key.accountId,
              occurredAt: dated ? nil : at))
          let moment = dated ? CalendarContext.utc.startOfDay(day) : at
          moves.append((key, moment, borrowed ? value : -value))
          kinds["journal", default: 0] += 1
        case 5:
          // A payment written on the debt's card alone moves no money.
          fx.debtEntries.append(
            DebtEntry(
              id: next(), debtId: FreeMoneyMovementsPropertyTests.loan.id,
              date: CalendarContext.utc.day(of: at), amountE4: -amount(1_000), kind: .payment,
              paymentMethodId: CashFx.main))
          kinds["card payment", default: 0] += 1
        case 6:
          // Money into a goal — from Main or from Freedom — stays on the account.
          let fromFreedom = random.chance(1, outOf: 2)
          fx.add(
            .expense, amount(5_000).decimal.description, at: at,
            currency: fromFreedom ? CashFx.tenge : .rub,
            account: fromFreedom ? CashFx.freedom : CashFx.main, category: CashFx.tripGoal,
            goal: CashFx.id(401))
          kinds["goal", default: 0] += 1
        case 7:
          // Kazakhstan's own spending: its total, not the summary's.
          let value = amount(50_000)
          add(.expense, value, CashFx.tenge, at: at, account: CashFx.freedom)
          moves.append((FreeMoneyMovementsPropertyTests.freedomKzt, at, -value))
          kinds["kazakhstan", default: 0] += 1
        default:
          let key = random.choice(from: FreeMoneyMovementsPropertyTests.inSummary)
          let value = amount(20_000)
          add(.expense, value, key.currency, at: at, account: key.accountId)
          moves.append((key, at, -value))
          kinds["plain", default: 0] += 1
        }
      }
      fx.goals = [
        Goal(
          id: CashFx.id(401), name: "Trip", targetE4: CashFx.money("1000000"),
          subcategoryId: CashFx.tripGoal)
      ]
      fx.settings.reserveGoalPlan = false
    }

    private mutating func next() -> UUID {
      number += 1
      return CashFx.id(number)
    }

    /// One operation of one part, written out in full; returns the id of its part.
    @discardableResult
    private mutating func add(
      _ kind: TransactionKind, _ amount: AmountE4, _ currency: CurrencyCode, at: Date,
      account: UUID, charged: (CurrencyCode, AmountE4)? = nil, refundOf: UUID? = nil
    ) -> UUID {
      let id = next()
      let partId = next()
      let rubles =
        currency == .rub
        ? amount : SubscriptionMath.rounded(amount.decimal * (fx.rubPerUnit[currency] ?? 100))
      let category: UUID? =
        switch kind {
        case .expense, .refund: CashFx.groceries
        case .income: CashFx.salary
        default: nil
        }
      fx.entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id, kind: kind, occurredAt: at, currency: currency, amountE4: amount,
            amountRubE4: rubles, paymentMethodId: account, accountCurrency: charged?.0,
            accountAmountE4: charged?.1, createdAt: at, updatedAt: at),
          parts: [
            TransactionPart(
              id: partId, transactionId: id, categoryId: category,
              quality: kind == .expense ? .neutral : nil,
              qualitySource: kind == .expense ? .category : nil, amountE4: amount,
              amountRubE4: rubles, refundOfPartId: refundOf)
          ]))
      return partId
    }

    /// The count plus every movement after it, by now.
    func expected(_ key: BalanceKey) -> AmountE4 {
      (counted[key] ?? .zero)
        + AmountE4.sum(
          moves.filter {
            $0.key == key && $0.at > FreeMoneyMovementsPropertyTests.count && $0.at <= CashFx.now
          }.map(\.amount))
    }
  }

  /// The money now is Σ over the balances of the summary of (count + what moved since), each at
  /// today's rate; Kazakhstan has its own total; every balance of the book is the model's.
  @Test(arguments: seeds)
  func theMoneyNowKnowsEveryKindOfMovement(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.fx.snapshot()
    for key in Self.inSummary + [Self.freedomKzt] {
      #expect(
        snapshot.accounts.balances[key]?.amountE4 == book.expected(key), "seed \(seed), \(key)")
    }
    let model = AmountE4.sum(
      Self.inSummary.compactMap {
        SubscriptionMath.rubles(
          book.expected($0), in: $0.currency, rubPerUnit: book.fx.rubPerUnit)
      })
    #expect(snapshot.freeMoney.moneyNow == model, "seed \(seed)")
    // What can be spent now is the money now less what the goals hold.
    #expect(
      snapshot.freeMoney.main == model - snapshot.freeMoney.goalSavings, "seed \(seed)")
    #expect(
      snapshot.freeMoney.excluded.first?.totalRub
        == SubscriptionMath.rubles(
          book.expected(Self.freedomKzt), in: Fx.tenge, rubPerUnit: book.fx.rubPerUnit),
      "seed \(seed)")
    // Nothing moved in a currency an account does not hold: a charge in another currency
    // always lands on one it holds.
    #expect(snapshot.freeMoney.unanchored.isEmpty, "seed \(seed)")
  }

  /// Right after a count of every balance the money now is the count itself, whatever moved
  /// before it.
  @Test(arguments: seeds)
  func rightAfterACountTheMoneyNowIsTheCount(_ seed: UInt64) {
    var book = Book(seed: seed)
    var random = SeededRandom(seed: seed &* 3)
    var counts: [(UUID, CurrencyCode, String)] = []
    var total = AmountE4.zero
    for key in Self.inSummary {
      let value = AmountE4(raw: Int64(random.int(in: 0...9_000_000)) * 100)
      counts.append((key.accountId, key.currency, value.decimal.description))
      total +=
        SubscriptionMath.rubles(value, in: key.currency, rubPerUnit: book.fx.rubPerUnit)
        ?? .zero
    }
    book.fx.count(counts, at: Fx.now)
    #expect(book.fx.snapshot().freeMoney.moneyNow == total, "seed \(seed)")
  }

  /// The random books reach every kind of movement.
  @Test func theBooksReachEveryKind() {
    var kinds: [String: Int] = [:]
    for seed in Self.seeds {
      for (kind, count) in Book(seed: seed).kinds { kinds[kind, default: 0] += count }
    }
    for kind in [
      "charged", "money back", "refund", "journal", "card payment", "goal", "kazakhstan", "plain",
    ] {
      #expect((kinds[kind] ?? 0) >= 5, "\(kind)")
    }
  }
}
