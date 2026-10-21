import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// Random books checked against a model of the rule simple enough to trust by reading it:
/// the balance of an (account, currency) at a moment is its latest count by then plus every
/// movement after the count and by that moment, in its own currency — nothing converted.
@Suite("Reconciliation by account and currency: random books against a plain model")
struct ReconciliationPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233]

  static let mainRub = BalanceKey(accountId: CashFx.main, currency: .rub)
  static let cardRub = BalanceKey(accountId: CashFx.card, currency: .rub)
  static let cardUsd = BalanceKey(accountId: CashFx.card, currency: .usd)
  static let freedomKzt = BalanceKey(accountId: CashFx.freedom, currency: CashFx.tenge)
  static let keys = [mainRub, cardRub, cardUsd, freedomKzt]

  /// The first count, the second one and the moment the snapshot looks from.
  static let firstCount = CashFx.at("2026-09-01", 10)
  static let secondCount = CashFx.at("2026-09-19", 14, 5)

  /// One movement the model knows: signed, in the key's currency.
  struct Move {
    var key: BalanceKey
    var at: Date
    var amount: AmountE4
  }

  /// A random book: every key counted at `firstCount`, then operations and transfers around
  /// it — some before it (inside the count), most after it, a few after `secondCount` — and
  /// money put into a goal, which moves nothing.
  struct Scenario {
    var fx = CashFx()
    var counted: [BalanceKey: AmountE4] = [:]
    var moves: [Move] = []

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      func amount(max whole: Int) -> AmountE4 {
        AmountE4(raw: Int64(random.int(in: 1...(whole * 100))) * 100)
      }
      var balances: [(UUID, CurrencyCode, String)] = []
      for key in ReconciliationPropertyTests.keys {
        let value = AmountE4(raw: Int64(random.int(in: 0...50_000_000)) * 100)
        counted[key] = value
        balances.append((key.accountId, key.currency, value.decimal.description))
      }
      fx.count(balances, at: ReconciliationPropertyTests.firstCount)

      let start = CashFx.at("2026-08-25", 0)
      let end = CashFx.at("2026-09-19", 15)
      let span = Int(end.timeIntervalSince(start) / 60)
      for _ in 0..<random.int(in: 5...40) {
        let at = start.addingTimeInterval(TimeInterval(random.int(in: 0...span) * 60))
        let key = random.choice(from: ReconciliationPropertyTests.keys)
        switch random.int(in: 0...9) {
        case 0...4:
          let value = amount(max: 20_000)
          fx.add(
            .expense, value.decimal.description, at: at, currency: key.currency,
            account: key.accountId)
          moves.append(Move(key: key, at: at, amount: -value))
        case 5...6:
          let value = amount(max: 50_000)
          fx.add(
            .income, value.decimal.description, at: at, currency: key.currency,
            account: key.accountId, category: CashFx.salary)
          moves.append(Move(key: key, at: at, amount: value))
        case 7:
          // Money into a goal stays on the account: no movement.
          fx.add(
            .expense, amount(max: 5_000).decimal.description, at: at, currency: key.currency,
            account: key.accountId, category: CashFx.tripGoal, goal: CashFx.id(401))
        default:
          var to = random.choice(from: ReconciliationPropertyTests.keys)
          while to == key { to = random.choice(from: ReconciliationPropertyTests.keys) }
          let sent = amount(max: 10_000)
          let received = key.currency == to.currency ? sent : amount(max: 10_000)
          fx.transfers.append(
            Transfer(
              occurredAt: at, fromAccountId: key.accountId, fromCurrency: key.currency,
              fromAmountE4: sent, toAccountId: to.accountId, toCurrency: to.currency,
              toAmountE4: received))
          moves.append(Move(key: key, at: at, amount: -sent))
          moves.append(Move(key: to, at: at, amount: received))
        }
      }
    }

    /// The model: the first count plus what moved after it and by `moment`.
    func expected(_ key: BalanceKey, at moment: Date) -> AmountE4 {
      (counted[key] ?? .zero)
        + AmountE4.sum(
          moves.filter {
            $0.key == key && $0.at > ReconciliationPropertyTests.firstCount && $0.at <= moment
          }.map(\.amount))
    }

    func balances(now: Date) -> AccountBalances {
      let dataset = fx.ledger.dataset
      return AccountBalances.build(
        entries: dataset.entries, transfers: dataset.transfers,
        debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
        reconciliations: dataset.planning.reconciliations,
        balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
        tree: CategoryTree(dataset.categories), now: now, calendar: .utc)
    }
  }

  /// A sequence of ids, the same on every run.
  final class Ids {
    private var next = 70_000
    func make() -> UUID {
      next += 1
      return CashFx.id(next)
    }
  }

  // MARK: - The rows

  /// Every row of the sheet expects the model's balance at the moment of the sheet: the count
  /// plus what moved after it, never what moved before it (it is inside the count) and never
  /// what is dated after the sheet.
  @Test(arguments: seeds)
  func theSheetExpectsTheCountPlusWhatMovedSince(_ seed: UInt64) {
    let scenario = Scenario(seed: seed)
    let rows = AccountReconciliation.rows(
      accounts: scenario.fx.accounts, groups: scenario.fx.groups,
      balances: scenario.balances(now: Fx.now), at: Self.secondCount,
      locale: Locale(identifier: "en"))
    #expect(rows.map(\.key) == Self.keys, "seed \(seed)")
    for row in rows {
      #expect(
        row.expected == scenario.expected(row.key, at: Self.secondCount),
        "seed \(seed), \(row.key)")
      #expect(row.lastCountedAt == Self.firstCount)
    }
  }

  // MARK: - Recording

  /// Whatever is counted, each row's difference is counted − expected in the row's own
  /// currency; «Записать разницу» writes exactly one operation per non-zero difference — an
  /// expense of the gap when money is missing, an income when there is more — on that
  /// account, in that currency, at the moment of the sheet; right after it the money of the
  /// summary is the count at today's rates, exactly.
  @Test(arguments: seeds)
  func theDifferenceIsInTheRowsCurrencyAndTheCountBecomesTheMoney(_ seed: UInt64) {
    var scenario = Scenario(seed: seed)
    var random = SeededRandom(seed: seed &+ 1_000)
    let rows = AccountReconciliation.rows(
      accounts: scenario.fx.accounts, groups: scenario.fx.groups,
      balances: scenario.balances(now: Fx.now), at: Self.secondCount,
      locale: Locale(identifier: "en"))
    var counted: [BalanceKey: AmountE4] = [:]
    for key in Self.keys {
      let expected = scenario.expected(key, at: Self.secondCount)
      // A third of the rows are right, the rest are off by up to 5 000 either way; zero is a
      // count like any other.
      switch random.int(in: 0...5) {
      case 0...1: counted[key] = expected
      case 2: counted[key] = .zero
      default:
        counted[key] = expected + AmountE4(raw: Int64(random.int(in: -500_000...500_000)) * 100)
      }
    }
    let record = AccountReconciliation.record(
      counted: counted, rows: rows, writeDifference: true, kind: .accounts,
      at: Self.secondCount, calendar: .utc, tree: CategoryTree(Fx.categories),
      categories: (Fx.id(801), Fx.id(802)), rubPerUnit: scenario.fx.rubPerUnit,
      makeId: Ids().make)

    #expect(record.balances.count == Self.keys.count)
    var operations = 0
    for balance in record.balances {
      let expected = scenario.expected(balance.key, at: Self.secondCount)
      let actual = counted[balance.key] ?? .zero
      #expect(balance.actualE4 == actual)
      #expect(balance.expectedE4 == expected)
      #expect(balance.differenceE4 == actual - expected, "seed \(seed), \(balance.key)")
      guard actual != expected else {
        #expect(balance.transactionId == nil)
        continue
      }
      operations += 1
      let operation = record.differences.first { $0.id == balance.transactionId }
      #expect(operation?.transaction.kind == (actual < expected ? .expense : .income))
      #expect(operation?.transaction.amountE4 == (actual - expected).magnitude)
      #expect(operation?.transaction.currency == balance.key.currency)
      #expect(operation?.transaction.paymentMethodId == balance.key.accountId)
      #expect(operation?.transaction.occurredAt == Self.secondCount)
    }
    #expect(record.differences.count == operations)

    scenario.fx.reconciliations.append(record.reconciliation)
    scenario.fx.counts += record.balances
    scenario.fx.entries += record.differences
    let right = Self.secondCount.addingTimeInterval(60)
    let after = AccountsSnapshot.build(
      dataset: scenario.fx.ledger.dataset, now: right, calendar: .utc,
      rubPerUnit: scenario.fx.rubPerUnit, localeIdentifier: "en")
    for key in Self.keys {
      #expect(after.balances[key]?.amountE4 == counted[key], "seed \(seed), \(key)")
    }
    let inSummary = [Self.mainRub, Self.cardRub, Self.cardUsd]
    let model = AmountE4.sum(
      inSummary.compactMap { key in
        counted[key].flatMap {
          SubscriptionMath.rubles($0, in: key.currency, rubPerUnit: scenario.fx.rubPerUnit)
        }
      })
    #expect(after.inSummaryTotalRub == model, "seed \(seed)")
  }

  /// A rate that moved between two counts is never a difference: counted exactly what the
  /// books expect, every row compares to zero at any rate of the day, and the operations of a
  /// real difference carry the same amount in the row's currency — only their rubles follow
  /// the rate.
  @Test(arguments: seeds)
  func aRateThatMovedIsNeverADifference(_ seed: UInt64) {
    let scenario = Scenario(seed: seed)
    let rows = AccountReconciliation.rows(
      accounts: scenario.fx.accounts, groups: scenario.fx.groups,
      balances: scenario.balances(now: Fx.now), at: Self.secondCount,
      locale: Locale(identifier: "en"))
    var exact: [BalanceKey: AmountE4] = [:]
    for key in Self.keys { exact[key] = scenario.expected(key, at: Self.secondCount) }
    var off = exact
    off[Self.cardUsd] = (exact[Self.cardUsd] ?? .zero) - Fx.money("12.5")
    let low: [CurrencyCode: Decimal] = [.usd: 70, Fx.tenge: Decimal(string: "0.15") ?? 0]
    let high: [CurrencyCode: Decimal] = [.usd: 110, Fx.tenge: Decimal(string: "0.25") ?? 0]
    for rates in [low, high] {
      let same = AccountReconciliation.record(
        counted: exact, rows: rows, writeDifference: true, kind: .accounts,
        at: Self.secondCount, calendar: .utc, tree: CategoryTree(Fx.categories),
        categories: (Fx.id(801), Fx.id(802)), rubPerUnit: rates, makeId: Ids().make)
      #expect(same.balances.allSatisfy { $0.differenceE4 == .zero }, "seed \(seed)")
      #expect(same.differences.isEmpty)

      let short = AccountReconciliation.record(
        counted: off, rows: rows, writeDifference: true, kind: .accounts,
        at: Self.secondCount, calendar: .utc, tree: CategoryTree(Fx.categories),
        categories: (Fx.id(801), Fx.id(802)), rubPerUnit: rates, makeId: Ids().make)
      #expect(short.differences.map(\.transaction.amountE4) == [Fx.money("12.5")])
      #expect(short.differences.map(\.transaction.currency) == [.usd])
      let rubles = SubscriptionMath.rounded(Fx.money("12.5").decimal * (rates[.usd] ?? 0))
      #expect(short.differences.map(\.transaction.amountRubE4) == [rubles])
    }
  }

  // MARK: - The first count

  /// The first count of a balance is its starting point: nothing is compared, nothing is
  /// written, whatever was typed — and the reconciliation's expected rubles leave it out.
  @Test(arguments: seeds)
  func theFirstCountOfABalanceIsItsStartingPoint(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    var fx = Fx()
    // Only the main account was counted before; the card and Freedom never were.
    fx.count([(Fx.main, .rub, "1000")], at: Self.firstCount)
    fx.add(.expense, "250", at: Fx.at("2026-09-05", 12), currency: .usd, account: Fx.card)
    let built = Scenario.balances(fx, now: Fx.now)
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: built, at: Self.secondCount,
      locale: Locale(identifier: "en"))
    let fresh = rows.filter { $0.key != Self.mainRub }
    #expect(fresh.allSatisfy { $0.expected == nil && $0.lastCountedAt == nil })
    var counted: [BalanceKey: AmountE4] = [:]
    for row in fresh {
      counted[row.key] = AmountE4(raw: Int64(random.int(in: 0...9_000_000)) * 100)
    }
    let record = AccountReconciliation.record(
      counted: counted, rows: rows, writeDifference: true, kind: .accounts,
      at: Self.secondCount, calendar: .utc, tree: CategoryTree(Fx.categories),
      categories: (Fx.id(801), Fx.id(802)), rubPerUnit: fx.rubPerUnit, makeId: Ids().make)
    #expect(record.differences.isEmpty)
    #expect(record.balances.count == fresh.count)
    #expect(record.balances.allSatisfy { $0.expectedE4 == nil && $0.differenceE4 == nil })
    #expect(record.reconciliation.expectedTotalRubE4 == nil)
    #expect(record.withoutRate.isEmpty)
  }

  /// A row left empty writes nothing — not a zero, not a balance; a count typed for a balance
  /// the sheet does not list is ignored.
  @Test func anEmptyRowAndAStrangerWriteNothing() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000"), (Fx.card, .rub, "500")], at: Self.firstCount)
    let dataset = fx.ledger.dataset
    let built = AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: Fx.now, calendar: .utc)
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: built, at: Self.secondCount,
      locale: Locale(identifier: "en"))
    let stranger = BalanceKey(accountId: Fx.id(99), currency: .eur)
    let record = AccountReconciliation.record(
      counted: [Self.mainRub: Fx.money("900"), stranger: Fx.money("5")], rows: rows,
      writeDifference: true, kind: .accounts, at: Self.secondCount, calendar: .utc,
      tree: CategoryTree(Fx.categories), categories: (Fx.id(801), Fx.id(802)),
      rubPerUnit: fx.rubPerUnit, makeId: Ids().make)
    #expect(record.balances.map(\.key) == [Self.mainRub])
    #expect(record.balances.map(\.differenceE4) == [Fx.money("-100")])
    #expect(record.differences.count == 1)
    #expect(record.reconciliation.actualTotalRubE4 == Fx.money("900"))
    #expect(record.reconciliation.expectedTotalRubE4 == Fx.money("1000"))
  }

  // MARK: - The groups of the rows

  /// An archived group is no group — its accounts count in «Всего», as the sidebar has them —
  /// so the sheet must not call their rows «не в сводке», whatever its switch said before it
  /// was put away. The sheet and the snapshot say the same about every row.
  @Test func anArchivedGroupLeavesNoRowApart() {
    var fx = Fx()
    fx.groups[0].archived = true
    fx.count([(Fx.freedom, Fx.tenge, "1000")], at: Self.firstCount)
    let snapshot = AccountsSnapshot.build(
      dataset: fx.ledger.dataset, now: Fx.now, calendar: .utc, rubPerUnit: fx.rubPerUnit,
      localeIdentifier: "en")
    #expect(snapshot.isInSummary(Fx.freedom))
    #expect(snapshot.inSummaryTotalRub == Fx.money("200"))
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: snapshot.balances, at: Fx.now,
      locale: Locale(identifier: "en"))
    for row in rows {
      #expect(row.isInSummary == snapshot.isInSummary(row.key.accountId), "\(row.key)")
    }
  }

  /// A live group left out of the summary: its rows are apart on the sheet as in the
  /// snapshot, and they are still on the sheet — the money is real.
  @Test func aLiveGroupLeftOutIsApartOnTheSheetToo() {
    let fx = Fx()
    let snapshot = AccountsSnapshot.build(
      dataset: fx.ledger.dataset, now: Fx.now, calendar: .utc, rubPerUnit: fx.rubPerUnit,
      localeIdentifier: "en")
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: snapshot.balances, at: Fx.now,
      locale: Locale(identifier: "en"))
    #expect(rows.contains { $0.key == Self.freedomKzt && !$0.isInSummary })
    for row in rows {
      #expect(row.isInSummary == snapshot.isInSummary(row.key.accountId), "\(row.key)")
    }
  }

  // MARK: - Before the count

  /// For any count, dates and save moments: the question is asked exactly when the operation
  /// is dated the day of the latest count of a balance it moves and saved after that count;
  /// «Да» puts it inside the count — the balance now does not move —, «Нет» after it — the
  /// balance moves by the operation.
  @Test(arguments: seeds)
  func beforeTheCountAgainstThePlainRule(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    for _ in 0..<40 {
      var fx = Fx()
      let countDay = Fx.day("2026-09-17").adding(days: random.int(in: 0...2))
      let countAt = CalendarContext.utc.startOfDay(countDay).addingTimeInterval(
        TimeInterval(random.int(in: 1...1_438) * 60))
      fx.count([(Fx.main, .rub, "10000")], at: countAt)
      let occurredDay = countDay.adding(days: random.int(in: -1...1))
      let occurredAt =
        random.chance(1, outOf: 3)
        ? CalendarContext.utc.noon(of: occurredDay)
        : CalendarContext.utc.startOfDay(occurredDay).addingTimeInterval(
          TimeInterval(random.int(in: 0...1_439) * 60))
      let savedAt = countAt.addingTimeInterval(TimeInterval(random.int(in: -600...3_000) * 60))
      let balances = Scenario.balances(fx, now: Fx.at("2026-09-21", 0))
      let asked = AccountReconciliation.beforeTheCount(
        occurredAt: occurredAt, savedAt: savedAt, keys: [Self.mainRub], balances: balances,
        calendar: .utc)
      let shouldAsk = occurredDay == countDay && savedAt > countAt
      #expect((asked != nil) == shouldAsk, "seed \(seed)")
      guard let asked else { continue }
      #expect(asked == countAt)

      for wasBefore in [true, false] {
        let stamp = AccountReconciliation.stamped(
          occurredAt: occurredAt, count: asked, wasBefore: wasBefore)
        #expect(wasBefore ? stamp < countAt : stamp > countAt)
        #expect(CalendarContext.utc.day(of: stamp) == countDay)
        var with = fx
        with.add(.expense, "300", at: stamp)
        let now = Scenario.balances(with, now: Fx.at("2026-09-21", 0))[Self.mainRub]?.amountE4
        #expect(now == (wasBefore ? Fx.money("10000") : Fx.money("9700")), "seed \(seed)")
      }
    }
  }

  /// A transfer moves two balances counted at different moments of the same day: it asks
  /// about the earlier count, which «Да» puts it before — and so before both.
  @Test func aTransferAsksAboutTheEarlierCountOfItsDay() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-19", 9))
    fx.count([(Fx.card, .rub, "500")], at: Fx.at("2026-09-19", 13))
    let balances = Scenario.balances(fx, now: Fx.now)
    let transfer = Transfer(
      occurredAt: Fx.at("2026-09-19", 12), fromAccountId: Fx.main, fromCurrency: .rub,
      fromAmountE4: Fx.money("100"), toAccountId: Fx.card, toCurrency: .rub,
      toAmountE4: Fx.money("100"))
    let asked = AccountReconciliation.beforeTheCount(
      occurredAt: transfer.occurredAt, savedAt: Fx.now,
      keys: AccountReconciliation.movedKeys(of: transfer), balances: balances, calendar: .utc)
    #expect(asked == Fx.at("2026-09-19", 9))
    // Saved between the two counts, only the earlier one asks.
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: transfer.occurredAt, savedAt: Fx.at("2026-09-19", 10),
        keys: AccountReconciliation.movedKeys(of: transfer), balances: balances,
        calendar: .utc) == Fx.at("2026-09-19", 9))
  }

  /// Only the latest count of a balance asks: a count yesterday followed by one this morning
  /// leaves yesterday's operations alone — they are inside this morning's count anyway.
  @Test func anOlderCountNeverAsks() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-18", 14, 5))
    fx.count([(Fx.main, .rub, "900")], at: Fx.at("2026-09-19", 9))
    let balances = Scenario.balances(fx, now: Fx.now)
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: CalendarContext.utc.noon(of: Fx.day("2026-09-18")), savedAt: Fx.now,
        keys: [Self.mainRub], balances: balances, calendar: .utc) == nil)
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: Fx.at("2026-09-19", 8), savedAt: Fx.now, keys: [Self.mainRub],
        balances: balances, calendar: .utc) == Fx.at("2026-09-19", 9))
    // A balance never counted never asks.
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: Fx.at("2026-09-19", 8), savedAt: Fx.now, keys: [Self.cardRub],
        balances: balances, calendar: .utc) == nil)
  }

  // MARK: - The reminder

  /// For any reconciliation day and rhythm: due exactly when more than `everyDays` days have
  /// passed since the day the reminder counts from; never reconciled — due.
  @Test(arguments: seeds)
  func theReminderRhythm(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    for _ in 0..<30 {
      var fx = Fx()
      let day = Fx.day("2026-06-01").adding(days: random.int(in: 0...100))
      fx.count([(Fx.main, .rub, "1")], at: CalendarContext.utc.noon(of: day))
      let every = random.int(in: 1...60)
      let today = day.adding(days: random.int(in: 0...90))
      #expect(
        AccountReconciliation.isDue(book: fx.book, today: today, everyDays: every)
          == (day.days(to: today) > every), "seed \(seed)")
    }
    #expect(AccountReconciliation.isDue(book: .empty, today: Fx.today, everyDays: 30))
  }
}

extension ReconciliationPropertyTests.Scenario {
  /// The balances of any fixture book as of `now`.
  static func balances(_ fx: CashFx, now: Date) -> AccountBalances {
    let dataset = fx.ledger.dataset
    return AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: now, calendar: .utc)
  }
}

extension ReconciliationPropertyTests {
  /// The question «Это было до сверки?» reads the owner's days, not UTC's: counted at 00:30 in
  /// Moscow on the 19th (21:30 UTC on the 18th), an operation of the 19th saved at 00:40 asks,
  /// and «вчера» — the 18th — does not, whatever UTC says.
  @Test func beforeTheCountReadsTheDaysOfTheOwnersCalendar() {
    let moscow = CalendarContext.moscow
    let countAt = moscow.startOfDay(Fx.day("2026-09-19")).addingTimeInterval(30 * 60)
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: countAt)
    let dataset = fx.ledger.dataset
    let balances = AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: countAt.addingTimeInterval(3_600),
      calendar: moscow)
    let savedAt = countAt.addingTimeInterval(10 * 60)
    let today = moscow.startOfDay(Fx.day("2026-09-19")).addingTimeInterval(10 * 60)
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: today, savedAt: savedAt, keys: [Self.mainRub], balances: balances,
        calendar: moscow) == countAt)
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: moscow.noon(of: Fx.day("2026-09-18")), savedAt: savedAt,
        keys: [Self.mainRub], balances: balances, calendar: moscow) == nil)
    // «Да» stays on the owner's day: 00:29:59 on the 19th in Moscow.
    let stamp = AccountReconciliation.stamped(occurredAt: today, count: countAt, wasBefore: true)
    #expect(moscow.day(of: stamp) == Fx.day("2026-09-19"))
  }
}
