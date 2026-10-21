import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// The counts a set with accounts adds, after the accounts' own count two weeks before the
  /// last day:
  ///
  /// * a credit card opened thirteen days before the last day with its debt as the starting
  ///   balance — a first count below zero, neither income nor spending —, a card named like it,
  ///   three purchases and one after the later count, so it ends below zero;
  /// * four days before the last day, a count of the cash and of the credit card at 20:45, which
  ///   records its differences: the cash is short, and the difference is an expense in «Сверка»;
  ///   the credit card is as the books say;
  /// * on that day at 09:30 — a time chosen, so never asked about — the credit card paid from
  ///   the main account, inside the window of the count;
  /// * groceries paid in cash two days before the count and entered the day after it: the
  ///   difference already follows them, the way it follows every operation dated inside its
  ///   window whenever it is written.
  ///
  /// The count is written as the app keeps a count that follows the books — its expected
  /// balance, its difference and the operation of the difference, with the ids derived from the
  /// count —, so opening the set settles nothing. Without the accounts' own count (a history
  /// shorter than a month) there is nothing to count after, and the set comes back as it is.
  func withCountsLayer(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?
  ) -> SampleDataSet {
    let layer = SampleLayer(
      tag: 0x0012_C0C0_0000_0012, seed: seed, set: self, calendar: calendar, language: language,
      now: now)
    guard reconciliations.contains(where: { $0.kind == .accounts }),
      let main = mainAccount,
      let cash = paymentMethods.first(where: { $0.kind == .cash && !$0.isDefault && !$0.archived }),
      let expenseId = settings[PlanningSettings.reconcileExpenseCategoryKey].flatMap(UUID.init),
      let incomeId = settings[PlanningSettings.reconcileIncomeCategoryKey].flatMap(UUID.init),
      let openedOn = layer.daysBeforeEnd(13), let countedOn = layer.daysBeforeEnd(4)
    else { return self }
    var set = self

    // The credit card and its starting balance: what the bank said was owed on it.
    var accountStream = layer.stream("credit card")
    let credit = PaymentMethod(
      id: accountStream.nextUUID(), name: layer.word("Credit card", "Кредитная карта"),
      kind: .card, currency: .rub, groupId: main.groupId)
    set.paymentMethods.append(credit)
    set.cards.append(
      PaymentCard(
        id: CardsMigration.cardId(forAccount: credit.id), accountId: credit.id,
        name: credit.name))
    let creditKey = BalanceKey(accountId: credit.id, currency: .rub)
    var openingStream = layer.stream("credit card opened", on: openedOn)
    let owed = AmountE4(whole: -Int64(openingStream.int(in: 24...40)) * 500)
    let openedAt = layer.moment(openedOn, hour: 10, minute: 0)
    let opening = Reconciliation(
      id: openingStream.nextUUID(), date: openedOn, reconciledAt: openedAt,
      actualTotalRubE4: .zero, kind: .opening, origin: .account)
    set.reconciliations.append(opening)
    set.reconciledBalances.append(
      ReconciledBalance(
        id: openingStream.nextUUID(), reconciliationId: opening.id, accountId: credit.id,
        currency: .rub, actualE4: owed))
    set.accountExpectations[creditKey] = owed

    // What the credit card paid for: three purchases before the count, one after it.
    let buys: [(days: Int, english: String, note: (String, String), range: ClosedRange<Int>)] = [
      (11, "Electronics", ("Online store", "Интернет-магазин"), 15...40),
      (8, "Clothing", ("Sneakers", "Кроссовки"), 20...45),
      (6, "Restaurants", ("Dinner out", "Ужин в ресторане"), 12...30),
      (2, "Groceries", ("Groceries", "Продукты"), 8...20),
    ]
    for buy in buys {
      guard let day = layer.daysBeforeEnd(buy.days), let category = starter(buy.english) else {
        continue
      }
      var rng = layer.stream("credit card purchase", on: day)
      set.add(
        layer.purchase(
          AmountE4(whole: Int64(rng.int(in: buy.range)) * 100), of: category.category,
          parent: category.parent, at: layer.moment(on: day, rng: &rng), account: credit.id,
          note: layer.word(buy.note.0, buy.note.1), rng: &rng),
        calendar: calendar)
    }

    // The credit card paid off in part, at a time chosen before the count.
    var transferStream = layer.stream("credit card paid", on: countedOn)
    let paidAt = layer.moment(countedOn, hour: 9, minute: 30)
    let paid = AmountE4(whole: 3_000)
    set.transfers.append(
      Transfer(
        id: transferStream.nextUUID(), occurredAt: paidAt, fromAccountId: main.id,
        fromCurrency: .rub, fromAmountE4: paid, toAccountId: credit.id, toCurrency: .rub,
        toAmountE4: paid, note: layer.word("Credit card payment", "Погашение кредитной карты"),
        createdAt: paidAt, updatedAt: paidAt))
    set.transfers.sort { left, right in
      left.occurredAt != right.occurredAt
        ? left.occurredAt < right.occurredAt : left.id.uuidString < right.id.uuidString
    }
    let mainKey = BalanceKey(accountId: main.id, currency: .rub)
    set.accountExpectations[mainKey] = (set.accountExpectations[mainKey] ?? .zero) - paid
    set.accountExpectations[creditKey] = (set.accountExpectations[creditKey] ?? .zero) + paid

    // Groceries in cash two days before the count, entered the day after it.
    let countedAt = layer.moment(countedOn, hour: 20, minute: 45)
    if let bought = layer.daysBeforeEnd(6), let groceries = starter("Groceries") {
      var rng = layer.stream("groceries entered late", on: bought)
      let enteredOn = calendar.adding(days: 1, to: countedOn)
      set.add(
        layer.purchase(
          AmountE4(whole: Int64(rng.int(in: 6...9)) * 100), of: groceries.category,
          parent: groceries.parent, at: layer.moment(on: bought, rng: &rng), account: cash.id,
          note: layer.word("Farmers market", "Рынок"),
          writtenAt: layer.moment(enteredOn, hour: 10, minute: 0), rng: &rng),
        calendar: calendar)
    }

    // The count: the cash short by what the stream says, the credit card as the books say.
    var countStream = layer.stream("later count", on: countedOn)
    let sheet = Reconciliation(
      id: countStream.nextUUID(), date: countedOn, reconciledAt: countedAt,
      actualTotalRubE4: .zero, kind: .accounts)
    let cashKey = BalanceKey(accountId: cash.id, currency: .rub)
    let short = AmountE4(whole: -Int64(countStream.int(in: 30...60)) * 10)
    let rows = [(cashKey, short), (creditKey, AmountE4.zero)].map { key, difference in
      (key: key, difference: difference, id: countStream.nextUUID())
    }
    set.reconciliations.append(sheet)
    let placeholders = rows.map { row in
      ReconciledBalance(
        id: row.id, reconciliationId: sheet.id, accountId: row.key.accountId,
        currency: row.key.currency, actualE4: .zero)
    }
    let tree = CategoryTree(set.categories)
    let balances = AccountBalances.build(
      entries: set.entries, transfers: set.transfers, debtEntries: set.debtEntries,
      debts: Dictionary(set.debts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      reconciliations: set.reconciliations, balances: set.reconciledBalances + placeholders,
      accounts: set.paymentMethods, tree: tree, now: countedAt, calendar: calendar)
    let categories = ReconcileCategories(expense: expenseId, income: incomeId)
    for row in rows {
      guard let expected = balances.expected(forCount: row.id) else { continue }
      var balance = ReconciledBalance(
        id: row.id, reconciliationId: sheet.id, accountId: row.key.accountId,
        currency: row.key.currency, actualE4: expected + row.difference, expectedE4: expected,
        differenceE4: row.difference, recordsDifference: true)
      if !row.difference.isZero {
        let entry = LiveCounts.differenceOperation(
          row.difference, key: row.key, rate: nil, at: countedAt, tree: tree,
          categories: categories, countId: row.id,
          link: .reconciledBalance(reconciliation: sheet.id, balance: row.id), now: countedAt)
        balance.transactionId = entry.id
        // Spending in «Сверка», and the money counted short gone from the cash from then on.
        set.add(entry, calendar: calendar)
      }
      set.reconciledBalances.append(balance)
    }
    return set
  }
}
