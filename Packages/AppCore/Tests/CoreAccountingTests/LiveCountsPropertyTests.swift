import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A book of operations, transfers and counts kept in memory, settled the way the storage
/// settles it: every live count against what the books expect of it, its operation created,
/// rewritten or purged in place. The suites of live counts drive it; nothing here is the code
/// under test but `LiveCounts.settle`, `LiveCounts.liveIds` and the balances they read.
struct CountBook {
  var accounts: [PaymentMethod]
  var entries: [TransactionEntry] = []
  var transfers: [Transfer] = []
  var reconciliations: [Reconciliation] = []
  /// Every count, in the order of the book.
  var balances: [ReconciledBalance] = []
  /// Counts the owner called a real difference, never frozen.
  var kept: Set<UUID> = []
  /// Rubles for one unit of a foreign currency, on every day.
  var rates: [CurrencyCode: Decimal] = [:]
  let tree: CategoryTree
  let categories: ReconcileCategories
  let calendar = CalendarContext.utc

  init(accounts: [PaymentMethod], tree: CategoryTree, categories: ReconcileCategories) {
    self.accounts = accounts
    self.tree = tree
    self.categories = categories
  }

  func engine(now: Date = Date(timeIntervalSince1970: 4_000_000_000)) -> AccountBalances {
    AccountBalances.build(
      entries: entries, transfers: transfers, debtEntries: [], debts: [:],
      reconciliations: reconciliations, balances: balances, accounts: accounts, tree: tree,
      now: now, calendar: calendar)
  }

  func count(_ id: UUID) -> ReconciledBalance? { balances.first { $0.id == id } }

  func operation(ofCount id: UUID) -> TransactionEntry? {
    guard let count = count(id) else { return nil }
    let key = OperationLink.reconciledBalance(reconciliation: count.reconciliationId, balance: id)
      .externalId
    return entries.first { $0.transaction.externalId == key }
  }

  var liveIds: Set<UUID> {
    let frozen = ZeroOpenings.frozenCounts(
      balances: engine(), reconciliations: reconciliations, kept: kept)
    return LiveCounts.liveIds(
      reconciliations: reconciliations, balances: balances, frozen: frozen)
  }

  /// Adds a reconciliation of `kind` at `at` counting `counts`; with `compare`, each count is
  /// compared with what the books expect at that moment and records its difference by
  /// `records` — the way the sheet saves it — and the difference is written at once.
  @discardableResult
  mutating func addCount(
    _ number: Int, at moment: Date, kind: ReconciliationKind = .accounts,
    origin: ReconciliationOrigin? = nil, compare: Bool = true, records: Bool = true,
    _ counts: [(BalanceKey, AmountE4)]
  ) -> [UUID] {
    let reconciliationId = id(number)
    reconciliations.append(
      Reconciliation(
        id: reconciliationId, date: calendar.day(of: moment), reconciledAt: moment,
        actualTotalRubE4: .zero, kind: kind, origin: kind == .opening ? origin : nil))
    let engine = engine()
    var ids: [UUID] = []
    for (index, (key, actual)) in counts.enumerated() {
      let expected =
        (compare && kind == .accounts) ? engine.balance(key, at: moment) : nil
      let balance = ReconciledBalance(
        id: id(number * 100 + index), reconciliationId: reconciliationId,
        accountId: key.accountId, currency: key.currency, actualE4: actual,
        expectedE4: expected, differenceE4: expected.map { actual - $0 },
        recordsDifference: expected == nil ? nil : records)
      balances.append(balance)
      ids.append(balance.id)
    }
    settle(now: moment)
    return ids
  }

  /// Settles every live count; returns what each settle said.
  @discardableResult
  mutating func settle(
    now: Date = Date(timeIntervalSince1970: 1_800_000_000)
  )
    -> [CountSettlement]
  {
    let engine = engine()
    let live = liveIds
    let moments = Dictionary(
      reconciliations.compactMap { reconciliation in
        reconciliation.reconciledAt.map { (reconciliation.id, $0) }
      }, uniquingKeysWith: { first, _ in first })
    var results: [CountSettlement] = []
    for index in balances.indices where live.contains(balances[index].id) {
      let count = balances[index]
      guard let expected = engine.expected(forCount: count.id),
        let countAt = moments[count.reconciliationId]
      else { continue }
      let rate = rates[count.currency].map {
        CountRate(perUnit: $0, day: calendar.day(of: countAt), provisional: false)
      }
      let settlement = LiveCounts.settle(
        CountState(count: count, countAt: countAt, operation: operation(ofCount: count.id)),
        expected: expected, rate: rate, categories: categories, tree: tree, now: now)
      balances[index] = settlement.count
      switch settlement.operation {
      case .none: break
      case .create(let entry):
        // A new operation takes the place of the binned one with the same ids, as the
        // database does.
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
      case .rewrite(let entry):
        if let at = entries.firstIndex(where: { $0.id == entry.id }) { entries[at] = entry }
      case .purge(let purged): entries.removeAll { $0.id == purged }
      }
      results.append(settlement)
    }
    return results
  }
}

/// Groceries, salary, and «Сверка» with its income twin — every category the live-count suites
/// file operations under.
let liveCountsTree = CategoryTree([
  CoreKit.Category(id: id(110), kind: .expense, name: "Groceries", quality: .neutral),
  CoreKit.Category(id: id(119), kind: .income, name: "Salary"),
  CoreKit.Category(id: id(900), kind: .expense, name: "Reconciliation", quality: .neutral),
  CoreKit.Category(id: id(901), kind: .income, name: "Reconciliation"),
])

/// After any random history of operations and transfers added, changed and deleted inside and
/// around the windows of the counts, settled after each step:
///
/// * every live count's difference is its count minus the count before it and what moved
///   between the two, worked out here by a plain sum;
/// * a count that records has exactly one live operation of the size of its difference, and
///   none at zero; one that keeps has none written for it;
/// * no `reconcile:<r>:<b>` operation is left without its count;
/// * the money now is the latest count plus everything after it — differences move nothing.
@Suite("Live counts, random histories")
struct LiveCountsPropertyTests {
  static let seeds: [UInt64] = Array(1...40)
  let groceries = id(110)
  let salary = id(119)
  let reconcile = ReconcileCategories(expense: id(900), income: id(901))

  var tree: CategoryTree { liveCountsTree }

  var card: PaymentMethod {
    PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
  }
  var cash: PaymentMethod {
    PaymentMethod(id: id(2), name: "Cash", kind: .cash, currency: .rub, otherCurrencies: [.usd])
  }

  func at(_ dayIndex: Int, hour: Int) -> Date {
    moment("2026-09-01").addingTimeInterval(TimeInterval(dayIndex * 86_400 + hour * 3_600))
  }

  @Test(arguments: seeds)
  func theDifferencesFollowTheBooks(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    var book = CountBook(accounts: [card, cash], tree: tree, categories: reconcile)
    book.rates = [.usd: 90]
    let keys = [
      BalanceKey(accountId: id(1), currency: .rub), BalanceKey(accountId: id(2), currency: .rub),
      BalanceKey(accountId: id(2), currency: .usd),
    ]
    // A first count of every key, then two later ones, each at a random moment of a month.
    book.addCount(10, at: at(0, hour: 9), keys.map { ($0, dice.amount(upTo: 50_000)) })
    var nextNumber = 1_000
    for _ in 0..<3 {
      book.entries.append(
        randomOperation(&dice, number: nextNumber, keys: keys, day: dice.int(0...29)))
      nextNumber += 1
    }
    book.addCount(
      11, at: at(12, hour: 10), records: dice.chance(70),
      keys.map { ($0, dice.amount(upTo: 60_000)) })
    book.addCount(
      12, at: at(24, hour: 18), records: dice.chance(70),
      keys.map { ($0, dice.amount(upTo: 60_000)) })
    check(book, seed: seed)

    for _ in 0..<25 {
      switch dice.below(5) {
      case 0, 1:
        book.entries.append(
          randomOperation(&dice, number: nextNumber, keys: keys, day: dice.int(0...29)))
        nextNumber += 1
      case 2:
        let ordinary = book.entries.indices.filter {
          book.entries[$0].transaction.externalId == nil
        }
        guard !ordinary.isEmpty else { continue }
        let index = dice.pick(ordinary)
        book.entries[index].transaction.occurredAt = at(dice.int(0...29), hour: dice.int(0...23))
        let amount = dice.amount(upTo: 5_000)
        book.entries[index].transaction.amountE4 = amount
        book.entries[index].parts[0].amountE4 = amount
      case 3:
        let ordinary = book.entries.indices.filter {
          book.entries[$0].transaction.externalId == nil
        }
        guard !ordinary.isEmpty else { continue }
        book.entries.remove(at: dice.pick(ordinary))
      default:
        let amount = dice.amount(upTo: 3_000)
        book.transfers.append(
          Transfer(
            id: id(nextNumber), occurredAt: at(dice.int(0...29), hour: dice.int(0...23)),
            fromAccountId: keys[0].accountId, fromCurrency: keys[0].currency,
            fromAmountE4: amount, toAccountId: keys[1].accountId, toCurrency: keys[1].currency,
            toAmountE4: amount))
        nextNumber += 1
      }
      book.settle()
      check(book, seed: seed)
    }
  }

  @Test(arguments: seeds)
  func aSecondSettleChangesNothing(seed: UInt64) {
    var dice = MoneyDice(seed: seed &+ 1_000)
    var book = CountBook(accounts: [card, cash], tree: tree, categories: reconcile)
    let key = BalanceKey(accountId: id(1), currency: .rub)
    book.addCount(10, at: at(0, hour: 9), [(key, money(50_000))])
    book.addCount(11, at: at(15, hour: 9), [(key, dice.amount(upTo: 60_000))])
    for number in 0..<10 {
      book.entries.append(
        randomOperation(&dice, number: 2_000 + number, keys: [key], day: dice.int(0...29)))
    }
    book.settle()
    let settled = book
    let again = book.settle()
    #expect(book.balances == settled.balances, "seed \(seed)")
    #expect(book.entries == settled.entries, "seed \(seed)")
    #expect(again.allSatisfy { !$0.countChanged && $0.operation == .none }, "seed \(seed)")
  }

  private func randomOperation(
    _ dice: inout MoneyDice, number: Int, keys: [BalanceKey], day: Int
  ) -> TransactionEntry {
    let key = dice.pick(keys)
    let kind: TransactionKind = dice.chance(30) ? .income : .expense
    let amount = dice.amount(upTo: 5_000)
    let transaction = Transaction(
      id: id(number), kind: kind, occurredAt: at(day, hour: dice.int(0...23)),
      currency: key.currency, amountE4: amount, paymentMethodId: key.accountId)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          id: id(number * 10 + 7), transactionId: id(number),
          categoryId: kind == .expense ? groceries : salary,
          amountE4: amount)
      ])
  }

  /// The four invariants, each by its own plain sum.
  private func check(_ book: CountBook, seed: UInt64) {
    let live = book.liveIds
    let moments = Dictionary(
      book.reconciliations.compactMap { reconciliation in
        reconciliation.reconciledAt.map { (reconciliation.id, $0) }
      }, uniquingKeysWith: { first, _ in first })
    let byKey = Dictionary(grouping: book.balances, by: \.key)
    for (key, counts) in byKey {
      for index in counts.indices.dropFirst() where live.contains(counts[index].id) {
        let previous = counts[index - 1]
        let count = counts[index]
        guard let from = moments[previous.reconciliationId],
          let to = moments[count.reconciliationId]
        else { continue }
        let moved = plainSum(book, key: key, after: from, through: to)
        let expected = previous.actualE4 + moved
        #expect(count.expectedE4 == expected, "seed \(seed): expected of a live count")
        #expect(count.differenceE4 == count.actualE4 - expected, "seed \(seed): difference")
        let operation = book.operation(ofCount: count.id)
        if count.recordsDifference == true, let difference = count.differenceE4,
          !difference.isZero
        {
          #expect(operation?.transaction.amountE4 == difference.magnitude, "seed \(seed)")
          #expect(
            operation?.transaction.kind == (difference.isNegative ? .expense : .income),
            "seed \(seed)")
          #expect(count.transactionId == operation?.id, "seed \(seed)")
        } else {
          #expect(operation == nil, "seed \(seed): no operation at zero or in keep mode")
          #expect(count.transactionId == nil, "seed \(seed)")
        }
      }
    }
    // No difference without its count.
    let countIds = Set(book.balances.map(\.id))
    for entry in book.entries {
      guard
        case .reconciledBalance(_, let balance) = OperationLink(
          externalId: entry.transaction.externalId)
      else { continue }
      #expect(countIds.contains(balance), "seed \(seed): an operation without its count")
    }
    // The money now is the latest count plus what moved after it.
    let engine = book.engine()
    for (key, counts) in byKey {
      guard let latest = counts.last, let from = moments[latest.reconciliationId] else {
        continue
      }
      let after = plainSum(book, key: key, after: from, through: engine.now)
      #expect(engine[key]?.amountE4 == latest.actualE4 + after, "seed \(seed): balance now")
    }
  }

  /// What ordinary operations and transfers moved on the key in `(after, through]`.
  private func plainSum(
    _ book: CountBook, key: BalanceKey, after: Date, through: Date
  )
    -> AmountE4
  {
    var sum = AmountE4.zero
    for entry in book.entries where entry.transaction.externalId == nil {
      let transaction = entry.transaction
      guard transaction.paymentMethodId == key.accountId, transaction.currency == key.currency,
        transaction.occurredAt > after, transaction.occurredAt <= through
      else { continue }
      sum += transaction.kind == .expense ? -transaction.amountE4 : transaction.amountE4
    }
    for transfer in book.transfers
    where transfer.occurredAt > after && transfer.occurredAt <= through {
      if transfer.from == key { sum += -transfer.fromAmountE4 }
      if transfer.to == key { sum += transfer.toAmountE4 }
    }
    return sum
  }
}
