import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Changing and deleting many operations from the list: one action is one step of ⌘Z, and
/// every write — undo included — tells the app so it can make a copy.
@MainActor
final class BulkActionsTests: XCTestCase {
  private var repository: TransactionRepository!
  private var references: ReferenceRepository!
  private var store: TransactionsStore!
  private var written: [[UUID]] = []
  /// The database of a test that needs the whole of it — counts and accounts included.
  private var stack: DatabaseStack?

  /// Built inside each test, on the main actor: the store and its callback belong there.
  private func makeStore() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    repository = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    store = TransactionsStore(repository: repository, references: references)
    written = []
    store.didWrite = { [weak self] write in self?.written.append(write.touchedIds) }
  }

  /// What the pipeline would hand the store after reading the database: the lists, the
  /// menus and the confirmations read the operations from it.
  private func showDatabase() throws {
    let dataset = Dataset(
      entries: try repository.entries(from: .distantPast, to: .distantFuture),
      categories: try references.categories(includeArchived: true),
      debts: try references.debts(includeClosed: true))
    store.show(Ledger(dataset: dataset, calendar: .utc))
  }

  private func saveEntries(_ notes: [String]) throws -> [TransactionEntry] {
    if store == nil { try makeStore() }
    let entries = try notes.enumerated().map { index, note in
      var draft = TransactionDraft(
        occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
          .addingTimeInterval(Double(index) * 60),
        amount: AmountE4(whole: 100), note: note)
      draft.normalizeSinglePart()
      return try draft.materialize()
    }
    for entry in entries { try repository.save(entry) }
    try showDatabase()
    return entries
  }

  /// Operations enough to make a bulk write leave the main thread, saved in one write.
  private func saveMany(_ count: Int) throws -> [UUID] {
    if store == nil { try makeStore() }
    let start = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 1))
    let entries = try (0..<count).map { index in
      var draft = TransactionDraft(
        occurredAt: start.addingTimeInterval(TimeInterval(index) * 60),
        amount: AmountE4(whole: 100), note: "row \(index)")
      draft.normalizeSinglePart()
      return try draft.materialize()
    }
    try repository.insert(entries)
    try showDatabase()
    return entries.map(\.id)
  }

  /// Waits for the write the store runs off the main thread and says whether it landed.
  private func backgroundWriteLands() async throws -> Bool {
    let write = try XCTUnwrap(store.backgroundWrite, "the write did not leave the main thread")
    return await write.value
  }

  /// ⌘A over two months of the large sample selects about 1 700 operations. A
  /// change that large is written off the main thread: the call returns at once, the store
  /// is busy — nothing to undo yet, nothing reported — and once it lands it is one step of
  /// ⌘Z and one report, like any bulk change. Its undo goes the same way.
  func testAChangeOfMoreThanAThousandLandsInTheBackgroundAsOneStep() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    XCTAssertTrue(store.isWritingInBackground)
    XCTAssertFalse(store.canUndo, "nothing to undo before the write has landed")
    XCTAssertTrue(written.isEmpty)

    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertFalse(store.isWritingInBackground)
    XCTAssertNil(store.lastError)
    XCTAssertEqual(written.count, 1)
    XCTAssertEqual(Set(written.last ?? []), Set(ids))
    let changed = try repository.entries(ids: ids)
    XCTAssertTrue(changed.allSatisfy { $0.parts[0].quality == .bad })
    XCTAssertTrue(store.canUndo)

    store.undo()
    XCTAssertTrue(store.isWritingInBackground, "a step that large is undone off the main thread")
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertTrue(try repository.entries(ids: ids).allSatisfy { $0.parts[0].quality == nil })
    XCTAssertEqual(written.count, 2)
    XCTAssertFalse(store.canUndo, "the whole change was one step")
  }

  func testADeletionOfMoreThanAThousandLandsInTheBackgroundAndComesBack() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)

    XCTAssertTrue(store.delete(ids: ids))
    XCTAssertTrue(store.isWritingInBackground)
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertEqual(try repository.count(), 0)
    XCTAssertEqual(Set(written.last ?? []), Set(ids))

    store.undo()
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertEqual(try repository.count(), ids.count)
    XCTAssertEqual(written.count, 2)
    XCTAssertFalse(store.canUndo)
  }

  /// While a large write is landing, the store takes no other bulk write and no undo: the
  /// steps of ⌘Z stay in the order of the writes they take back.
  func testNothingElseIsWrittenOrUndoneWhileABackgroundWriteLands() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.apply(.quality(.good), to: [ids[0]]))

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    XCTAssertFalse(store.apply(.quality(.neutral), to: [ids[1]]))
    XCTAssertFalse(store.delete(ids: [ids[2]]))
    store.undo()

    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertEqual(written.count, 2, "only the two changes that were taken")
    XCTAssertEqual(try repository.count(), ids.count)
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .bad)
    XCTAssertEqual(try repository.entry(id: ids[1])?.parts[0].quality, .bad)
  }

  /// A store handed another database while a large write on the first one is still on its
  /// way: that write belongs to the database it was asked of. It used to keep the store busy
  /// — no bulk write and no ⌘Z on the new database until it landed — and then to report
  /// itself to the new database's `didWrite`: its overlay got rows that are not there, its
  /// backup a change it never had.
  func testAWriteOnADatabaseLetGoIsNeitherWaitedForNorReportedToTheNextOne() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    let old = try XCTUnwrap(store.backgroundWrite)

    let next = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let nextRepository = TransactionRepository(writer: next.writer)
    store.attach(nextRepository, references: ReferenceRepository(writer: next.writer))
    let tea = try typedEntry("tea")
    try nextRepository.save(tea)

    XCTAssertFalse(store.isWritingInBackground, "the new database has no write on its way")
    XCTAssertTrue(store.apply(.quality(.good), to: [tea.id]), "a bulk write was turned away")
    XCTAssertEqual(written, [[tea.id]])
    let landed = await old.value
    XCTAssertTrue(landed)
    XCTAssertEqual(written, [[tea.id]], "the old database's write was reported to the new one")
    XCTAssertFalse(store.isWritingInBackground)
    store.undo()
    XCTAssertNil(try nextRepository.entry(id: tea.id)?.parts[0].quality)
    XCTAssertFalse(store.canUndo, "the old write left a step on the new database")
  }

  /// An operation that is not saved yet, as the entry line would hand it to the store.
  private func typedEntry(_ note: String) throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: note)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  /// The entry line is never locked: a line typed while a large change is landing
  /// is the last thing the owner did, so it is the first thing ⌘Z takes back — although the
  /// change reaches the stack of undo only when it lands. The change takes the place it was
  /// asked for in, above the steps taken before it.
  func testALineSavedWhileABackgroundChangeLandsIsUndoneFirst() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.apply(.quality(.good), to: [ids[0]]))
    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    let coffee = try typedEntry("coffee")
    XCTAssertTrue(store.save(coffee))
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)

    store.undo()
    XCTAssertFalse(store.isWritingInBackground, "one operation is undone at once")
    XCTAssertNil(try repository.entry(id: coffee.id), "the line went first")
    XCTAssertEqual(try repository.entry(id: ids[1])?.parts[0].quality, .bad)

    store.undo()
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertNil(try repository.entry(id: ids[1])?.parts[0].quality, "then the large change")
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .good)

    store.undo()
    XCTAssertNil(try repository.entry(id: ids[0])?.parts[0].quality, "then the one before it")
    XCTAssertFalse(store.canUndo)
  }

  /// The same for a large deletion: what goes is chosen and deleted in one write, and its
  /// step still lands under the line typed meanwhile.
  func testALineSavedWhileABackgroundDeletionLandsIsUndoneFirst() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.delete(ids: ids))
    let coffee = try typedEntry("coffee")
    XCTAssertTrue(store.save(coffee))
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertEqual(try repository.count(), 1)

    store.undo()
    XCTAssertNil(try repository.entry(id: coffee.id), "the line went first")
    XCTAssertEqual(try repository.count(), 0)

    store.undo()
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertEqual(try repository.count(), ids.count)
    XCTAssertFalse(store.canUndo)
  }

  /// Recording a reimbursement forgets the steps before it, and a large change still landing
  /// was asked for before it too: its step is not kept, so ⌘Z never reaches across the
  /// write the history was forgotten for. A line saved after that is kept as usual.
  func testALargeChangeLandingAfterTheHistoryWasForgottenLeavesNoStep() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    store.forgetUndoHistory()
    let coffee = try typedEntry("coffee")
    XCTAssertTrue(store.save(coffee))
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertEqual(written.count, 2, "the change landed and was reported all the same")

    store.undo()
    XCTAssertNil(try repository.entry(id: coffee.id))
    XCTAssertFalse(store.canUndo, "nothing reaches across the forgotten history")
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .bad)
  }

  /// The undo of a large deletion runs with nothing selected — the deleted rows left the
  /// selection — and so may a change whose selection was cleared with Esc. The bar stays
  /// for the time of the write, without a count, to say why ⌘Z and the menu wait.
  func testTheBarSaysAWriteIsLandingWhenNothingIsSelected() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    let actions = OperationActions()
    actions.selection = Set(ids)
    var form: SelectionBar.Form {
      SelectionBar.form(selection: actions.selection, writing: store.isWritingInBackground)
    }
    XCTAssertEqual(form, .selection)

    XCTAssertTrue(store.delete(ids: ids))
    XCTAssertEqual(form, .selection, "the count and the inactive buttons, as before")
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    actions.keep(only: [])
    XCTAssertEqual(form, .hidden)

    store.undo()
    XCTAssertEqual(form, .writing)
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertEqual(form, .hidden)
  }

  // MARK: How far ⌘Z reaches back

  /// The stack of ⌘Z used to keep every step of the session until quit — each bulk change
  /// with a copy of every operation it touched. It reaches back a hundred steps now: the
  /// hundred and first write lets the oldest step go, and that write stays in place.
  func testUndoReachesBackAHundredStepsAndNoFurther() throws {
    let entries = try saveEntries(["coffee"])
    let id = entries[0].id
    let levels = TransactionsStore.UndoDepth().levels
    XCTAssertEqual(levels, 100)
    for step in 0...levels {
      XCTAssertTrue(store.apply(.quality(step.isMultiple(of: 2) ? .bad : .good), to: [id]))
    }
    XCTAssertEqual(try repository.entry(id: id)?.parts[0].quality, .bad)

    for _ in 0..<levels { store.undo() }

    XCTAssertFalse(store.canUndo, "a hundred steps back, and no further")
    XCTAssertEqual(
      try repository.entry(id: id)?.parts[0].quality, .bad, "the first change stays in place")
  }

  /// Steps of many operations count by what they hold: beyond the budget the oldest go,
  /// however few the steps. The newest stays whatever its size — the last thing done can
  /// always be taken back.
  func testLargeStepsLetTheOldestGoBeyondTheBudget() throws {
    let entries = try saveEntries((0..<20).map { "row \($0)" })
    let ids = entries.map(\.id)
    store.undoDepth = TransactionsStore.UndoDepth(levels: 100, operations: 10)

    XCTAssertTrue(store.apply(.quality(.good), to: Array(ids[0..<4])))
    XCTAssertTrue(store.apply(.quality(.bad), to: Array(ids[4..<8])))
    XCTAssertTrue(store.apply(.quality(.neutral), to: Array(ids[8..<12])))
    store.undo()
    store.undo()
    XCTAssertFalse(store.canUndo, "twelve operations kept where ten are allowed")
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .good)
    XCTAssertNil(try repository.entry(id: ids[4])?.parts[0].quality)

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    XCTAssertTrue(store.canUndo, "a step larger than the budget is still kept, alone")
    store.undo()
    XCTAssertFalse(store.canUndo)
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .good)
    XCTAssertNil(try repository.entry(id: ids[19])?.parts[0].quality)
  }

  /// A large change takes its place in the stack when it is asked for and lands later; the
  /// history is not trimmed meanwhile, or a line saved in between would end up under the
  /// change and ⌘Z would take the change back first.
  func testTheHistoryIsTrimmedOnlyOnceALargeWriteHasLanded() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 2)
    store.undoDepth = TransactionsStore.UndoDepth(levels: 3, operations: 100_000)
    for quality in [Quality.good, .neutral, .bad] {
      XCTAssertTrue(store.apply(.quality(quality), to: [ids[0]]))
    }
    XCTAssertTrue(store.apply(.quality(.good), to: Array(ids.dropFirst())))
    let coffee = try typedEntry("coffee")
    XCTAssertTrue(store.save(coffee))
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)

    store.undo()
    XCTAssertNil(try repository.entry(id: coffee.id), "the line went first")
    store.undo()
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertNil(try repository.entry(id: ids[1])?.parts[0].quality, "then the large change")
    store.undo()
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .neutral)
    XCTAssertFalse(store.canUndo, "three steps kept: the line, the change and the last edit")
  }

  /// A thousand is still written where it is asked for: the call has landed when it returns.
  func testAThousandOperationsAreStillWrittenAtOnce() throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold)

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))

    XCTAssertFalse(store.isWritingInBackground)
    XCTAssertNil(store.backgroundWrite)
    XCTAssertEqual(written.count, 1)
    XCTAssertTrue(try repository.entries(ids: ids).allSatisfy { $0.parts[0].quality == .bad })
  }

  /// The confirmation of a bulk change drops what `apply` returns: a change the database
  /// refuses — here a place that is not in the dictionary — is told by the store itself,
  /// through `failure`, which the alert of the screen shows (`operationPresentations`), and
  /// the journal gets it. Nothing is written and nothing is left to undo.
  func testARefusedBulkChangeIsToldByTheStoreNotByItsCaller() throws {
    let entries = try saveEntries(["coffee", "tea"])
    let ids = entries.map(\.id)

    XCTAssertFalse(store.apply(.place(UUID()), to: ids))

    XCTAssertEqual(store.failure?.action, .change)
    XCTAssertFalse(store.canUndo)
    XCTAssertTrue(written.isEmpty)
    XCTAssertTrue(try repository.entries(ids: ids).allSatisfy { $0.transaction.placeId == nil })
  }

  func testOneBulkChangeIsUndoneByOneUndo() throws {
    let entries = try saveEntries(["coffee", "tea", "juice"])
    let ids = entries.map(\.id)

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    let changed = try repository.entries(ids: ids)
    XCTAssertEqual(changed.map { $0.parts[0].quality }, [.bad, .bad, .bad])
    XCTAssertEqual(changed.map { $0.parts[0].qualitySource }, [.manual, .manual, .manual])

    store.undo()

    let restored = try repository.entries(ids: ids)
    XCTAssertEqual(restored.map { $0.parts[0].quality }, [nil, nil, nil])
    XCTAssertFalse(store.canUndo, "the whole change was one step")
  }

  func testOneBulkDeletionIsUndoneByOneUndo() throws {
    let entries = try saveEntries(["coffee", "tea", "juice"])

    XCTAssertTrue(store.delete(ids: entries.map(\.id)))
    XCTAssertEqual(try repository.count(), 0)
    XCTAssertEqual(Set(written.last ?? []), Set(entries.map(\.id)))

    store.undo()

    XCTAssertEqual(try repository.count(), 3)
    XCTAssertEqual(Set(written.last ?? []), Set(entries.map(\.id)))
    XCTAssertFalse(store.canUndo)
  }

  /// A copy after every change — ⌘Z is a change too.
  func testEveryWriteAndEveryUndoIsReported() throws {
    let entries = try saveEntries(["coffee", "tea"])
    let ids = entries.map(\.id)

    store.apply(.quality(.good), to: ids)
    store.delete(ids: [ids[0]])
    XCTAssertEqual(written.count, 2)

    store.undo()
    XCTAssertEqual(written.count, 3)
    XCTAssertEqual(written.last, [ids[0]])
    store.undo()
    XCTAssertEqual(written.count, 4)
    XCTAssertEqual(Set(written.last ?? []), Set(ids))
  }

  /// The plan the confirmation is written from counts the splits and what is left alone.
  func testThePlanSaysWhatTheChangeReachesAndWhatItLeavesAlone() throws {
    try makeStore()
    var receipt = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18)),
      amount: AmountE4(whole: 1_000), note: "receipt")
    receipt.parts = [
      PartDraft(amount: AmountE4(whole: 600)),
      PartDraft(amount: AmountE4(whole: 400)),
    ]
    var salary = TransactionDraft(
      kind: .income,
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18)),
      amount: AmountE4(whole: 5_000), note: "salary")
    salary.normalizeSinglePart()
    let split = try receipt.materialize()
    let income = try salary.materialize()
    try repository.save(split)
    try repository.save(income)
    try showDatabase()

    let plan = store.plan(.quality(.bad), ids: [split.id, income.id])

    XCTAssertEqual(plan.changedIds, [split.id])
    XCTAssertEqual(plan.splitCount, 1)
    XCTAssertEqual(plan.skipped.map(\.reason), [.noQuality])
  }

  /// Settings adds, re-rates and archives categories without going through the store, so a
  /// bulk change judges by the dictionary as it is at that moment, not as the list last
  /// read it.
  func testABulkCategoryChangeJudgesByTheCategoriesAsTheyAreNow() throws {
    try makeStore()
    var cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
    try references.save(cafe)
    let lunch = try saveEntries(["lunch"])[0]

    // Re-rated after the list was read: the operation takes the quality Cafe has now.
    cafe.quality = .bad
    try references.save(cafe)
    XCTAssertTrue(store.apply(.category(cafe.id), to: [lunch.id]))
    let moved = try XCTUnwrap(try repository.entry(id: lunch.id))
    XCTAssertEqual(moved.parts[0].categoryId, cafe.id)
    XCTAssertEqual(moved.parts[0].quality, .bad)
    XCTAssertEqual(moved.parts[0].qualitySource, .category)

    // Created after the list was read: a category the popover offers is one the rule knows.
    let pets = CoreKit.Category(kind: .expense, name: "Pets", quality: .neutral)
    try references.save(pets)
    XCTAssertEqual(store.plan(.category(pets.id), ids: [lunch.id]).changedIds, [lunch.id])

    // Archived after the list was read: nothing is filed into it any more.
    var pub = CoreKit.Category(kind: .expense, name: "Pub", quality: .bad)
    try references.save(pub)
    try showDatabase()
    pub.archived = true
    try references.save(pub)
    let refused = store.plan(.category(pub.id), ids: [lunch.id])
    XCTAssertTrue(refused.changed.isEmpty)
    XCTAssertEqual(refused.skipped.map(\.reason), [.retiredCategory])
    XCTAssertTrue(store.apply(.category(pub.id), to: [lunch.id]))
    XCTAssertEqual(try repository.entry(id: lunch.id)?.parts[0].categoryId, cafe.id)
  }

  /// A payment typed in the line moves its debt right after it is saved. Undoing the entry
  /// takes that movement off the debt as well: the payment never happened, so the debt is
  /// what it was before.
  func testUndoingATypedDebtPaymentTakesItsMovementOffTheDebt() throws {
    try makeStore()
    let loan = Debt(direction: .iOwe, type: .loan, name: "Bank loan", paymentsAreExpenses: true)
    try references.save(loan)
    let opening = DebtEntry(
      debtId: loan.id, date: DateOnly(year: 2026, month: 1, day: 10),
      amountE4: AmountE4(whole: 100_000), kind: .borrowed)
    try references.save(opening)
    var draft = TransactionDraft(amount: AmountE4(whole: 7_000), note: "loan", debtId: loan.id)
    draft.normalizeSinglePart()
    let payment = try draft.materialize()
    XCTAssertTrue(store.save(payment))
    try references.save(
      DebtEntry(
        debtId: loan.id, date: DateOnly(year: 2026, month: 9, day: 18),
        amountE4: AmountE4(whole: -7_000), kind: .payment, transactionId: payment.id))

    store.undo()

    XCTAssertEqual(try repository.count(), 0)
    XCTAssertEqual(try references.debtEntries(debtId: loan.id), [opening])
  }

  /// Deleting asks with the count and the sums of what goes; a purchase on credit is left
  /// for the Debts section and the dialog says why.
  func testTheDeleteConfirmationCountsWhatGoesAndSaysWhatStays() throws {
    let entries = try saveEntries(["coffee", "tea"])
    var laptop = entries[1]
    laptop.transaction.creditDebtId = UUID()

    let confirmation = try XCTUnwrap(
      BulkConfirmation.deletion(of: [entries[0], laptop], debts: [:]))
    guard case .delete(let ids, let plan, let totals, _, _) = confirmation else {
      return XCTFail("a deletion was expected")
    }
    XCTAssertEqual(ids, [entries[0].id])
    XCTAssertEqual(totals.myExpenses, AmountE4(whole: 100))
    XCTAssertEqual(plan.skipped.map(\.reason), [.creditPurchase])
  }

  /// «Телефон» 60,000 ₽ bought on credit, its debt deleted since. Never paid, the purchase is
  /// offered for deletion like any other — from the list and from the editor alike. Three
  /// instalments of 5,000 ₽ paid on it, it stays, and the dialog says the debt was paid: the
  /// 15,000 ₽ that left the card would otherwise be in no figure.
  func testACreditPurchaseOfADeletedDebtIsOfferedForDeletion() throws {
    try makeStore()
    let phone = Debt(
      direction: .iOwe, type: .installment, name: "Phone", paymentsAreExpenses: false,
      origin: .purchase, deletedAt: Date(timeIntervalSince1970: 1_789_128_000))
    try references.save(phone)
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18)),
      amount: AmountE4(whole: 60_000), note: "Phone")
    draft.normalizeSinglePart()
    var purchase = try draft.materialize()
    purchase.transaction.creditDebtId = phone.id
    try repository.save(purchase)
    let environment = AppEnvironment()

    // The question of the list and the question of the editor, `paid` instalments paid.
    func questions(paid: Int) throws -> [BulkConfirmation?] {
      let journal = (0..<paid).map { month in
        DebtEntry(
          debtId: phone.id, date: DateOnly(year: 2026, month: 10 + month, day: 1),
          amountE4: AmountE4(whole: -5_000), kind: .payment)
      }
      store.show(
        Ledger(
          dataset: Dataset(
            entries: try repository.entries(from: .distantPast, to: .distantFuture),
            planning: PlanningBook(debtEntries: journal), deletedDebts: [phone]),
          calendar: .utc))
      let actions = OperationActions()
      actions.requestDeletion(of: [purchase.id], store: store)
      let editor = TransactionEditorModel(entry: purchase, environment: environment)
      editor.requestDeletion(store: store)
      return [actions.confirmation, editor.confirmation]
    }

    for question in try questions(paid: 0) {
      guard case .delete(let ids, let plan, _, _, _) = try XCTUnwrap(question) else {
        return XCTFail("a deletion was expected")
      }
      XCTAssertEqual(ids, [purchase.id])
      XCTAssertTrue(plan.skipped.isEmpty, "\(plan.skipped.map(\.reason))")
    }
    for question in try questions(paid: 3) {
      guard case .delete(let ids, let plan, _, _, _) = try XCTUnwrap(question) else {
        return XCTFail("a deletion was expected")
      }
      XCTAssertEqual(ids, [])
      XCTAssertEqual(plan.skipped.map(\.reason), [.creditPurchasePaid])
    }
  }

  /// Money a person gives back on a debt they owe me is a reimbursement too (DebtRules), but
  /// it closes no part and has no surplus or shortfall: its deletion moves the debt, and that
  /// is the only line the confirmation says about it. Money given back for a purchase says
  /// what goes with it.
  func testTheDeleteConfirmationSaysWhatAPaymentOnADebtOwedToMeTakesAlong() throws {
    let environment = AppEnvironment()
    environment.language.choice = .english
    var payment = TransactionDraft(
      kind: .reimbursement, amount: AmountE4(whole: 1_000), debtId: UUID())
    payment.normalizeSinglePart()
    var reimbursement = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: 600))
    reimbursement.normalizeSinglePart()
    func message(_ entries: [TransactionEntry]) throws -> String {
      let confirmation = try XCTUnwrap(BulkConfirmation.deletion(of: entries, debts: [:]))
      return BulkConfirmationText.message(confirmation, environment: environment)
    }
    let reimbursementLine = environment.language("bulk.deleteReimbursement", table: "Transactions")
    let debtLine = environment.language("bulk.deleteDebtPayment", table: "Transactions")

    let onDebt = try message([try payment.materialize()])
    XCTAssertTrue(onDebt.contains(debtLine), onDebt)
    XCTAssertFalse(onDebt.contains(reimbursementLine), onDebt)

    let forPurchase = try message([try reimbursement.materialize()])
    XCTAssertTrue(forPurchase.contains(reimbursementLine), forPurchase)
    XCTAssertFalse(forPurchase.contains(debtLine), forPurchase)
  }

  /// Every sentence the dialogs are built from is in both languages, plural forms included:
  /// a key that resolves to itself would show up in the interface as it is.
  func testTheWordsOfTheConfirmationsAreTranslated() throws {
    let environment = AppEnvironment()
    let plan = BulkEditPlan(
      changed: [try saveEntries(["coffee"])[0]],
      skipped: [
        BulkSkip(transactionId: UUID(), reason: .goalContribution),
        BulkSkip(transactionId: UUID(), reason: .paidForSomebodyElse, isPartial: true),
      ],
      splitCount: 2)
    let confirmation = BulkConfirmation.edit(.quality(.bad), ids: [], plan: plan)
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let words =
        BulkConfirmationText.title(confirmation, environment: environment) + "\n"
        + BulkConfirmationText.message(confirmation, environment: environment)
      XCTAssertFalse(words.contains("bulk."), words)
      XCTAssertTrue(words.contains("2"), words)
      for key in ["selection.count", "selection.change", "totals.moneyReturned"] {
        XCTAssertNotEqual(environment.language(key, table: "Transactions"), key)
      }
      for reason in BulkSkipReason.allCases {
        let key = "bulk.reason.\(reason.rawValue)"
        XCTAssertNotEqual(environment.language(key, table: "Transactions"), key)
      }
    }
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language.format("selection.count", table: "Transactions", 5), "5 операций")
    XCTAssertEqual(
      environment.language.format("selection.count", table: "Transactions", 2), "2 операции")
    XCTAssertEqual(
      environment.language.format("selection.count", table: "Transactions", 21), "21 операция")
  }

  // MARK: Accounts

  /// Coffee for 1 000 ₽ on the card, and the lists knowing both accounts.
  private func coffeeOnTheCard() throws -> (
    entry: TransactionEntry, card: PaymentMethod, kaspi: PaymentMethod
  ) {
    try makeStore()
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
    for account in [card, kaspi] { try references.save(account) }
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18)),
      amount: AmountE4(whole: 1_000), note: "coffee", paymentMethodId: card.id)
    draft.normalizeSinglePart()
    let entry = try repository.save(try draft.materialize())
    let dataset = Dataset(
      entries: try repository.entries(from: .distantPast, to: .distantFuture),
      categories: try references.categories(includeArchived: true),
      paymentMethods: [card, kaspi])
    store.show(Ledger(dataset: dataset, calendar: .utc))
    return (entry, card, kaspi)
  }

  /// 20 ₽ for 100 ₸ on the day of the coffee.
  private var tengeRates: DayRates {
    DayRates(series: [
      CurrencyCode("KZT"): [DayRate(day: DateOnly(year: 2026, month: 9, day: 18), perUnit: 0.2)]
    ])
  }

  /// Moved in bulk onto an account that does not hold rubles, the coffee says what that
  /// account was charged — worked out at the rates of its day — and ⌘Z puts it back on the
  /// card with nothing charged apart.
  func testMovingOperationsToAnAccountWithoutTheirCurrencyChargesIt() throws {
    let (entry, card, kaspi) = try coffeeOnTheCard()
    let kzt = CurrencyCode("KZT")

    let plan = store.plan(
      .paymentMethod(kaspi.id), ids: [entry.id], rates: tengeRates, calendar: .utc)
    XCTAssertEqual(plan.skipped, [])
    XCTAssertEqual(plan.changed.first?.transaction.accountCurrency, kzt)
    XCTAssertEqual(plan.changed.first?.transaction.accountAmountE4, AmountE4(whole: 5_000))

    XCTAssertTrue(
      store.apply(.paymentMethod(kaspi.id), to: [entry.id], rates: tengeRates, calendar: .utc))
    let moved = try XCTUnwrap(try repository.entry(id: entry.id))
    XCTAssertEqual(moved.transaction.paymentMethodId, kaspi.id)
    XCTAssertEqual(moved.transaction.accountCurrency, kzt)
    XCTAssertEqual(moved.transaction.accountAmountE4, AmountE4(whole: 5_000))

    store.undo()
    let back = try XCTUnwrap(try repository.entry(id: entry.id))
    XCTAssertEqual(back.transaction.paymentMethodId, card.id)
    XCTAssertNil(back.transaction.accountCurrency)
    XCTAssertNil(back.transaction.accountAmountE4)
  }

  /// Without the rate of the day nothing can be charged: the operation stays where it is, and
  /// the confirmation says why.
  func testAnOperationWithoutTheRateToChargeItStaysWhereItIs() throws {
    let (entry, _, kaspi) = try coffeeOnTheCard()
    let plan = store.plan(.paymentMethod(kaspi.id), ids: [entry.id], calendar: .utc)
    XCTAssertEqual(plan.changed, [])
    XCTAssertEqual(plan.skipped.map(\.reason), [.noRateForCharge])
  }

  /// A purchase a refund takes money back from is not deleted from under it: planned from the
  /// store, the deletion leaves it and says why.
  func testThePlannedDeletionKeepsAPurchaseWhoseRefundStays() throws {
    let entries = try saveEntries(["Sneakers"])
    let purchase = entries[0]
    let draft = try RefundRules.draft(
      refunding: purchase.parts[0], of: purchase, amount: AmountE4(whole: 40),
      occurredAt: purchase.transaction.occurredAt.addingTimeInterval(3600), accountId: nil,
      index: RefundIndex(entries: [purchase], debts: [:]), tree: CategoryTree())
    let refund = try repository.save(try draft.materialize())
    try showDatabase()

    let plan = store.planDeletion(ids: [purchase.id])
    XCTAssertEqual(plan.changed, [])
    XCTAssertEqual(plan.skipped.map(\.reason), [.hasRefunds])
    XCTAssertEqual(store.planDeletion(ids: [purchase.id, refund.id]).changed.count, 2)
  }

  /// The account menu of a selection moves operations to another account and never to none:
  /// every operation keeps one. The main account comes first, as in every menu of accounts,
  /// and an archived one is not offered.
  func testTheAccountMenuOffersEveryLiveAccountMainFirstAndNeverNone() {
    let cash = PaymentMethod(name: "Cash", currency: .rub)
    let main = PaymentMethod(name: "Zeta card", currency: .rub, isDefault: true)
    var old = PaymentMethod(name: "Old", currency: .rub)
    old.archived = true
    let edits = BulkMenuItems.accountEdits(
      [cash, old, main], locale: Locale(identifier: "en_US"))
    XCTAssertEqual(edits, [.paymentMethod(main.id), .paymentMethod(cash.id)])
    XCTAssertFalse(edits.contains(.paymentMethod(nil)))
  }

  /// Only a change of the account works out what an account is charged: the rest of the menu
  /// — a category, a place, an event, a quality, «на кого» — never reads the rate cache.
  func testOnlyAChangeOfTheAccountReadsTheRates() {
    XCTAssertTrue(BulkRates.needed(for: .paymentMethod(UUID())))
    for edit: BulkEdit in [
      .category(UUID()), .refile(from: [UUID()], to: UUID()), .quality(.bad),
      .forWhom(.family), .forPerson(UUID()), .event(nil), .place(UUID()),
    ] {
      XCTAssertFalse(BulkRates.needed(for: edit), "\(edit)")
    }
  }

  // MARK: An account in the archive stays at zero

  /// The card (main) counted 10,000 ₽ and the cash counted the sum of `purchases` at 06:00 of
  /// 18 September, each purchase paid in cash after it, and the cash then archived at zero —
  /// the lists showing the whole database. Returns the ids of the purchases.
  private func purchasesOnArchivedCash(
    _ purchases: [Int64]
  ) async throws -> (card: PaymentMethod, cash: PaymentMethod, ids: [UUID]) {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    self.stack = stack
    repository = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      repository, references: references, planning: PlanningRepository(writer: stack.writer))
    written = []
    store.didWrite = { [weak self] write in self?.written.append(write.touchedIds) }
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    var cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    for account in [card, cash] { try references.save(account) }
    let morning = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
      .addingTimeInterval(6 * 3_600)
    let count = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 18), reconciledAt: morning,
      actualTotalRubE4: .zero, kind: .accounts)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [count],
          reconciledBalances: [
            ReconciledBalance(
              reconciliationId: count.id, accountId: card.id, currency: .rub,
              actualE4: AmountE4(whole: 10_000)),
            ReconciledBalance(
              reconciliationId: count.id, accountId: cash.id, currency: .rub,
              actualE4: AmountE4(whole: purchases.reduce(0, +))),
          ])))
    let entries = try purchases.enumerated().map { index, whole in
      var draft = TransactionDraft(
        occurredAt: morning.addingTimeInterval(3_600 + TimeInterval(index)),
        amount: AmountE4(whole: whole), note: "market \(index)", paymentMethodId: cash.id)
      draft.normalizeSinglePart()
      return try draft.materialize(now: morning)
    }
    try repository.insert(entries)
    cash.archived = true
    try references.save(cash)
    try await showEverything()
    return (card, cash, entries.map(\.id))
  }

  /// The lists over the whole database: accounts, counts and transfers included.
  private func showEverything() async throws {
    let stack = try XCTUnwrap(stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    store.show(Ledger(dataset: dataset, calendar: .utc))
  }

  /// The balances of the card and the cash, and the transfers, as the database has them now.
  private func money(
    _ card: PaymentMethod, _ cash: PaymentMethod
  ) async throws -> (card: AmountE4?, cash: AmountE4?, transfers: [UUID]) {
    let stack = try XCTUnwrap(stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let balances = TransactionsStore.balances(of: dataset)
    return (
      balances[BalanceKey(accountId: card.id, currency: .rub)]?.amountE4,
      balances[BalanceKey(accountId: cash.id, currency: .rub)]?.amountE4,
      dataset.transfers.map(\.id)
    )
  }

  /// Two purchases paid in cash moved to the card after the cash went to the archive at zero:
  /// the 5,000 ₽ would come back onto the cash. The change is confirmed first though it splits
  /// nothing and leaves nothing alone, the confirmation asks where the money goes, and the
  /// change and the transfer to the card are one write — the cash at zero, the card holding the
  /// money — that one ⌘Z takes back whole.
  func testABulkChangeLeavingMoneyOnAnArchivedAccountSettlesInOneStep() async throws {
    let (card, cash, ids) = try await purchasesOnArchivedCash([2_000, 3_000])
    let actions = OperationActions()
    actions.request(
      .paymentMethod(card.id), on: Set(ids), store: store, environment: AppEnvironment())
    guard case .edit(let edit, let asked, let plan) = actions.confirmation else {
      return XCTFail("a change that moves archived money is confirmed first")
    }
    XCTAssertFalse(plan.touchesSplit)
    XCTAssertEqual(plan.skipped, [])
    XCTAssertEqual(
      try repository.entries(ids: ids).map(\.transaction.paymentMethodId), [cash.id, cash.id],
      "nothing is written before the confirmation")

    let check = store.archivedLeftovers(of: edit, ids: Set(asked), calendar: .utc)
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: 5_000)])
    let settling = ArchivedMoneyForm(
      check: check, accounts: [card, cash], locale: Locale(identifier: "en")
    ).transfers(now: Date(), note: "left over")
    XCTAssertEqual(settling.first?.toAccountId, card.id)
    XCTAssertTrue(store.apply(edit, to: asked, calendar: .utc, settling: settling))
    XCTAssertEqual(written.count, 1, "one write")
    let after = try await money(card, cash)
    XCTAssertEqual(after.cash, .zero, "the archived cash stays at zero")
    XCTAssertEqual(after.card, AmountE4(whole: 10_000), "the card paid and got the money back")
    XCTAssertEqual(after.transfers, settling.map(\.id))

    store.undo()
    let undone = try await money(card, cash)
    XCTAssertEqual(undone.transfers, [], "one ⌘Z takes the transfer back with the change")
    XCTAssertEqual(undone.cash, .zero)
    XCTAssertEqual(undone.card, AmountE4(whole: 10_000))
    XCTAssertTrue(
      try repository.entries(ids: ids).allSatisfy { $0.transaction.paymentMethodId == cash.id })
    XCTAssertFalse(store.canUndo, "the change and its transfer were one step")
  }

  /// The same with more operations than are written on the main thread: the change and its
  /// transfer land in the background as one write, and its undo — in the background too —
  /// takes the transfer back.
  func testALargeBulkChangeLeavingMoneyOnAnArchivedAccountSettlesInOneStep() async throws {
    let (card, cash, ids) = try await purchasesOnArchivedCash(
      Array(repeating: 1, count: TransactionsStore.backgroundThreshold + 1))
    let edit = BulkEdit.paymentMethod(card.id)
    let check = store.archivedLeftovers(of: edit, ids: Set(ids), calendar: .utc)
    XCTAssertEqual(
      check.leftovers.map(\.amount),
      [AmountE4(whole: Int64(TransactionsStore.backgroundThreshold + 1))])
    let settling = ArchivedMoneyForm(
      check: check, accounts: [card, cash], locale: Locale(identifier: "en")
    ).transfers(now: Date(), note: "left over")

    XCTAssertTrue(store.apply(edit, to: ids, calendar: .utc, settling: settling))
    XCTAssertTrue(store.isWritingInBackground)
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertEqual(written.count, 1)
    let after = try await money(card, cash)
    XCTAssertEqual(after.cash, .zero)
    XCTAssertEqual(after.card, AmountE4(whole: 10_000))
    XCTAssertEqual(after.transfers, settling.map(\.id))

    store.undo()
    XCTAssertTrue(store.isWritingInBackground, "a step that large is undone off the main thread")
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertEqual(written.count, 2)
    let back = try await money(card, cash)
    XCTAssertEqual(back.transfers, [], "one ⌘Z takes the transfer back with the change")
    XCTAssertEqual(back.cash, .zero)
    XCTAssertEqual(back.card, AmountE4(whole: 10_000))
    XCTAssertFalse(store.canUndo)
  }

  /// The two cash purchases are asked about and the owner is choosing where their 5,000 ₽ go
  /// when the first one, 2,000 ₽, is moved to the card elsewhere with its own transfer. Returns
  /// the purchases in their order, the change as it was confirmed, the 5,000 ₽ transfer worked
  /// out for it, and the operations it planned to change.
  private func aBulkMoveOvertaken() async throws -> (
    card: PaymentMethod, cash: PaymentMethod, ids: [UUID], edit: BulkEdit, settling: [Transfer],
    planned: Set<UUID>, meanwhile: [Transfer]
  ) {
    let (card, cash, ids) = try await purchasesOnArchivedCash([2_000, 3_000])
    let actions = OperationActions()
    actions.request(
      .paymentMethod(card.id), on: Set(ids), store: store, environment: AppEnvironment())
    guard case .edit(let edit, let asked, let plan) = actions.confirmation else {
      XCTFail("a change that moves archived money is confirmed first")
      throw CancellationError()
    }
    let check = store.archivedLeftovers(of: edit, ids: Set(asked), calendar: .utc)
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: 5_000)])
    let settling = ArchivedMoneyForm(
      check: check, accounts: [card, cash], locale: Locale(identifier: "en")
    ).transfers(now: Date(), note: "left over")

    let first = ids[0]
    let alone = store.archivedLeftovers(of: edit, ids: [first], calendar: .utc)
    XCTAssertEqual(alone.leftovers.map(\.amount), [AmountE4(whole: 2_000)])
    let meanwhile = ArchivedMoneyForm(
      check: alone, accounts: [card, cash], locale: Locale(identifier: "en")
    ).transfers(now: Date(), note: "moved elsewhere")
    try repository.modify(ids: [first], settlingTransfers: meanwhile) { fresh in
      var moved = fresh
      moved.transaction.paymentMethodId = card.id
      return moved
    }
    let between = try await money(card, cash)
    XCTAssertEqual(between.cash, .zero, "the move elsewhere settled its own 2,000 ₽")
    XCTAssertEqual(Set(asked), Set(ids))
    return (card, cash, ids, edit, settling, Set(plan.changed.map(\.id)), meanwhile)
  }

  /// The confirmed change lands on the second purchase alone now, but its transfer counts
  /// 5,000 ₽ of both: written, it would take the archived cash to −2,000 ₽ and the card 2,000 ₽
  /// too high. Nothing is written, and the screen says the operations changed meanwhile.
  func testABulkMoveWhosePlanChangedMeanwhileWritesNothing() async throws {
    let setup = try await aBulkMoveOvertaken()
    XCTAssertFalse(
      store.apply(setup.edit, to: setup.ids, calendar: .utc, settling: setup.settling))
    let after = try await money(setup.card, setup.cash)
    XCTAssertEqual(after.cash, .zero, "the archived cash stays at zero")
    XCTAssertEqual(after.card, AmountE4(whole: 10_000))
    XCTAssertEqual(after.transfers, setup.meanwhile.map(\.id), "no 5,000 ₽ transfer")
    XCTAssertEqual(
      try repository.entry(id: setup.ids[1])?.transaction.paymentMethodId, setup.cash.id,
      "the second purchase stays on the cash")
    XCTAssertEqual(written, [])
    XCTAssertFalse(store.canUndo, "nothing to undo")
    let failure = try XCTUnwrap(store.failure, "the screen is told")
    XCTAssertEqual(failure, StoreFailure(action: .change, cause: .planOutdated))
    let language = AppLanguage()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = language.choice
    defer { language.choice = before }
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      let message = StoreFailureText.message(failure, language: language)
      XCTAssertFalse(message.hasPrefix("store.failure"), "\(message) in \(choice.rawValue)")
      XCTAssertNotEqual(
        message, language("store.failure.other", table: "Transactions"), "\(choice.rawValue)")
    }
  }

  /// The same once the lists show the move made elsewhere: planned again from them, the change
  /// would land on the second purchase alone and look right. The confirmation hands over the
  /// operations it planned on, so the 5,000 ₽ transfer is still refused.
  func testABulkMoveWhosePlanChangedMeanwhileWritesNothingOnceTheListsFollow() async throws {
    let setup = try await aBulkMoveOvertaken()
    try await showEverything()
    XCTAssertFalse(
      store.apply(
        setup.edit, to: setup.ids, calendar: .utc, settling: setup.settling,
        planned: setup.planned))
    let after = try await money(setup.card, setup.cash)
    XCTAssertEqual(after.cash, .zero, "the archived cash stays at zero")
    XCTAssertEqual(after.card, AmountE4(whole: 10_000))
    XCTAssertEqual(after.transfers, setup.meanwhile.map(\.id), "no 5,000 ₽ transfer")
    XCTAssertEqual(
      try repository.entry(id: setup.ids[1])?.transaction.paymentMethodId, setup.cash.id)
    XCTAssertEqual(store.failure?.cause, .planOutdated)
  }

  /// The two cash purchases are asked about for deletion and the owner is choosing where their
  /// 5,000 ₽ go when the first one, 2,000 ₽, is deleted elsewhere with its own transfer. Returns
  /// the purchases in their order, the 5,000 ₽ transfer worked out for the deletion, the
  /// operations it planned to take, the transfer made elsewhere, and the card's balance after
  /// it.
  private func aBulkDeletionOvertaken() async throws -> (
    card: PaymentMethod, cash: PaymentMethod, ids: [UUID], settling: [Transfer],
    planned: Set<UUID>, meanwhile: [Transfer], cardBetween: AmountE4?
  ) {
    let (card, cash, ids) = try await purchasesOnArchivedCash([2_000, 3_000])
    let actions = OperationActions()
    actions.requestDeletion(of: Set(ids), store: store)
    guard case .delete(let asked, _, _, _, _) = actions.confirmation else {
      XCTFail("a deletion is confirmed first")
      throw CancellationError()
    }
    XCTAssertEqual(Set(asked), Set(ids))
    let check = store.archivedLeftovers(ofDeleting: ids)
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: 5_000)])
    let planned = store.deletionPlanned(of: ids)
    XCTAssertEqual(planned, Set(ids))
    let settling = ArchivedMoneyForm(
      check: check, accounts: [card, cash], locale: Locale(identifier: "en")
    ).transfers(now: Date(), note: "left over")

    let first = ids[0]
    let alone = store.archivedLeftovers(ofDeleting: [first])
    XCTAssertEqual(alone.leftovers.map(\.amount), [AmountE4(whole: 2_000)])
    let meanwhile = ArchivedMoneyForm(
      check: alone, accounts: [card, cash], locale: Locale(identifier: "en")
    ).transfers(now: Date(), note: "deleted elsewhere")
    _ = try PlanningRepository(writer: try XCTUnwrap(stack).writer).apply(
      PlanningChange(
        upsert: PlanningRows(transfers: meanwhile), softDeleted: [first], at: Date()))
    let between = try await money(card, cash)
    XCTAssertEqual(between.cash, .zero, "the deletion elsewhere settled its own 2,000 ₽")
    XCTAssertEqual(between.card, AmountE4(whole: 12_000))
    return (card, cash, ids, settling, planned, meanwhile, between.card)
  }

  /// The confirmed deletion takes the second purchase alone now — the first is gone already —,
  /// but its transfer counts 5,000 ₽ of both: written, it would take the archived cash to
  /// −2,000 ₽ and the card 2,000 ₽ too high. Nothing is written, and the screen says the
  /// operations changed meanwhile.
  func testABulkDeletionWhosePlanChangedMeanwhileWritesNothing() async throws {
    let setup = try await aBulkDeletionOvertaken()
    XCTAssertFalse(store.delete(ids: setup.ids, settling: setup.settling))
    let after = try await money(setup.card, setup.cash)
    XCTAssertEqual(after.cash, .zero, "the archived cash stays at zero")
    XCTAssertEqual(
      after.card, setup.cardBetween, "the card is where the deletion elsewhere left it")
    XCTAssertEqual(after.transfers, setup.meanwhile.map(\.id), "no 5,000 ₽ transfer")
    XCTAssertEqual(
      try repository.entry(id: setup.ids[1])?.transaction.isDeleted, false,
      "the second purchase stays")
    XCTAssertEqual(written, [])
    XCTAssertFalse(store.canUndo, "nothing to undo")
    XCTAssertEqual(store.failure, StoreFailure(action: .delete, cause: .planOutdated))
  }

  /// The same once the lists show the deletion made elsewhere: planned again from them, the
  /// deletion would take the second purchase alone and look right. The confirmation hands over
  /// the operations it planned on, so the 5,000 ₽ transfer is still refused.
  func testABulkDeletionWhosePlanChangedMeanwhileWritesNothingOnceTheListsFollow() async throws {
    let setup = try await aBulkDeletionOvertaken()
    try await showEverything()
    XCTAssertEqual(store.deletionPlanned(of: setup.ids), [setup.ids[1]])
    XCTAssertFalse(
      store.delete(ids: setup.ids, settling: setup.settling, planned: setup.planned))
    let after = try await money(setup.card, setup.cash)
    XCTAssertEqual(after.cash, .zero, "the archived cash stays at zero")
    XCTAssertEqual(after.card, setup.cardBetween)
    XCTAssertEqual(after.transfers, setup.meanwhile.map(\.id), "no 5,000 ₽ transfer")
    XCTAssertEqual(try repository.entry(id: setup.ids[1])?.transaction.isDeleted, false)
    XCTAssertFalse(store.canUndo)
    XCTAssertEqual(store.failure, StoreFailure(action: .delete, cause: .planOutdated))
  }

  /// Nothing changed meanwhile: the deletion confirmed with its plan takes both purchases and
  /// the 5,000 ₽ transfer in one write, and one ⌘Z brings all of it back.
  func testABulkDeletionWithItsPlanSettlesInOneStep() async throws {
    let (card, cash, ids) = try await purchasesOnArchivedCash([2_000, 3_000])
    let check = store.archivedLeftovers(ofDeleting: ids)
    let planned = store.deletionPlanned(of: ids)
    let settling = ArchivedMoneyForm(
      check: check, accounts: [card, cash], locale: Locale(identifier: "en")
    ).transfers(now: Date(), note: "left over")
    XCTAssertTrue(store.delete(ids: ids, settling: settling, planned: planned))
    XCTAssertEqual(written.count, 1, "one write")
    let after = try await money(card, cash)
    XCTAssertEqual(after.cash, .zero, "the archived cash stays at zero")
    XCTAssertEqual(after.card, AmountE4(whole: 15_000))
    XCTAssertEqual(after.transfers, settling.map(\.id))
    XCTAssertNil(store.failure)

    store.undo()
    let undone = try await money(card, cash)
    XCTAssertEqual(undone.transfers, [], "one ⌘Z takes the transfer back with the deletion")
    XCTAssertEqual(undone.cash, .zero)
    XCTAssertEqual(undone.card, AmountE4(whole: 10_000))
    XCTAssertTrue(try repository.entries(ids: ids).allSatisfy { !$0.transaction.isDeleted })
    XCTAssertFalse(store.canUndo)
  }
}
