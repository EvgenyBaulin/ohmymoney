import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.
@Suite("A card's separate balance round trip and undo")
struct CardOwnBalanceWriteTests {
  let fixture = CardToCreditCardWriteTests()

  @Test(arguments: [
    CardPastOperations.all, .none, .onAndAfter(DateOnly(year: 2026, month: 3, day: 1)),
  ])
  func separationRoundTripsAndUndoesInOneStep(_ past: CardPastOperations) throws {
    let book = try fixture.book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let plan = try CardOwnBalance.plan(
      separating: book.black.id, past: past, cards: [book.black, book.plain],
      accounts: [book.debit]
    ).get()
    let repository = PlanningRepository(writer: book.stack.writer, liveCounts: fixture.context)
    let undo = try repository.apply(.cardConversion(plan, at: fixture.at("2026-04-01")))
    let account = try book.stack.writer.read { db in
      try PaymentMethod.fetchOne(db, key: plan.account.id.uuidString)
    }
    #expect(account == plan.account)
    #expect(account?.credit == nil && account?.bankId == book.bank.id)
    let (payment, rule, conditions, offers) = try book.stack.writer.read { db in
      (
        try ScheduledPayment.fetchOne(db, key: book.payment.id.uuidString),
        try CashbackRule.fetchOne(db, key: book.cardRule.id.uuidString),
        try String.fetchAll(db, sql: "SELECT payment_method_id FROM bank_conditions"),
        try String.fetchAll(db, sql: "SELECT payment_method_id FROM cashback_offers")
      )
    }
    #expect(payment?.paymentMethodId == plan.account.id)
    #expect(rule?.accountId == plan.account.id)
    #expect(conditions == [plan.account.id.uuidString] && offers == [plan.account.id.uuidString])
    #expect(try fixture.cardsOfOtherAccounts(book.stack) == 0)
    let operations = try fixture.operations(book.stack)
    for entry in [book.early, book.late, book.binned] {
      let moves = plan.moves(entry.transaction, calendar: .utc)
      #expect(operations[entry.id]?.paymentMethodId == (moves ? plan.account.id : book.debit.id))
      #expect(operations[entry.id]?.cardId == (moves ? book.black.id : plan.leftCard.id))
    }
    #expect(undo.cardConversion != nil)
    try repository.revert(undo, at: fixture.at("2026-04-02"))
    #expect(try PlanningUndoPropertyTests.contents(book.stack) == before)
    _ = try repository.apply(try #require(undo.change))

    // Each account can be counted independently; neither count overwrites the other.
    try fixture.count(book.debit.id, 12_000, at: fixture.at("2026-04-02"), stack: book.stack)
    try fixture.count(plan.account.id, 3_000, at: fixture.at("2026-04-02"), stack: book.stack)
    #expect(
      try fixture.balance(book.debit.id, book.stack, at: fixture.at("2026-04-03"))
        == AmountE4(whole: 12_000))
    #expect(
      try fixture.balance(plan.account.id, book.stack, at: fixture.at("2026-04-03"))
        == AmountE4(whole: 3_000))
    #expect(try DatabaseCheck.run(book.stack.writer).isHealthy)
  }

  @Test func theSwitchStateAndOperationsReachTheOtherDevice() throws {
    let mac = try TestDevice("own-mac")
    let phone = try TestDevice("own-phone")
    let folder = InMemoryFolder()
    let book = try fixture.book(mac.stack)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    let plan = try CardOwnBalance.plan(
      separating: book.black.id, past: .onAndAfter(DateOnly(year: 2026, month: 3, day: 1)),
      cards: [book.black, book.plain], accounts: [book.debit]
    ).get()
    _ = try PlanningRepository(writer: mac.stack.writer, liveCounts: fixture.context)
      .apply(.cardConversion(plan, at: fixture.at("2026-04-01")))
    _ = try mac.exchange.exchange(with: folder)
    let result = try phone.exchange.exchange(with: folder)
    #expect(result.deferred == 0 && result.conflictsOpen == 0)
    let (cards, accounts) = try phone.stack.writer.read { db in
      (try PaymentCard.fetchAll(db), try PaymentMethod.fetchAll(db))
    }
    let card = try #require(cards.first { $0.id == book.black.id })
    #expect(CardOwnBalance.isOn(for: card, accounts: accounts))
    #expect(accounts.first { $0.id == card.accountId } == plan.account)
    #expect(try fixture.operations(phone.stack)[book.late.id]?.paymentMethodId == plan.account.id)
    #expect(try fixture.cardsOfOtherAccounts(phone.stack) == 0)
  }

  @Test func switchingOffMergesTheWholeBalanceAndOneUndoRestoresIt() async throws {
    let book = try fixture.book()
    let plan = try CardOwnBalance.plan(
      separating: book.black.id, past: .all, cards: [book.black, book.plain],
      accounts: [book.debit]
    ).get()
    let repository = PlanningRepository(writer: book.stack.writer, liveCounts: fixture.context)
    _ = try repository.apply(.cardConversion(plan, at: fixture.at("2026-04-01")))
    try fixture.count(book.debit.id, 12_000, at: fixture.at("2026-04-02"), stack: book.stack)
    try fixture.count(plan.account.id, 3_000, at: fixture.at("2026-04-02"), stack: book.stack)
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let dataset = try await DatasetRepository(writer: book.stack.writer).load(version: 0)
    let now = fixture.at("2026-04-03")
    let summary = AccountsSnapshot.build(
      dataset: dataset, now: now, calendar: .utc, rubPerUnit: [:], localeIdentifier: "en_US")
    let lines = summary.sections.flatMap(\.accounts)
    #expect(lines.first { $0.account.id == book.debit.id }?.totalRub == AmountE4(whole: 12_000))
    #expect(lines.first { $0.account.id == plan.account.id }?.totalRub == AmountE4(whole: 3_000))
    let reconcile = AccountReconciliation.rows(
      accounts: dataset.paymentMethods, groups: dataset.accountGroups,
      balances: summary.balances, at: now, locale: Locale(identifier: "en_US"))
    #expect(
      reconcile.first { $0.key.accountId == plan.account.id }?.expected == AmountE4(whole: 3_000))
    #expect(
      reconcile.first { $0.key.accountId == book.debit.id }?.expected == AmountE4(whole: 12_000))
    let capital = NetWorth.build(
      ledger: Ledger(dataset: dataset, calendar: .utc), balances: summary.balances,
      debtsJournal: [], assets: [], valuations: [], today: CalendarContext.utc.day(of: now),
      now: now, rubPerUnit: [:], dayRates: .empty)
    #expect(
      capital.breakdown.have.first { $0.source == .account(plan.account.id) }?.amountRub
        == AmountE4(whole: 3_000))
    #expect(capital.now.accountsRub == AmountE4(whole: 15_000))
    let (merge, needs) = AccountMerge.plan(
      source: plan.account, target: plan.former, transfers: dataset.transfers,
      balances: summary.balances, at: now)
    #expect(needs.isEmpty)
    let undo = try repository.apply(PlanningChange(at: now, mergingAccounts: merge))
    let (card, accounts) = try await book.stack.writer.read { db in
      (try PaymentCard.fetchOne(db, key: book.black.id.uuidString), try PaymentMethod.fetchAll(db))
    }
    let shared = try #require(card)
    #expect(!CardOwnBalance.isOn(for: shared, accounts: accounts))
    #expect(shared.accountId == book.debit.id)
    #expect(try fixture.balance(book.debit.id, book.stack, at: now) == AmountE4(whole: 15_000))
    #expect(try fixture.cardsOfOtherAccounts(book.stack) == 0)
    // A second separation can reuse the archived, emptied account without a schema flag.
    let again = try CardOwnBalance.plan(
      separating: shared.id, cards: [shared, book.plain], accounts: accounts
    ).get()
    let separateUndo = try repository.apply(.cardConversion(again, at: now))
    try repository.revert(separateUndo, at: now)
    try repository.revert(undo, at: now)
    #expect(try PlanningUndoPropertyTests.contents(book.stack) == before)
  }
}
