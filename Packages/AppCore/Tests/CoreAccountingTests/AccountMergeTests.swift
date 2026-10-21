import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Merging one account into another")
struct AccountMergeTests {
  let categories = StartingCategories()
  let kzt = CurrencyCode("KZT")

  var source: PaymentMethod {
    PaymentMethod(
      id: id(1), name: "Old card", currency: .rub, isDefault: true, otherCurrencies: [.usd])
  }
  var target: PaymentMethod {
    PaymentMethod(id: id(2), name: "New card", currency: .rub, otherCurrencies: [kzt])
  }

  func key(_ account: UUID, _ currency: CurrencyCode) -> BalanceKey {
    BalanceKey(accountId: account, currency: currency)
  }

  func spend(
    _ number: Int, _ amount: Int, _ currency: CurrencyCode, on account: UUID,
    at: Date = moment("2026-03-05")
  )
    -> TransactionEntry
  {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .expense, occurredAt: at, currency: currency,
        amountE4: money(amount), paymentMethodId: account),
      parts: [TransactionPart(transactionId: id(number), amountE4: money(amount))])
  }

  func balances(
    _ entries: [TransactionEntry], transfers: [Transfer] = [], counted: [(BalanceKey, Int)]
  ) -> AccountBalances {
    let reconciliation = Reconciliation(
      id: id(90), date: day("2026-03-01"), reconciledAt: moment("2026-03-01"),
      actualTotalRubE4: .zero, kind: .opening)
    return AccountBalances.build(
      entries: entries, transfers: transfers, debtEntries: [], debts: [:],
      reconciliations: [reconciliation],
      balances: counted.map {
        ReconciledBalance(
          reconciliationId: id(90), accountId: $0.0.accountId, currency: $0.0.currency,
          actualE4: money($0.1))
      },
      accounts: [source, target], tree: categories.tree, now: moment("2026-03-31"),
      calendar: .utc)
  }

  @Test func theTargetTakesTheCurrenciesAndTheMainFlagOfBoth() {
    let result = AccountMerge.plan(
      source: source, target: target, transfers: [], balances: balances([], counted: []),
      at: moment("2026-03-20"))
    #expect(result.plan.target.currencies == [.rub, kzt, .usd])
    #expect(result.plan.target.isDefault)
    #expect(result.plan.sourceId == id(1))
  }

  /// Both counted at one moment: the target is counted there at what the two held together
  /// then, the source at zero — and after it the two hold together what they hold now.
  @Test func theBalancesAreAddedUpAndTheSourceIsCountedAtZero() {
    let known = balances(
      [spend(3, 100, .rub, on: id(1)), spend(4, 50, .rub, on: id(2))],
      counted: [(key(id(1), .rub), 1000), (key(id(2), .rub), 500), (key(id(1), .usd), 20)])
    let result = AccountMerge.plan(
      source: source, target: target, transfers: [], balances: known, at: moment("2026-03-20"))
    #expect(result.plan.opening[key(id(2), .rub)] == money(1500))
    #expect(result.plan.moments[key(id(2), .rub)] == moment("2026-03-01"))
    #expect(result.plan.opening[key(id(2), .usd)] == money(20))
    #expect(result.plan.moments[key(id(2), .usd)] == moment("2026-03-01"))
    #expect(result.plan.opening[key(id(2), kzt)] == nil)
    #expect(result.needsBalance.isEmpty)
    #expect(result.plan.sourceZero == [key(id(1), .rub), key(id(1), .usd)].sorted())
    let after = AccountMerge.balancesAfter(result.plan, source: source.id, balances: known)
    #expect(after[key(id(2), .rub)] == money(1350))
    #expect(after[key(id(2), .usd)] == money(20))
  }

  /// A key that moved on both but was counted on one only: the dialog asks for it. Left
  /// empty, the target keeps its own latest count as the starting point.
  @Test func aBalanceNobodyKnowsIsAskedFor() {
    let partly = balances(
      [spend(3, 100, .rub, on: id(1)), spend(4, 50, .rub, on: id(2))],
      counted: [(key(id(2), .rub), 500)])
    let result = AccountMerge.plan(
      source: source, target: target, transfers: [], balances: partly, at: moment("2026-03-20"))
    #expect(result.needsBalance == [key(id(2), .rub)])
    #expect(result.plan.opening[key(id(2), .rub)] == money(500))
    #expect(result.plan.moments[key(id(2), .rub)] == moment("2026-03-01"))
  }

  @Test func transfersBetweenTheTwoInOneCurrencyGoAndExchangesStay() {
    let same = Transfer(
      id: id(70), occurredAt: moment("2026-03-03"), fromAccountId: id(1), fromCurrency: .rub,
      fromAmountE4: money(100), toAccountId: id(2), toCurrency: .rub, toAmountE4: money(100))
    let exchange = Transfer(
      id: id(71), occurredAt: moment("2026-03-03"), fromAccountId: id(1), fromCurrency: .rub,
      fromAmountE4: money(100), toAccountId: id(2), toCurrency: kzt, toAmountE4: money(550))
    let elsewhere = Transfer(
      id: id(72), occurredAt: moment("2026-03-03"), fromAccountId: id(1), fromCurrency: .rub,
      fromAmountE4: money(100), toAccountId: id(3), toCurrency: .rub, toAmountE4: money(100))
    let result = AccountMerge.plan(
      source: source, target: target, transfers: [same, exchange, elsewhere],
      balances: balances([], counted: []), at: moment("2026-03-20"))
    #expect(result.plan.deletedTransferIds == [id(70)])
  }

  // MARK: A merge is no count

  /// «Сбер» (kept) and «Наличные» (merged into it), each in rubles only.
  let sber = PaymentMethod(id: id(2), name: "Sber", currency: .rub, isDefault: true)
  let cash = PaymentMethod(id: id(1), name: "Cash", currency: .rub)
  var sberKey: BalanceKey { key(id(2), .rub) }
  var cashKey: BalanceKey { key(id(1), .rub) }

  /// 26.09 at `hour` UTC.
  func at(_ hour: Double, on iso: String = "2026-09-26") -> Date {
    moment(iso).addingTimeInterval(hour * 3600)
  }

  struct Book {
    var entries: [TransactionEntry] = []
    var transfers: [Transfer] = []
    var reconciliations: [Reconciliation] = []
    var counted: [ReconciledBalance] = []
  }

  func count(_ book: inout Book, number: Int, at moment: Date, _ rows: [(BalanceKey, Int)]) {
    let reconciliation = Reconciliation(
      id: id(number), date: CalendarContext.utc.day(of: moment), reconciledAt: moment,
      actualTotalRubE4: .zero, kind: .accounts)
    book.reconciliations.append(reconciliation)
    for (index, row) in rows.enumerated() {
      book.counted.append(
        ReconciledBalance(
          id: id(number * 100 + index), reconciliationId: reconciliation.id,
          accountId: row.0.accountId, currency: row.0.currency, actualE4: money(row.1)))
    }
  }

  func build(_ book: Book, accounts: [PaymentMethod], now: Date) -> AccountBalances {
    // The book's order: by moment, and in the order written within one moment.
    let order = Dictionary(
      book.reconciliations.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }
    )
    let moments = Dictionary(
      book.reconciliations.map { ($0.id, $0.reconciledAt ?? .distantPast) },
      uniquingKeysWith: { first, _ in first })
    let counted = book.counted.enumerated().sorted { left, right in
      let (l, r) = (
        moments[left.element.reconciliationId]!, moments[right.element.reconciliationId]!
      )
      if l != r { return l < r }
      let (lo, ro) = (order[left.element.reconciliationId]!, order[right.element.reconciliationId]!)
      if lo != ro { return lo < ro }
      return left.offset < right.offset
    }.map(\.element)
    return AccountBalances.build(
      entries: book.entries, transfers: book.transfers, debtEntries: [], debts: [:],
      reconciliations: book.reconciliations, balances: counted, accounts: accounts,
      tree: categories.tree, now: now, calendar: .utc)
  }

  /// The merge as the storage writes it: same-currency transfers between the two go,
  /// everything of the source points at the target, and one opening per moment of the plan.
  func merged(_ book: Book, plan: AccountMergePlan) -> Book {
    var after = book
    let gone = Set(plan.deletedTransferIds)
    after.transfers = book.transfers.filter { !gone.contains($0.id) }.map { transfer in
      var moved = transfer
      if moved.fromAccountId == plan.sourceId { moved.fromAccountId = plan.target.id }
      if moved.toAccountId == plan.sourceId { moved.toAccountId = plan.target.id }
      return moved
    }
    after.entries = book.entries.map { entry in
      var moved = entry
      if moved.transaction.paymentMethodId == plan.sourceId {
        moved.transaction.paymentMethodId = plan.target.id
      }
      return moved
    }
    for (index, group) in plan.countsByMoment.enumerated() {
      let reconciliation = Reconciliation(
        id: id(9_000 + index), date: CalendarContext.utc.day(of: group.at),
        reconciledAt: group.at, actualTotalRubE4: .zero, kind: .opening, origin: .merge)
      after.reconciliations.append(reconciliation)
      for (row, count) in group.counts.enumerated() {
        after.counted.append(
          ReconciledBalance(
            id: id(900_000 + index * 100 + row), reconciliationId: reconciliation.id,
            accountId: count.key.accountId, currency: count.key.currency,
            actualE4: count.actual))
      }
    }
    return after
  }

  func mergedAccounts(_ plan: AccountMergePlan) -> [PaymentMethod] {
    var archived = cash
    archived.archived = true
    return [plan.target, archived]
  }

  /// One sheet: «Сбер» 100,000 and «Наличные» 5,000 at 06:00, merged at 12:00, a coffee
  /// of 09:00 entered on «Сбер» afterwards moves money: 104,700, not 105,000.
  @Test func aMergeAnchorsAtTheKeptAccountsLatestCount() {
    var book = Book()
    count(&book, number: 10, at: at(6), [(sberKey, 100_000), (cashKey, 5_000)])
    let before = build(book, accounts: [sber, cash], now: at(12))
    let (plan, needs) = AccountMerge.plan(
      source: cash, target: sber, transfers: [], balances: before, at: at(12))
    #expect(needs.isEmpty)
    #expect(plan.opening[sberKey] == money(105_000))
    #expect(plan.moments[sberKey] == at(6))
    var after = merged(book, plan: plan)
    after.entries.append(spend(20, 300, .rub, on: sber.id, at: at(9)))
    let balances = build(after, accounts: mergedAccounts(plan), now: at(13))
    #expect(balances[sberKey]?.amountE4 == money(104_700))
    // «сверено» and «до сверки?» read the latest count: 06:00, never the merge's 12:00.
    #expect(balances.latestAnchor(sberKey)?.at == at(6))
  }

  /// Counts of different moments: «Сбер» 06:00 100,000; «Наличные» 10:00 5,000. Coffee 08:00
  /// −300 and lunch 11:00 −700 on «Сбер», taxi 09:00 −200 on «Наличные» (inside its 5,000).
  /// The anchor is «Сбер»'s own count: 100,000 + 5,200 at 06:00, and now 104,000.
  @Test func countsOfDifferentMomentsAddUpAtTheTargetsCount() {
    var book = differentMoments()
    let before = build(book, accounts: [sber, cash], now: at(12))
    let (plan, _) = AccountMerge.plan(
      source: cash, target: sber, transfers: [], balances: before, at: at(12))
    #expect(plan.opening[sberKey] == money(105_200))
    #expect(plan.moments[sberKey] == at(6))
    book = merged(book, plan: plan)
    let balances = build(book, accounts: mergedAccounts(plan), now: at(12))
    #expect(balances[sberKey]?.amountE4 == money(104_000))
    #expect(
      AccountMerge.balancesAfter(plan, source: cash.id, balances: before)[sberKey]
        == money(104_000))
  }

  /// The same, and a card coffee of 08:00 entered at 13:00, after the merge: it is after the
  /// anchor, so it moves money — 103,700. An anchor at 10:00 would have left it history.
  @Test func aBackdatedOperationOfTheTargetBetweenTheTwoCountsMovesMoney() {
    var book = differentMoments()
    let before = build(book, accounts: [sber, cash], now: at(12))
    let (plan, _) = AccountMerge.plan(
      source: cash, target: sber, transfers: [], balances: before, at: at(12))
    book = merged(book, plan: plan)
    book.entries.append(spend(30, 300, .rub, on: sber.id, at: at(8)))
    let balances = build(book, accounts: mergedAccounts(plan), now: at(13))
    #expect(balances[sberKey]?.amountE4 == money(103_700))
  }

  func differentMoments() -> Book {
    var book = Book()
    count(&book, number: 10, at: at(6), [(sberKey, 100_000)])
    count(&book, number: 11, at: at(10), [(cashKey, 5_000)])
    book.entries = [
      spend(20, 300, .rub, on: sber.id, at: at(8)),
      spend(21, 700, .rub, on: sber.id, at: at(11)),
      spend(22, 200, .rub, on: cash.id, at: at(9)),
    ]
    return book
  }

  /// «Сбер» was counted on 20.09 and «Наличные» only moved (−3,000 on 10.09). The balance
  /// left empty keeps «Сбер» at its latest count: an opening there with that count's money,
  /// so the wallet's past lands before it and is history.
  @Test func aMergeWithAnEmptyBalanceLeavesTheTargetsDifferencesAlone() {
    var book = Book()
    count(&book, number: 10, at: at(12, on: "2026-09-01"), [(sberKey, 50_000)])
    count(&book, number: 11, at: at(12, on: "2026-09-20"), [(sberKey, 45_000)])
    book.entries = [
      spend(20, 3_000, .rub, on: cash.id, at: at(12, on: "2026-09-10")),
      spend(21, 1_000, .rub, on: sber.id, at: at(12, on: "2026-09-22")),
    ]
    let before = build(book, accounts: [sber, cash], now: at(12, on: "2026-09-26"))
    let (plan, needs) = AccountMerge.plan(
      source: cash, target: sber, transfers: [], balances: before,
      at: at(12, on: "2026-09-26"))
    #expect(needs == [sberKey])
    #expect(plan.opening[sberKey] == money(45_000))
    #expect(plan.moments[sberKey] == at(12, on: "2026-09-20"))
    #expect(plan.sourceZero.isEmpty)
    book = merged(book, plan: plan)
    let balances = build(book, accounts: mergedAccounts(plan), now: at(12, on: "2026-09-26"))
    #expect(balances[sberKey]?.amountE4 == money(44_000))
    // The count of 20.09 is followed by an opening of the same moment: the wallet's −3,000
    // of 10.09 is before both.
    let anchors = balances.anchors(sberKey)
    #expect(anchors.count == 3)
    #expect(anchors.last?.at == at(12, on: "2026-09-20"))
  }

  /// Both accounts set up on 01.09, merged on 16.09. The merged key is anchored at the
  /// setup, so a rent due on 10.09 is still after the latest count — a merge pays no due date.
  @Test func aMergeIsNoCountForDueDates() {
    var book = Book()
    count(&book, number: 10, at: at(12, on: "2026-09-01"), [(sberKey, 100_000), (cashKey, 5_000)])
    let before = build(book, accounts: [sber, cash], now: at(12, on: "2026-09-16"))
    let (plan, _) = AccountMerge.plan(
      source: cash, target: sber, transfers: [], balances: before,
      at: at(12, on: "2026-09-16"))
    book = merged(book, plan: plan)
    let balances = build(book, accounts: mergedAccounts(plan), now: at(12, on: "2026-09-16"))
    #expect(balances.latestAnchor(sberKey)?.at == at(12, on: "2026-09-01"))
    #expect(balances[sberKey]?.amountE4 == money(105_000))
    #expect(plan.countsByMoment.allSatisfy { $0.at < at(12, on: "2026-09-10") })
  }

  /// Neither was ever counted: nothing is written and nothing is asked — the merged key stays
  /// «ещё не сверен».
  @Test func twoUncountedAccountsStayUncounted() {
    var book = Book()
    book.entries = [
      spend(20, 300, .rub, on: sber.id, at: at(8)),
      spend(21, 200, .rub, on: cash.id, at: at(9)),
    ]
    let before = build(book, accounts: [sber, cash], now: at(12))
    let (plan, needs) = AccountMerge.plan(
      source: cash, target: sber, transfers: [], balances: before, at: at(12))
    #expect(needs.isEmpty)
    #expect(plan.opening.isEmpty)
    #expect(plan.sourceZero.isEmpty)
    #expect(plan.countsByMoment.isEmpty)
    #expect(AccountMerge.balancesAfter(plan, source: cash.id, balances: before)[sberKey] == nil)
  }

  /// The source is counted at zero right after its own latest count: archived, it holds
  /// nothing, and bringing it back never counts its money twice.
  @Test func theSourceIsZeroedRightAfterItsLatestCount() {
    var book = differentMoments()
    let before = build(book, accounts: [sber, cash], now: at(12))
    let (plan, _) = AccountMerge.plan(
      source: cash, target: sber, transfers: [], balances: before, at: at(12))
    #expect(plan.sourceZero == [cashKey])
    #expect(plan.moments[cashKey] == at(10))
    book = merged(book, plan: plan)
    let balances = build(book, accounts: mergedAccounts(plan), now: at(12))
    #expect(balances[cashKey]?.amountE4 == .zero)
    #expect(balances.latestAnchor(cashKey)?.at == at(10))
    // One opening per moment: «Сбер» at 06:00, «Наличные» at 10:00.
    #expect(plan.countsByMoment.map(\.at) == [at(6), at(10)])
  }

  /// The target never counted, the source counted: the target is counted at the source's
  /// count with its money; what moved on the source after it lands on the target.
  @Test func anUncountedTargetTakesTheSourcesCount() {
    var book = Book()
    count(&book, number: 10, at: at(6), [(cashKey, 5_000)])
    book.entries = [spend(20, 200, .rub, on: cash.id, at: at(9))]
    let before = build(book, accounts: [sber, cash], now: at(12))
    let (plan, needs) = AccountMerge.plan(
      source: cash, target: sber, transfers: [], balances: before, at: at(12))
    #expect(needs.isEmpty)
    #expect(plan.opening[sberKey] == money(5_000))
    #expect(plan.moments[sberKey] == at(6))
    book = merged(book, plan: plan)
    let balances = build(book, accounts: mergedAccounts(plan), now: at(12))
    #expect(balances[sberKey]?.amountE4 == money(4_800))
  }

  /// A balance typed in the dialog is the owner's own count, now: it replaces what the plan
  /// would write for the key and is dated at the merge.
  @Test func aTypedBalanceIsCountedAtTheMerge() {
    var book = Book()
    count(&book, number: 10, at: at(6), [(sberKey, 100_000)])
    book.entries = [spend(21, 200, .rub, on: cash.id, at: at(9))]
    let before = build(book, accounts: [sber, cash], now: at(12))
    var (plan, needs) = AccountMerge.plan(
      source: cash, target: sber, transfers: [], balances: before, at: at(12))
    #expect(needs == [sberKey])
    plan.count(sberKey, typed: money(99_000))
    #expect(plan.opening[sberKey] == money(99_000))
    #expect(plan.moments[sberKey] == nil)
    #expect(plan.countsByMoment.map(\.at) == [at(12)])
  }
}
