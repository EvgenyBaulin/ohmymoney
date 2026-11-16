import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// A card of a debit account turned into a credit card of its own is one planning change
/// (`PlanningChange.cardConversion`): the credit card is a new account of the same bank with
/// the terms, the card moves to it with its rules, scheduled payments, conditions and offers,
/// the operations it paid go as the owner chose — the rest name an archived card left on the
/// former account —, and ⌘Z leaves the database exactly as it was.
@Suite("A card turned into a credit card of its own, and its undo")
struct CardToCreditCardWriteTests {
  let context = LiveCountsContext(calendar: .utc, categoryName: "Reconciliation")
  let terms = CreditCardTerms(
    limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25),
    purchaseRate: Decimal(string: "29.9"), minPercent: Decimal(8),
    minFloorE4: AmountE4(whole: 600))

  struct Book {
    var stack: DatabaseStack
    var bank: Bank
    var debit: PaymentMethod
    var black: PaymentCard
    var plain: PaymentCard
    var cafe: CoreKit.Category
    var early: TransactionEntry
    var late: TransactionEntry
    var binned: TransactionEntry
    var onPlain: TransactionEntry
    var payment: ScheduledPayment
    var cardRule: CashbackRule
    var accountRule: CashbackRule
  }

  func at(_ iso: String, hour: Int = 12) -> Date {
    CalendarContext.utc.startOfDay(DateOnly(iso: iso) ?? DateOnly(year: 2026, month: 1, day: 1))
      .addingTimeInterval(TimeInterval(hour * 3_600))
  }

  func purchase(
    _ whole: Int64, on iso: String, account: UUID, card: UUID?, cafe: UUID
  ) -> TransactionEntry {
    let stamp = at(iso)
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: stamp, currency: .rub, amountE4: AmountE4(whole: whole),
      paymentMethodId: account, createdAt: stamp, updatedAt: stamp, cardId: card)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, categoryId: cafe, amountE4: AmountE4(whole: whole))
      ])
  }

  /// «Т-Банк» with the cards «Кредитная карта» (main) and «Блэк»; the first count on 1 January
  /// at 50,000, purchases with «Кредитная карта» on 10 January and 5 March, one more on
  /// 6 March in the bin, one with «Блэк»; a count on 20 March at 40,000 that keeps its
  /// difference.
  func book(_ stack: DatabaseStack? = nil) throws -> Book {
    let stack = try stack ?? TestSupport.makeStack()
    let bank = Bank(name: "Т-Банк")
    var debit = PaymentMethod(
      name: "Т-Банк", kind: .card, currency: .rub, isDefault: true, bankId: bank.id)
    let black = PaymentCard(accountId: debit.id, name: "Кредитная карта", aliases: ["Платинум"])
    let plain = PaymentCard(accountId: debit.id, name: "Блэк")
    debit.mainCardId = black.id
    let cafe = CoreKit.Category(kind: .expense, name: "Cafe")
    let percent = { (e4: Int64) in CashbackPercent(e4: e4)! }
    let cardRule = CashbackRule(
      accountId: debit.id, cardId: black.id, categoryId: cafe.id, percent: percent(50_000))
    let accountRule = CashbackRule(accountId: debit.id, percent: percent(10_000))
    let payment = ScheduledPayment(
      name: "Phone", amountE4: AmountE4(whole: 500), paymentMethodId: debit.id,
      cardId: black.id)
    let planning = PlanningRepository(writer: stack.writer, liveCounts: context)
    _ = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(
          categories: [cafe], scheduled: [payment], paymentMethods: [debit],
          cards: [black, plain], cashbackRules: [cardRule, accountRule], banks: [bank]),
        at: at("2025-12-31")))
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO bank_conditions (id, payment_method_id, card_id, currency, free_cash_e4)
          VALUES ('C0000000-0000-4000-8000-000000000001', ?, ?, 'RUB', 1000000000);
          INSERT INTO cashback_offers (id, payment_method_id, card_id, month, label, percent_e4)
          VALUES ('C0000000-0000-4000-8000-000000000002', ?, ?, '2026-03', 'Кафе', 50000);
          """,
        arguments: [
          debit.id.uuidString, black.id.uuidString, debit.id.uuidString, black.id.uuidString,
        ])
    }
    try count(debit.id, 50_000, at: at("2026-01-01", hour: 9), stack: stack)
    let transactions = TransactionRepository(writer: stack.writer, liveCounts: context)
    let early = try transactions.save(
      purchase(1_000, on: "2026-01-10", account: debit.id, card: black.id, cafe: cafe.id))
    let late = try transactions.save(
      purchase(2_000, on: "2026-03-05", account: debit.id, card: black.id, cafe: cafe.id))
    let binned = try transactions.save(
      purchase(300, on: "2026-03-06", account: debit.id, card: black.id, cafe: cafe.id))
    _ = try transactions.softDelete(id: binned.id, at: at("2026-03-07"))
    let onPlain = try transactions.save(
      purchase(400, on: "2026-03-08", account: debit.id, card: plain.id, cafe: cafe.id))
    try count(debit.id, 40_000, at: at("2026-03-20", hour: 10), stack: stack)
    return Book(
      stack: stack, bank: bank, debit: debit, black: black, plain: plain, cafe: cafe,
      early: early, late: late, binned: binned, onPlain: onPlain, payment: payment,
      cardRule: cardRule, accountRule: accountRule)
  }

  /// A count saved the way the reconcile sheet saves it, keeping its difference.
  func count(_ account: UUID, _ whole: Int64, at moment: Date, stack: DatabaseStack) throws {
    let key = BalanceKey(accountId: account, currency: .rub)
    let reconciliation = Reconciliation(
      date: CalendarContext.utc.day(of: moment), reconciledAt: moment, actualTotalRubE4: .zero,
      kind: .accounts)
    let expected = try stack.writer.read { db in
      try LiveCountsWriter.balance(of: key, at: moment, context: context, db: db)
    }
    let actual = AmountE4(whole: whole)
    var upsert = PlanningRows.empty
    upsert.reconciliations = [reconciliation]
    upsert.reconciledBalances = [
      ReconciledBalance(
        reconciliationId: reconciliation.id, accountId: account, currency: .rub,
        actualE4: actual, expectedE4: expected, differenceE4: expected.map { actual - $0 },
        recordsDifference: expected == nil ? nil : true)
    ]
    _ = try PlanningRepository(writer: stack.writer, liveCounts: context).apply(
      PlanningChange(upsert: upsert, at: moment, settles: [key]))
  }

  func plan(_ book: Book, _ past: CardPastOperations) throws -> CreditCardConversionPlan {
    let (cards, accounts) = try book.stack.writer.read { db in
      (try PaymentCard.fetchAll(db), try PaymentMethod.fetchAll(db))
    }
    return try CreditCardConversion.plan(
      converting: book.black.id, terms: terms, past: past, cards: cards, accounts: accounts
    ).get()
  }

  /// No row anywhere names a card of another account than its own.
  func cardsOfOtherAccounts(_ stack: DatabaseStack) throws -> Int {
    try stack.writer.read { db in
      var total = 0
      for table in [
        "transactions", "scheduled_payments", "cashback_rules", "bank_conditions",
        "cashback_offers",
      ] {
        total +=
          try Int.fetchOne(
            db,
            sql: """
              SELECT COUNT(*) FROM \(table) t JOIN cards c ON c.id = t.card_id
              WHERE c.payment_method_id IS NOT t.payment_method_id
              """) ?? 0
      }
      total +=
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM payment_methods p JOIN cards c ON c.id = p.main_card_id
            WHERE c.payment_method_id <> p.id
            """) ?? 0
      return total
    }
  }

  func operations(_ stack: DatabaseStack) throws -> [UUID: CoreKit.Transaction] {
    let rows = try stack.writer.read { db in try CoreKit.Transaction.fetchAll(db) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
  }

  func balance(_ account: UUID, _ stack: DatabaseStack, at moment: Date) throws -> AmountE4? {
    try stack.writer.read { db in
      try LiveCountsWriter.balance(
        of: BalanceKey(accountId: account, currency: .rub), at: moment, context: context, db: db)
    }
  }

  @Test func allMovesEveryOperationOfTheCardAndItsUndoLeavesTheDatabaseAsItWas() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let now = at("2026-04-01")
    let debitBalance = try balance(book.debit.id, book.stack, at: now)
    let binnedStamp = try operations(book.stack)[book.binned.id]?.updatedAt
    let plan = try plan(book, .all)
    let planning = PlanningRepository(writer: book.stack.writer, liveCounts: context)
    let undo = try planning.apply(PlanningChange.cardConversion(plan, at: now))

    let (accounts, cards, payment, rules, conditions, offers) = try book.stack.writer.read {
      db in
      (
        try PaymentMethod.fetchAll(db), try PaymentCard.fetchAll(db),
        try ScheduledPayment.fetchOne(db, key: book.payment.id.uuidString),
        try CashbackRule.fetchAll(db),
        try String.fetchAll(db, sql: "SELECT payment_method_id FROM bank_conditions"),
        try String.fetchAll(db, sql: "SELECT payment_method_id FROM cashback_offers")
      )
    }
    let credit = try #require(accounts.first { $0.id == plan.account.id })
    #expect(credit.credit == terms && credit.bankId == book.bank.id)
    #expect(credit.mainCardId == book.black.id && credit.name == "Кредитная карта")
    let former = try #require(accounts.first { $0.id == book.debit.id })
    #expect(former.mainCardId == nil && former.isDefault && former.credit == nil)
    #expect(cards.count == 2, "nothing stays, so no card is left behind")
    #expect(cards.first { $0.id == book.black.id }?.accountId == credit.id)
    #expect(cards.first { $0.id == book.plain.id }?.accountId == book.debit.id)
    #expect(payment?.paymentMethodId == credit.id && payment?.cardId == book.black.id)
    #expect(rules.first { $0.id == book.cardRule.id }?.accountId == credit.id)
    #expect(rules.first { $0.id == book.accountRule.id }?.accountId == book.debit.id)
    #expect(conditions == [credit.id.uuidString] && offers == [credit.id.uuidString])

    let byId = try operations(book.stack)
    for moved in [book.early, book.late, book.binned] {
      #expect(byId[moved.id]?.paymentMethodId == credit.id)
      #expect(byId[moved.id]?.cardId == book.black.id)
    }
    #expect(byId[book.binned.id]?.isDeleted == true, "an operation in the bin moves too")
    #expect(byId[book.late.id]?.updatedAt == now, "a live one is stamped as an edit is")
    #expect(byId[book.binned.id]?.updatedAt == binnedStamp, "the bin keeps its moment")
    #expect(byId[book.onPlain.id]?.paymentMethodId == book.debit.id)
    #expect(try cardsOfOtherAccounts(book.stack) == 0)
    #expect(
      Set(undo.cardConversion?.movedOperationIds ?? []) == [
        book.early.id, book.late.id, book.binned.id,
      ])
    #expect(undo.cardConversion?.leftOperationIds == [])
    #expect(Set(undo.written.map(\.id)) == [book.early.id, book.late.id])
    // The money counted on the former account stays as counted; the credit card was never
    // counted, so it has no balance until the owner counts it.
    #expect(try balance(book.debit.id, book.stack, at: now) == debitBalance)
    #expect(try balance(credit.id, book.stack, at: now) == nil)
    #expect(try DatabaseCheck.run(book.stack.writer).isHealthy)

    try planning.revert(undo, at: at("2026-04-02"))
    let after = try PlanningUndoPropertyTests.contents(book.stack)
    #expect(after == before, "\(PlanningUndoPropertyTests.difference(before, after))")

    // ⇧⌘Z makes the same rows again.
    let again = try planning.apply(try #require(undo.change))
    #expect(try operations(book.stack)[book.late.id]?.paymentMethodId == plan.account.id)
    #expect(again.cardConversion?.movedOperationIds.count == 3)
    #expect(try cardsOfOtherAccounts(book.stack) == 0)
  }

  @Test func onAndAfterLeavesTheEarlierOperationsOnTheFormerAccountWithTheLeftCard() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let plan = try plan(book, .onAndAfter(DateOnly(year: 2026, month: 3, day: 1)))
    let planning = PlanningRepository(writer: book.stack.writer, liveCounts: context)
    let undo = try planning.apply(PlanningChange.cardConversion(plan, at: at("2026-04-01")))

    let byId = try operations(book.stack)
    #expect(byId[book.early.id]?.paymentMethodId == book.debit.id)
    #expect(byId[book.early.id]?.cardId == plan.leftCard.id)
    #expect(byId[book.early.id]?.updatedAt == book.early.transaction.updatedAt, "not an edit")
    #expect(byId[book.late.id]?.paymentMethodId == plan.account.id)
    #expect(byId[book.binned.id]?.paymentMethodId == plan.account.id)
    let left = try book.stack.writer.read { db in
      try PaymentCard.fetchOne(db, key: plan.leftCard.id.uuidString)
    }
    #expect(left?.archived == true && left?.accountId == book.debit.id)
    #expect(left?.name == "Кредитная карта")
    #expect(undo.cardConversion?.leftOperationIds == [book.early.id])
    #expect(try cardsOfOtherAccounts(book.stack) == 0)
    #expect(try DatabaseCheck.run(book.stack.writer).isHealthy)

    try planning.revert(undo, at: at("2026-04-02"))
    let after = try PlanningUndoPropertyTests.contents(book.stack)
    #expect(after == before, "\(PlanningUndoPropertyTests.difference(before, after))")
  }

  @Test func noneMovesTheCardAloneAndItsPastStays() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let now = at("2026-04-01")
    let debitBalance = try balance(book.debit.id, book.stack, at: now)
    let binnedStamp = try operations(book.stack)[book.binned.id]?.updatedAt
    let plan = try plan(book, .none)
    let planning = PlanningRepository(writer: book.stack.writer, liveCounts: context)
    let undo = try planning.apply(PlanningChange.cardConversion(plan, at: now))

    let byId = try operations(book.stack)
    for stayed in [book.early, book.late, book.binned] {
      #expect(byId[stayed.id]?.paymentMethodId == book.debit.id)
      #expect(byId[stayed.id]?.cardId == plan.leftCard.id)
    }
    #expect(byId[book.binned.id]?.updatedAt == binnedStamp, "the bin keeps its moment")
    #expect(undo.cardConversion?.movedOperationIds == [])
    #expect(undo.written.isEmpty)
    #expect(try balance(book.debit.id, book.stack, at: now) == debitBalance)
    #expect(try cardsOfOtherAccounts(book.stack) == 0)
    // The card and what is its own moved all the same.
    let payment = try book.stack.writer.read { db in
      try ScheduledPayment.fetchOne(db, key: book.payment.id.uuidString)
    }
    #expect(payment?.paymentMethodId == plan.account.id)

    try planning.revert(undo, at: at("2026-04-02"))
    let after = try PlanningUndoPropertyTests.contents(book.stack)
    #expect(after == before, "\(PlanningUndoPropertyTests.difference(before, after))")
  }

  /// A change that would leave the card where it is never moves what it paid.
  @Test func aChangeThatDoesNotMoveTheCardIsRefusedAndNothingIsWritten() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let plan = try plan(book, .all)
    var change = PlanningChange.cardConversion(plan, at: at("2026-04-01"))
    change.upsert.cards = []
    let planning = PlanningRepository(writer: book.stack.writer, liveCounts: context)
    #expect(throws: AccountWriteError.cardOfAnotherAccount) { try planning.apply(change) }
    let after = try PlanningUndoPropertyTests.contents(book.stack)
    #expect(after == before, "\(PlanningUndoPropertyTests.difference(before, after))")
  }

  /// Every row the conversion writes is in the journal of the exchange, and the other device
  /// ends with the same credit card, card and operations.
  @Test func theConversionTravelsToTheOtherDevice() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    let book = try self.book(mac.stack)
    _ = try mac.exchange.exchange(with: folder)
    let seed = try phone.exchange.exchange(with: folder)
    #expect(seed.deferred == 0)
    try mac.sql("DELETE FROM sync_outbox")

    let plan = try plan(book, .onAndAfter(DateOnly(year: 2026, month: 3, day: 1)))
    _ = try PlanningRepository(writer: mac.stack.writer, liveCounts: context).apply(
      PlanningChange.cardConversion(plan, at: at("2026-04-01")))
    let queued = try mac.stack.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT DISTINCT table_name, row_key FROM sync_outbox")
        .map { "\($0["table_name"] as String):\($0["row_key"] as String)".lowercased() }
    }
    let expected = [
      "payment_methods:\(plan.account.id)", "payment_methods:\(book.debit.id)",
      "cards:\(book.black.id)", "cards:\(plan.leftCard.id)",
      "transactions:\(book.early.id)", "transactions:\(book.late.id)",
      "transactions:\(book.binned.id)", "scheduled_payments:\(book.payment.id)",
      "cashback_rules:\(book.cardRule.id)",
    ].map { $0.lowercased() }
    for row in expected { #expect(queued.contains(row), "\(row) is not in the journal") }

    _ = try mac.exchange.exchange(with: folder)
    // One exchange takes all of it: nothing waits for the next one.
    let taken = try phone.exchange.exchange(with: folder)
    #expect(taken.deferred == 0)
    #expect(taken.conflictsOpen == 0)
    let read = { (stack: DatabaseStack) throws -> [String] in
      try stack.writer.read { db in
        try String.fetchAll(
          db,
          sql: """
            SELECT 'card ' || id || ' ' || payment_method_id || ' ' || archived FROM cards
            UNION ALL SELECT 'account ' || id || ' ' || IFNULL(credit_limit_e4, '-') || ' '
              || IFNULL(main_card_id, '-') FROM payment_methods
            UNION ALL SELECT 'operation ' || id || ' ' || payment_method_id || ' ' || card_id
              FROM transactions WHERE card_id IS NOT NULL
            ORDER BY 1
            """)
      }
    }
    #expect(try read(phone.stack) == read(mac.stack))
    #expect(try cardsOfOtherAccounts(phone.stack) == 0)
  }
}
