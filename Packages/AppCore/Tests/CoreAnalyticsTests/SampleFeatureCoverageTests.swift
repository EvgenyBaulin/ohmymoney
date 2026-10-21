import CoreAccounting
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// Every seed of the sample carries every feature of accounts, and its numbers are the ones
/// the layer knows it wrote: the balances of the accounts, the spending and income of every
/// month, the money paid for others.
///
/// Twenty fixed seeds, half of them in Russian, six months each, the size of `make sample`; the
/// demo's year, with what it adds on top, is checked in the app's `DemoSetTests`. The balances
/// are checked against what the layer tracked itself, never against a rule of the app read back.
@Suite("Every seed of the sample shows every feature of accounts")
struct SampleFeatureCoverageTests {
  static let seeds: [UInt64] = (1...20).map { UInt64($0) * 7_919 + 20_260_918 }

  struct Case: Sendable, CustomTestStringConvertible {
    let seed: UInt64
    var language: String { seed % 2 == 0 ? "ru" : "en" }
    var testDescription: String { "seed \(seed) (\(language))" }
  }

  static let cases = seeds.map(Case.init)

  static func set(_ testCase: Case) -> SampleDataSet {
    SampleDataGenerator(seed: testCase.seed).generate(
      months: 6, endingOn: Synthetic.endingOn, calendar: Synthetic.calendar,
      language: testCase.language
    ).withAccounts(seed: testCase.seed, calendar: Synthetic.calendar, language: testCase.language)
  }

  /// What the database would give for the set, with the counts and settings of its accounts.
  static func dataset(_ set: SampleDataSet) -> Dataset {
    Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules)
  }

  /// The same history with every layer after its accounts: cards and cashback, planning,
  /// references and a later count (`withEveryFeature`).
  static func layered(_ testCase: Case, demo: Bool = false) -> SampleDataSet {
    SampleDataGenerator(seed: testCase.seed).generate(
      months: 6, endingOn: Synthetic.endingOn, calendar: Synthetic.calendar,
      language: testCase.language
    ).withEveryFeature(
      seed: testCase.seed, calendar: Synthetic.calendar, language: testCase.language, demo: demo)
  }

  /// The end of the last day: every operation of the history has happened by then.
  static func end(of set: SampleDataSet) -> Date {
    Synthetic.calendar.startOfDay(Synthetic.calendar.adding(days: 1, to: set.lastDay))
  }

  static func balances(_ set: SampleDataSet) -> AccountBalances {
    AccountBalances.build(
      entries: set.entries, transfers: set.transfers, debtEntries: set.debtEntries,
      debts: Dictionary(uniqueKeysWithValues: set.debts.map { ($0.id, $0) }),
      reconciliations: set.reconciliations, balances: set.reconciledBalances,
      accounts: set.paymentMethods, tree: CategoryTree(set.categories), now: end(of: set),
      calendar: Synthetic.calendar)
  }

  // MARK: - Features

  @Test(arguments: cases)
  func everyFeatureIsThere(_ testCase: Case) throws {
    let set = Self.set(testCase)
    let accounts = Dictionary(uniqueKeysWithValues: set.paymentMethods.map { ($0.id, $0) })
    let entries = set.entries.filter { !$0.transaction.isDeleted }
    let byPart = Dictionary(
      uniqueKeysWithValues: entries.flatMap { entry in entry.parts.map { ($0.id, entry) } })
    let tree = CategoryTree(set.categories)

    // Groups: one in the summary, one out of it; the main account in the one that counts.
    #expect(set.accountGroups.count == 2)
    let outside = try #require(set.accountGroups.first { !$0.inSummary })
    let main = try #require(set.paymentMethods.first { $0.isDefault && !$0.archived })
    #expect(set.paymentMethods.filter(\.isDefault).count == 1)
    #expect(main.groupId != outside.id && main.groupId != nil)
    // Accounts: one holding four currencies, one in tenge only, both out of the summary.
    let multi = try #require(set.paymentMethods.first { $0.currencies.count == 4 })
    #expect(multi.groupId == outside.id)
    let tenge = try #require(set.paymentMethods.first { $0.currencies == [CurrencyCode("KZT")] })
    #expect(tenge.groupId == outside.id)
    #expect(set.paymentMethods.allSatisfy { $0.currency != nil })

    // Charges: rubles the history's card was charged, tenge a card of tenge was charged for
    // dollars, and rubles typed by hand above the fixed rate.
    let charged = entries.filter { $0.transaction.accountCurrency != nil }
    #expect(
      charged.contains {
        $0.transaction.accountCurrency == .rub
          && $0.transaction.accountAmountE4 == $0.transaction.amountRubE4
          && $0.transaction.rate == 95
      })
    #expect(charged.contains { $0.transaction.accountCurrency == CurrencyCode("KZT") })
    #expect(
      charged.contains {
        $0.transaction.accountCurrency == .rub && $0.transaction.rateSource == .manual
          && $0.transaction.rate != 95
          && $0.transaction.accountAmountE4 == $0.transaction.amountRubE4
      })

    // Transfers: an ATM withdrawal with its fee, an exchange inside one account, rubles sent to
    // an account in tenge.
    let withdrawals = set.transfers.filter { transfer in
      accounts[transfer.toAccountId]?.kind == .cash && !transfer.isExchange
    }
    #expect(!withdrawals.isEmpty)
    for withdrawal in withdrawals {
      let fee = try #require(
        entries.first { $0.transaction.externalId == TransferRules.feeKey(of: withdrawal.id) },
        "the withdrawal of \(withdrawal.occurredAt) has no fee")
      #expect(fee.transaction.amountE4.raw * 100 == withdrawal.fromAmountE4.raw)
      #expect(fee.transaction.paymentMethodId == withdrawal.fromAccountId)
    }
    #expect(set.transfers.contains { $0.isExchange && $0.fromAccountId == $0.toAccountId })
    #expect(set.transfers.contains { $0.isExchange && $0.fromAccountId != $0.toAccountId })
    for transfer in set.transfers {
      #expect(TransferRules.validate(transfer, accounts: set.paymentMethods) == nil)
    }

    // Counts: the opening of every key, and a sheet that finds 350 ₽ of cash missing and writes
    // the difference as a line of the books.
    let keys = Set(Self.liveKeys(set.paymentMethods))
    let opening = try #require(set.reconciliations.first { $0.kind == .opening })
    let openingRows = set.reconciledBalances.filter { $0.reconciliationId == opening.id }
    #expect(Set(openingRows.map(\.key)) == keys)
    #expect(openingRows.allSatisfy { $0.isStartingPoint && $0.actualE4.raw > 0 })
    let sheet = try #require(set.reconciliations.first { $0.kind == .accounts })
    let sheetRows = set.reconciledBalances.filter { $0.reconciliationId == sheet.id }
    #expect(Set(sheetRows.map(\.key)) == keys)
    let short = sheetRows.filter { $0.differenceE4 != .zero }
    #expect(short.count == 1)
    let difference = try #require(short.first)
    #expect(difference.differenceE4 == AmountE4(whole: -350))
    #expect(difference.currency == .rub && accounts[difference.accountId]?.kind == .cash)
    let written = try #require(entries.first { $0.id == difference.transactionId })
    #expect(
      OperationLink(externalId: written.transaction.externalId)
        == .reconciledBalance(reconciliation: sheet.id, balance: difference.id))
    #expect(written.transaction.paymentMethodId == difference.accountId)

    // Refunds tied to their purchases: a whole one, part of one part of a split purchase, and
    // one made in the month after its purchase.
    let refunds = entries.filter { RefundRules.takesBack($0) }
    var whole = false
    var ofASplit = false
    var nextMonth = false
    for refund in refunds {
      for part in refund.parts {
        let target = try #require(part.refundOfPartId)
        let purchase = try #require(byPart[target])
        let taken = try #require(purchase.parts.first { $0.id == target })
        #expect(RefundRules.isRefundable(part: taken, in: purchase, tree: tree))
        #expect(refund.transaction.currency == purchase.transaction.currency)
        if part.amountE4 == taken.amountE4 { whole = true }
        if purchase.isSplit, part.amountE4 < taken.amountE4 { ofASplit = true }
        let calendar = Synthetic.calendar
        if calendar.day(of: refund.transaction.occurredAt).monthKey
          != calendar.day(of: purchase.transaction.occurredAt).monthKey
        {
          nextMonth = true
        }
      }
    }
    #expect(whole && ofASplit && nextMonth)

    // Money back: part of a part still owed after it, and dollars that close a part in dollars
    // at another rate with no surplus.
    let linked = Dictionary(grouping: set.links, by: \.partId)
    let partlyBack = entries.flatMap(\.parts).filter { part in
      part.reimbursable && part.reimbursementStatus == .expected
        && !(linked[part.id] ?? []).isEmpty
    }
    #expect(!partlyBack.isEmpty)
    for part in partlyBack {
      let back = AmountE4.sum((linked[part.id] ?? []).map(\.amountE4))
      #expect(back < part.amountRubE4)
    }
    let dollars = try #require(
      entries.first { entry in
        entry.transaction.kind == .reimbursement && entry.transaction.currency == .usd
          && set.links.contains { $0.reimbursementTxId == entry.id }
      })
    let dollarLink = try #require(set.links.first { $0.reimbursementTxId == dollars.id })
    let dollarPart = try #require(
      byPart[dollarLink.partId]?.parts.first { $0.id == dollarLink.partId })
    #expect(dollarPart.amountE4 == dollars.transaction.amountE4)
    #expect(dollarLink.amountE4 == dollarPart.amountRubE4)
    #expect(dollars.transaction.amountRubE4 != dollarPart.amountRubE4)
    #expect(dollarPart.reimbursementStatus == .returned)
    let reimbursement = dollars.id.uuidString.lowercased()
    #expect(!entries.contains { $0.transaction.externalId == "reimb:\(reimbursement):surplus" })

    // A payment due once, twelve days after the last day.
    let once = try #require(set.planning.scheduled.first { $0.endDate != nil })
    #expect(once.endDate == once.nextDate)
    #expect(once.nextDate == Synthetic.calendar.adding(days: 12, to: set.lastDay))

    // A goal in dollars, fed in dollars from the account of four currencies and once in rubles.
    let goal = try #require(set.goals.first { $0.currency == .usd })
    let contributions = entries.filter { entry in entry.parts.contains { $0.goalId == goal.id } }
    #expect(
      contributions.contains {
        $0.transaction.currency == .usd && $0.transaction.paymentMethodId == multi.id
      })
    #expect(contributions.filter { $0.transaction.currency == .rub }.count == 1)

    // Budgets of the coming birthday and New Year.
    let coming = set.events.filter { $0.startDate > set.lastDay && $0.budgetE4 != nil }
    #expect(Set(coming.map(\.kind)) == [.birthday, .newYear])

    // Money borrowed through a debt journal, onto an account, at a moment.
    #expect(
      set.debtEntries.contains {
        $0.kind == .borrowed && $0.transactionId == nil && $0.paymentMethodId != nil
          && $0.occurredAt != nil
      })

    // The settings of a database whose accounts are set up.
    #expect(set.settings[AccountSettings.setupKey] == "done")
    #expect(set.settings[AccountSettings.defaultCurrencyKey] == "RUB")
    let settings = AccountSettings(storedValues: set.settings)
    #expect(settings.setup == .done)
    #expect(tree[settings.transferFeeCategoryId ?? UUID()] != nil)
  }

  /// Every operation names its account, and one in a currency its account does not hold says
  /// what the account was charged in one it does — the rule the database holds every write to.
  @Test(arguments: cases)
  func everyOperationIsOnAnAccountThatCanCarryIt(_ testCase: Case) {
    let set = Self.set(testCase)
    let accounts = Dictionary(uniqueKeysWithValues: set.paymentMethods.map { ($0.id, $0) })
    let tree = CategoryTree(set.categories)
    for entry in set.entries {
      #expect(entry.isBalanced)
      #expect(AmountE4.sum(entry.parts.map(\.amountRubE4)) == entry.transaction.amountRubE4)
      guard let account = entry.transaction.paymentMethodId.flatMap({ accounts[$0] }) else {
        Issue.record("\(entry.id) is on no account")
        continue
      }
      let transaction = entry.transaction
      guard !account.holds(transaction.currency), AccountBalances.movesMoney(entry, tree: tree)
      else { continue }
      #expect(
        transaction.accountCurrency.map(account.holds) == true,
        "\(entry.id) says nothing of what its account was charged")
    }
  }

  // MARK: - Numbers

  /// The balances the app works out from the counts and the movements are the ones the layer
  /// kept while it wrote, and no account is ever below zero.
  @Test(arguments: cases)
  func theBalancesAreTheOnesTheLayerKept(_ testCase: Case) {
    let set = Self.set(testCase)
    let balances = Self.balances(set)
    Self.expectTheBalancesKept(set, balances: balances, label: testCase.testDescription)
    // Right after the sheet, every balance is what it counted.
    guard let sheet = set.reconciliations.first(where: { $0.kind == .accounts }),
      let at = sheet.reconciledAt
    else {
      Issue.record("no sheet")
      return
    }
    for row in set.reconciledBalances where row.reconciliationId == sheet.id {
      #expect(balances.balance(row.key, at: at) == row.actualE4)
    }
  }

  /// Every month's spending, income and money paid for others are what the layer and the
  /// history under it wrote: a refund makes its purchase's month cheaper, money back of part of
  /// a part leaves the rest waiting, a difference of a count is spending in «Сверка».
  @Test(arguments: cases)
  func everyMonthIsWhatTheLayerWrote(_ testCase: Case) throws {
    Self.expectEveryMonthKnown(Self.set(testCase), label: testCase.testDescription)
  }

  /// The balances the app works out are the ones the layers kept, and no account but a credit
  /// card — one whose starting balance was below zero, or one with the terms of a credit card —
  /// is ever below zero.
  static func expectTheBalancesKept(
    _ set: SampleDataSet, balances: AccountBalances, label: String
  ) {
    let creditCards = Set(set.paymentMethods.filter(\.isCreditCard).map(\.id))
    let owing = Set(
      set.reconciledBalances.filter {
        ($0.isStartingPoint && $0.actualE4.isNegative) || creditCards.contains($0.accountId)
      }.map(\.key))
    #expect(balances.unassignedOperations == 0, "\(label)")
    #expect(Set(balances.keys) == Set(set.accountExpectations.keys), "\(label)")
    for key in balances.keys {
      #expect(balances[key]?.amountE4 == set.accountExpectations[key], "\(label): \(key)")
      guard !owing.contains(key) else { continue }
      let moments = (balances[key]?.movements ?? []).map(\.at)
      for moment in moments {
        let balance = balances.balance(key, at: moment)
        #expect((balance?.raw ?? -1) >= 0, "\(label): \(key) below zero at \(moment)")
      }
    }
  }

  /// Every month's spending, income and money paid for others are what the layers wrote.
  static func expectEveryMonthKnown(_ set: SampleDataSet, label testLabel: String) {
    let ledger = Ledger(dataset: Self.dataset(set), calendar: Synthetic.calendar)
    for month in Synthetic.months(of: set) {
      let known = set.expectations[month]
      let period = Period.month(month)
      let label = "\(testLabel), \(month.iso)"
      #expect(ledger.expenses(in: period.range) == known.myExpenses, "\(label): my expenses")
      let categories = CategoryBreakdown(ledger: ledger, period: period, kind: .expense)
      var byRoot: [ReportKey: AmountE4] = [:]
      for (root, amount) in known.byRootCategory where !amount.isZero {
        byRoot[root.map(ReportKey.category) ?? .uncategorized] = amount
      }
      let found = Dictionary(
        categories.nodes.filter { !$0.amount.isZero }.map { ($0.key, $0.amount) },
        uniquingKeysWith: { first, _ in first })
      #expect(found == byRoot, "\(label): by category")
      #expect(ledger.income(in: period) == known.income, "\(label): income")
      let others = OthersReport(ledger: ledger, period: period).totals
      #expect(
        [others.paid, others.returned, others.writtenOff, others.waiting, others.shortfall]
          == [
            known.forOthers.paid, known.forOthers.returned, known.forOthers.writtenOff,
            known.forOthers.waiting, known.forOthers.shortfall,
          ], "\(label): for others")
    }
  }

  // MARK: - The layers after the accounts

  /// Every seed with every layer shows cards and cashback, the planning of an event and of a
  /// goal paid ahead, an expected salary on an account, an archived place, a one-day event, a
  /// credit card below zero and a later count whose difference follows the books.
  @Test(arguments: cases)
  func everyFeatureOfTheLayersAfterTheAccountsIsThere(_ testCase: Case) throws {
    let set = Self.layered(testCase)
    let label = testCase.testDescription
    let accounts = Dictionary(uniqueKeysWithValues: set.paymentMethods.map { ($0.id, $0) })
    let entries = set.entries.filter { !$0.transaction.isDeleted }
    let calendar = Synthetic.calendar
    let main = try #require(set.paymentMethods.first { $0.isDefault && !$0.archived })

    // Cards: one named like every live card account, two on the main account.
    for account in set.paymentMethods where account.kind == .card && !account.archived {
      #expect(
        set.cards.contains { $0.id == CardsMigration.cardId(forAccount: account.id) },
        "\(label): \(account.name)")
    }
    let own = try #require(set.cards.first { $0.id == CardsMigration.cardId(forAccount: main.id) })
    #expect(set.cards.filter { $0.accountId == main.id }.count == 2, "\(label)")

    // Cashback rules of both kinds on the main account, which its cards follow, a purchase with
    // the cashback typed over them, and the cashback received naming the card it came to.
    let month = set.lastDay.monthKey
    #expect(
      set.cashbackRules.allSatisfy { $0.accountId == main.id && $0.cardId == nil }, "\(label)")
    #expect(set.cashbackRules.contains { $0.month == nil && $0.categoryId == nil }, "\(label)")
    #expect(set.cashbackRules.contains { $0.month == nil && $0.categoryId != nil }, "\(label)")
    #expect(set.cashbackRules.contains { $0.month == month }, "\(label)")
    #expect(set.cashbackRules.contains { $0.month == month.previous }, "\(label)")
    #expect(
      entries.contains { $0.transaction.keptCashback != nil && $0.transaction.cardId == own.id },
      "\(label): a purchase with its cashback typed")
    let received = entries.filter { entry in
      entry.transaction.kind == .income && entry.transaction.cardId != nil
        && entry.parts.allSatisfy { $0.categoryId == set.cashbackCategoryId }
    }
    #expect(!received.isEmpty, "\(label): cashback naming its card")
    let ledger = Ledger(dataset: Self.dataset(set), calendar: calendar)
    let report = CashbackReport(ledger: ledger, period: .month(month.previous))
    let line = report.cells.first {
      $0.holder == CashbackHolderKey(accountId: main.id, cardId: own.id)
    }
    #expect((line?.expectedRub.raw ?? 0) > 0, "\(label): cashback expected on the main card")
    #expect((line?.receivedRub.raw ?? 0) > 0, "\(label): cashback received on the main card")

    // A hotel paid once, tied to an event with a budget, on the main card.
    let planning = set.planning
    let hotel = try #require(planning.scheduled.first { $0.eventId != nil }, "\(label)")
    let event = try #require(set.events.first { $0.id == hotel.eventId })
    #expect(event.budgetE4 != nil && hotel.endDate == hotel.nextDate, "\(label)")
    #expect(hotel.cardId == own.id && hotel.paymentMethodId == main.id, "\(label)")
    #expect((hotel.nextDate ?? event.endDate) <= event.endDate, "\(label)")
    #expect(!planning.scheduled.contains { ($0.nextDate ?? set.lastDay) < set.lastDay }, "\(label)")

    // A goal whose plan starts in a month and a deposit ahead of it.
    let goal = try #require(set.goals.first { $0.planStartMonth != nil }, "\(label)")
    let state = try #require(
      GoalMath.planState(goal: goal, rows: ledger.rows, month: month, rates: .empty))
    #expect(state.creditIn.raw > 0, "\(label): paid ahead of the plan")

    // The salary expected on an account.
    #expect(
      planning.expected.contains { $0.kind == .recurring && $0.paymentMethodId == main.id },
      "\(label)")

    // An archived place with one operation, and an event of one day with its purchase.
    let archived = try #require(set.places.first { $0.archived }, "\(label)")
    #expect(entries.filter { $0.transaction.placeId == archived.id }.count == 1, "\(label)")
    let oneDay = try #require(
      set.events.first { event in
        event.startDate == event.endDate && event.kind == .other && event.budgetE4 != nil
      }, "\(label)")
    #expect(entries.contains { $0.parts.contains { $0.eventId == oneDay.id } }, "\(label)")

    // A credit card that started below zero and ends below zero.
    let balances = Self.balances(set)
    let credit = try #require(
      set.reconciledBalances.first { $0.isStartingPoint && $0.actualE4.isNegative }, "\(label)")
    #expect(accounts[credit.accountId]?.kind == .card, "\(label)")
    #expect((balances[credit.key]?.amountE4?.raw ?? 0) < 0, "\(label): below zero at the end")

    // A later count that records its difference with the ids derived from the count, and an
    // operation written after it, dated inside its window.
    let later = try #require(set.reconciliations.last { $0.kind == .accounts }, "\(label)")
    let countedAt = try #require(later.reconciledAt)
    let rows = set.reconciledBalances.filter { $0.reconciliationId == later.id }
    let different = try #require(rows.first { !($0.differenceE4?.isZero ?? true) }, "\(label)")
    #expect(different.recordsDifference == true, "\(label)")
    #expect(
      different.transactionId == ReconcileDifferenceIds.operation(forCount: different.id),
      "\(label)")
    #expect(entries.contains { $0.id == different.transactionId }, "\(label)")
    let previous = try #require(balances.anchors(different.key).dropLast().last)
    #expect(
      entries.contains { entry in
        entry.transaction.paymentMethodId == different.accountId
          && entry.transaction.createdAt > countedAt && entry.transaction.occurredAt < countedAt
          && entry.transaction.occurredAt > previous.at
      }, "\(label): an operation entered after the count, inside its window")
    #expect(
      set.transfers.contains { transfer in
        transfer.to == credit.key && calendar.day(of: transfer.occurredAt) == later.date
          && transfer.occurredAt < countedAt
      }, "\(label): the card paid on the day of the count, before it")
  }

  /// Every count that follows the books is written as following them: the settle of each finds
  /// nothing to change — no expected balance, no difference, no operation.
  @Test(arguments: cases)
  func everyCountOfTheLayersIsSettled(_ testCase: Case) throws {
    let set = Self.layered(testCase)
    let balances = Self.balances(set)
    let tree = CategoryTree(set.categories)
    let expense = try #require(
      set.settings[PlanningSettings.reconcileExpenseCategoryKey].flatMap(UUID.init))
    let income = try #require(
      set.settings[PlanningSettings.reconcileIncomeCategoryKey].flatMap(UUID.init))
    let live = LiveCounts.liveIds(
      reconciliations: set.reconciliations, balances: set.reconciledBalances, frozen: [])
    let moments = Dictionary(
      uniqueKeysWithValues: set.reconciliations.map { ($0.id, $0.reconciledAt) })
    let later = try #require(set.reconciliations.last { $0.kind == .accounts })
    #expect(
      set.reconciledBalances.filter { $0.reconciliationId == later.id }.allSatisfy {
        live.contains($0.id)
      })
    for count in set.reconciledBalances where live.contains(count.id) {
      let expected = try #require(balances.expected(forCount: count.id))
      let operation = count.transactionId.flatMap { id in set.entries.first { $0.id == id } }
      let settled = LiveCounts.settle(
        CountState(
          count: count, countAt: try #require(moments[count.reconciliationId] ?? nil),
          operation: operation),
        expected: expected, rate: nil,
        categories: ReconcileCategories(expense: expense, income: income), tree: tree,
        now: Self.end(of: set))
      #expect(!settled.countChanged, "\(testCase.testDescription): \(count.key)")
      #expect(settled.operation == .none, "\(testCase.testDescription): \(count.key)")
    }
  }

  @Test(arguments: cases)
  func theBalancesOfEveryLayerAreTheOnesTheLayersKept(_ testCase: Case) {
    let set = Self.layered(testCase)
    Self.expectTheBalancesKept(
      set, balances: Self.balances(set), label: testCase.testDescription)
  }

  @Test(arguments: cases)
  func everyMonthOfEveryLayerIsWhatTheLayersWrote(_ testCase: Case) {
    Self.expectEveryMonthKnown(Self.layered(testCase), label: testCase.testDescription)
  }

  static func liveKeys(_ accounts: [PaymentMethod]) -> [BalanceKey] {
    accounts.filter { !$0.archived }.flatMap { account in
      account.currencies.map { BalanceKey(accountId: account.id, currency: $0) }
    }
  }
}
