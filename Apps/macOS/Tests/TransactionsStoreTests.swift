import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// One action of planning is one step of ⌘Z however many operations it rewrites or deletes:
/// the store says what it changed both ways, so the lists follow without a reload, and the
/// step weighs what it holds.
extension TransactionsStoreTests {
  /// What the store reported, write after write.
  @MainActor
  private final class Writes {
    var all: [StoreWrite] = []
    var last: StoreWrite? { all.last }
  }

  private struct Planned {
    let stack: DatabaseStack
    let repository: TransactionRepository
    let store: TransactionsStore
    let writes: Writes
  }

  private static let at = Date(timeIntervalSince1970: 1_789_128_000)

  /// A store with the planning attached, its writes recorded.
  private func plannedStore() throws -> Planned {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let repository = TransactionRepository(writer: stack.writer)
    let references = ReferenceRepository(writer: stack.writer)
    let store = TransactionsStore(repository: repository, references: references)
    store.attach(
      repository, references: references, planning: PlanningRepository(writer: stack.writer))
    let writes = Writes()
    store.didWrite = { writes.all.append($0) }
    return Planned(stack: stack, repository: repository, store: store, writes: writes)
  }

  private func entry(_ note: String, minutes: Int = 0) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: Self.at.addingTimeInterval(TimeInterval(minutes * 60)),
      amount: AmountE4(whole: 100), note: note)
    draft.normalizeSinglePart()
    return try draft.materialize(now: Self.at)
  }

  /// A dinner with 600 for a friend, and 700 of money back: the part closes, 100 is a surplus.
  private func moneyBack(
    _ planned: Planned
  ) throws -> (
    reimbursement: UUID, surplus: UUID, part: UUID
  ) {
    let at = Self.at
    let repository = planned.repository
    let references = ReferenceRepository(writer: planned.stack.writer)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let surcharges = CoreKit.Category(kind: .income, name: "Surcharges", systemRole: .surcharges)
    try references.save(groceries)
    try references.save(surcharges)
    var dinner = TransactionDraft(occurredAt: at, amount: AmountE4(whole: 1_000), note: "dinner")
    dinner.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 400)),
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 600), reimbursable: true),
    ]
    try repository.save(try dinner.materialize(now: at))
    let owed = try repository.owedParts()
    let reimbursementId = UUID()
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: reimbursementId, amountE4: AmountE4(whole: 700),
      closing: owed.map(\.inRubles))
    var back = TransactionDraft(kind: .reimbursement, occurredAt: at, amount: AmountE4(whole: 700))
    back.normalizeSinglePart()
    let surplus = try XCTUnwrap(outcome.surplus)
    var income = TransactionDraft(kind: .income, occurredAt: at, amount: surplus.amountE4)
    income.parts = [PartDraft(categoryId: surcharges.id, amount: surplus.amountE4)]
    var surplusEntry = try income.materialize(now: at)
    surplusEntry.transaction.externalId = ReimbursementCompanions.surplusKey(of: reimbursementId)
    try repository.apply(
      outcome, reimbursement: try back.materialize(id: reimbursementId, now: at),
      extra: [surplusEntry])
    return (reimbursementId, surplusEntry.id, owed[0].partId)
  }

  /// The change says it rewrote one operation — as written, stamped with its moment — and
  /// deleted a money back with its surplus, which put the part it closed back to waiting.
  /// Its undo says the reverse: the operations are back as they are after it, and the part is
  /// closed again.
  func testAStepOfPlanningReportsWhatItRewroteDeletedAndReopenedBothWays() throws {
    let planned = try plannedStore()
    let (repository, store, writes, at) = (
      planned.repository, planned.store, planned.writes, Self.at
    )
    let plain = try entry("plain")
    try repository.save(plain)
    let money = try moneyBack(planned)
    writes.all = []
    var renamed = try XCTUnwrap(try repository.entry(id: plain.id))
    renamed.transaction.note = "renamed"

    XCTAssertTrue(
      store.apply(
        PlanningChange(rewritten: [renamed], softDeleted: [money.reimbursement], at: at)))

    let applied = try XCTUnwrap(writes.last)
    XCTAssertEqual(applied.upserted.map(\.id), [plain.id])
    XCTAssertEqual(applied.upserted.first?.transaction.note, "renamed")
    XCTAssertEqual(applied.upserted.first?.transaction.updatedAt, at)
    XCTAssertEqual(applied.upserted, [try XCTUnwrap(try repository.entry(id: plain.id))])
    XCTAssertEqual(Set(applied.removed), [money.reimbursement, money.surplus])
    XCTAssertEqual(applied.partStatuses, [money.part: .expected])
    XCTAssertTrue(applied.planningChanged)

    store.undo()

    let undone = try XCTUnwrap(writes.last)
    XCTAssertEqual(writes.all.count, 2)
    XCTAssertEqual(undone.removed, [])
    XCTAssertEqual(
      Set(undone.upserted.map(\.id)), [plain.id, money.reimbursement, money.surplus])
    XCTAssertEqual(
      undone.upserted.first { $0.id == plain.id }?.transaction.note, "plain")
    XCTAssertTrue(undone.upserted.allSatisfy { !$0.transaction.isDeleted })
    for entry in undone.upserted {
      XCTAssertEqual(entry, try repository.entry(id: entry.id), "not the row as it is now")
    }
    XCTAssertEqual(undone.partStatuses, [money.part: .returned])
    XCTAssertTrue(undone.planningChanged)
    XCTAssertFalse(store.canUndo)
  }

  /// The operations a change created are reported both ways, as before.
  func testTheOperationsAChangeCreatedGoWithItsUndo() throws {
    let planned = try plannedStore()
    let (repository, store, writes) = (planned.repository, planned.store, planned.writes)
    let created = try entry("created")
    XCTAssertTrue(store.apply(PlanningChange(created: [created])))
    XCTAssertEqual(writes.last?.upserted.map(\.id), [created.id])
    XCTAssertEqual(writes.last?.removed, [])

    store.undo()
    XCTAssertEqual(writes.last?.removed, [created.id])
    XCTAssertEqual(writes.last?.upserted.map(\.id), [])
    XCTAssertNil(try repository.entry(id: created.id))
  }

  /// A step weighs the operations its undo writes back. With room for three operations, a
  /// change that deleted three and a line saved after it are four: the change is let go, the
  /// line stays. Weighed as one, the change stayed and ⌘Z reached it.
  func testAStepOfPlanningWeighsTheOperationsItHolds() throws {
    let planned = try plannedStore()
    let (repository, store, at) = (planned.repository, planned.store, Self.at)
    let rows = try (0..<3).map { try entry("row \($0)", minutes: $0) }
    for row in rows { try repository.save(row) }
    store.undoDepth = TransactionsStore.UndoDepth(levels: 100, operations: 3)

    XCTAssertTrue(store.apply(PlanningChange(softDeleted: rows.map(\.id), at: at)))
    XCTAssertTrue(store.save(try entry("after", minutes: 10)))

    store.undo()
    XCTAssertFalse(store.canUndo, "the change of three operations was kept past the cap")
    XCTAssertTrue(try repository.entries(ids: rows.map(\.id)).allSatisfy(\.transaction.isDeleted))
  }

  /// A change that deleted more operations than the main thread writes is taken back off it,
  /// in one step, and says what came back.
  func testALargeStepOfPlanningIsUndoneOffTheMainThread() async throws {
    let planned = try plannedStore()
    let (repository, store, writes, at) = (
      planned.repository, planned.store, planned.writes, Self.at
    )
    let start = at
    let rows = try (0...TransactionsStore.backgroundThreshold).map { index in
      var draft = TransactionDraft(
        occurredAt: start.addingTimeInterval(TimeInterval(index)), amount: AmountE4(whole: 1),
        note: "row \(index)")
      draft.normalizeSinglePart()
      return try draft.materialize(now: start)
    }
    try repository.insert(rows)
    XCTAssertTrue(store.apply(PlanningChange(softDeleted: rows.map(\.id), at: at)))
    XCTAssertEqual(writes.last?.removed.count, rows.count)

    store.undo()
    XCTAssertTrue(store.isWritingInBackground, "a step that large is undone off the main thread")
    let write = try XCTUnwrap(store.backgroundWrite)
    let landed = await write.value
    XCTAssertTrue(landed)
    XCTAssertFalse(store.isWritingInBackground)
    XCTAssertEqual(writes.last?.upserted.count, rows.count)
    XCTAssertTrue(writes.last?.planningChanged == true)
    XCTAssertEqual(try repository.count(), rows.count)
    XCTAssertFalse(store.canUndo)
  }
}

/// What the store hands on to the rules of money: a purchase on credit of a deleted debt goes
/// like any other unless the debt was paid, and an edit that balances money back again writes a
/// new surplus with the note of the interface's language.
extension TransactionsStoreTests {
  /// «Телефон» 60,000 ₽ on credit of a debt that is deleted since; `paid` lines of its journal.
  private func phoneOnCredit(
    _ planned: Planned, paid: Int
  ) throws -> (purchase: TransactionEntry, debt: Debt) {
    let references = ReferenceRepository(writer: planned.stack.writer)
    let phone = Debt(
      direction: .iOwe, type: .installment, name: "Phone", paymentsAreExpenses: false,
      origin: .purchase, deletedAt: Self.at)
    try references.save(phone)
    var draft = TransactionDraft(
      occurredAt: Self.at, amount: AmountE4(whole: 60_000), note: "Phone")
    draft.normalizeSinglePart()
    var purchase = try draft.materialize(now: Self.at)
    purchase.transaction.creditDebtId = phone.id
    try planned.repository.save(purchase)
    let journal = (0..<paid).map { month in
      DebtEntry(
        debtId: phone.id, date: DateOnly(year: 2026, month: 10 + month, day: 1),
        amountE4: AmountE4(whole: -5_000), kind: .payment)
    }
    planned.store.show(
      Ledger(
        dataset: Dataset(
          entries: [try XCTUnwrap(try planned.repository.entry(id: purchase.id))],
          planning: PlanningBook(debtEntries: journal), deletedDebts: [phone]),
        calendar: .utc))
    return (purchase, phone)
  }

  /// Its debt deleted and never paid, the purchase on credit goes with a deletion from the list.
  func testACreditPurchaseOfADeletedDebtIsDeletable() throws {
    let planned = try plannedStore()
    let (purchase, _) = try phoneOnCredit(planned, paid: 0)
    XCTAssertTrue(planned.store.planDeletion(ids: [purchase.id]).skipped.isEmpty)
    XCTAssertTrue(planned.store.delete(ids: [purchase.id]))
    XCTAssertEqual(try planned.repository.entry(id: purchase.id)?.transaction.isDeleted, true)
  }

  /// Three instalments of 5,000 ₽ paid on it: the purchase stays spending of 60,000 ₽, or the
  /// 15,000 ₽ that left the card would be in no figure.
  func testAPaidCreditPurchaseOfADeletedDebtStays() throws {
    let planned = try plannedStore()
    let (purchase, _) = try phoneOnCredit(planned, paid: 3)
    XCTAssertEqual(
      planned.store.planDeletion(ids: [purchase.id]).skipped.map(\.reason),
      [.creditPurchasePaid])
    XCTAssertFalse(planned.store.delete(ids: [purchase.id]))
    XCTAssertEqual(try planned.repository.entry(id: purchase.id)?.transaction.isDeleted, false)
  }

  /// 20 $ paid for a friend at 92 (1,840 ₽ charged) and exactly 1,840 ₽ given back: the part is
  /// closed, nothing over. The card was really charged 1,800 ₽: the edit of the purchase writes
  /// 40 ₽ of income in «Доплаты», noted in the language of the interface, and its ⌘Z takes it
  /// away.
  func testAnEditAfterMoneyBackWritesTheSurplusWithItsNote() throws {
    let planned = try plannedStore()
    let references = ReferenceRepository(writer: planned.stack.writer)
    let card = PaymentMethod(name: "Card", kind: .card, currency: .rub, isDefault: true)
    try references.save(card)
    let friend = Person(name: "Friend")
    try references.save(friend)
    if try references.category(systemRole: .surcharges, kind: .income) == nil {
      try references.save(
        CoreKit.Category(kind: .income, name: "Surcharges", systemRole: .surcharges))
    }
    let day = DateOnly(year: 2026, month: 9, day: 10)
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(9 * 3600),
      currency: .usd, amount: AmountE4(whole: 20), rate: 92, rateDate: day, rateSource: .cbr,
      note: "Subscription", paymentMethodId: card.id, accountCurrency: .rub,
      accountAmount: AmountE4(whole: 1_840))
    draft.parts = [
      PartDraft(
        amount: AmountE4(whole: 20), forWhom: .friends, reimbursable: true,
        debtorPersonId: friend.id)
    ]
    let purchase = try planned.repository.save(
      try draft.materialize(rublesConverter: { _ in AmountE4(whole: 1_840) }))
    var backDraft = TransactionDraft(
      kind: .reimbursement, occurredAt: Self.at, amount: AmountE4(whole: 1_840),
      paymentMethodId: card.id)
    backDraft.normalizeSinglePart()
    let back = try backDraft.materialize(now: Self.at)
    try planned.repository.apply(
      ReimbursementOutcome(
        reimbursementTxId: back.id, allocations: [],
        links: [
          ReimbursementLink(
            reimbursementTxId: back.id, partId: purchase.parts[0].id,
            amountE4: AmountE4(whole: 1_840))
        ],
        closedPartIds: [purchase.parts[0].id]),
      reimbursement: back, at: Self.at)

    var charged = try XCTUnwrap(try planned.repository.entry(id: purchase.id))
    charged.transaction.accountAmountE4 = AmountE4(whole: 1_800)
    charged.transaction.amountRubE4 = AmountE4(whole: 1_800)
    charged.transaction.rate = 90
    charged.transaction.rateSource = .manual
    charged.parts[0].amountRubE4 = AmountE4(whole: 1_800)
    XCTAssertEqual(planned.store.saveEdit(charged, calendar: .utc), .saved)

    let surplus = try XCTUnwrap(
      try planned.repository.entries(from: .distantPast, to: .distantFuture).first {
        $0.transaction.externalId == ReimbursementCompanions.surplusKey(of: back.id)
      })
    XCTAssertEqual(surplus.transaction.amountE4, AmountE4(whole: 40))
    XCTAssertEqual(surplus.transaction.note, TransactionsStore.surplusNote())
    XCTAssertNotEqual(surplus.transaction.note, "reimbursement.surplus")
    XCTAssertTrue(planned.writes.last?.planningChanged == true)

    planned.store.undo()
    XCTAssertEqual(try planned.repository.entry(id: surplus.id), nil)
  }

  /// The note is the one of the language chosen, read where the choice is kept.
  func testTheSurplusNoteFollowsTheLanguageChosen() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "surplus-note-\(UUID().uuidString)"))
    defaults.set("ru", forKey: "app.language")
    XCTAssertEqual(TransactionsStore.surplusNote(defaults), "Излишек возврата")
    defaults.set("en", forKey: "app.language")
    XCTAssertNotEqual(TransactionsStore.surplusNote(defaults), "Излишек возврата")
    XCTAssertNotEqual(TransactionsStore.surplusNote(defaults), "reimbursement.surplus")
  }
}
