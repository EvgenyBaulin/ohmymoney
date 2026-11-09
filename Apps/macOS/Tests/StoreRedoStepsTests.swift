import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// ⇧⌘Z for the steps beyond an operation: the plan of the year, planning, rules (also applied to
/// the past), baskets, files, a move from another application and bulk changes. Each one is the
/// same write again as one step of ⌘Z; a new write after ⌘Z ends the chain.
@MainActor
final class StoreRedoStepsTests: XCTestCase {
  private var stack: DatabaseStack!
  private var repository: TransactionRepository!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var spending: SpendingRulesRepository!
  private var year: YearPlanRepository!
  private var subscriptions: SubscriptionRepository!
  private var imports: StatementImportRepository!
  private var service: AttachmentService!
  private var store: TransactionsStore!
  private var directory: URL!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-redo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    repository = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    spending = SpendingRulesRepository(writer: stack.writer)
    year = YearPlanRepository(writer: stack.writer)
    subscriptions = SubscriptionRepository(writer: stack.writer)
    imports = StatementImportRepository(writer: stack.writer)
    service = AttachmentService(
      repository: AttachmentRepository(writer: stack.writer),
      store: AttachmentFileStore(root: directory.appendingPathComponent("Files")))
    store = TransactionsStore()
    store.attach(
      repository, references: references, planning: planning, spending: spending, year: year,
      subscriptions: subscriptions, imports: imports, attachments: service)
  }

  override func tearDown() async throws {
    store = nil
    service = nil
    stack = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private func entry(
    _ note: String, whole: Int64 = 100, minutes: Double = 0
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
        .addingTimeInterval(minutes * 60),
      amount: AmountE4(whole: whole), note: note)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  // MARK: The plan of the year

  func testALimitOfAMonthIsMadeAgainAndTakenBackAgain() throws {
    let budget = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(budgets: [budget]))))
    let december = MonthKey(year: 2026, month: 12)
    XCTAssertTrue(store.setMonthLimit(AmountE4(whole: 20_000), budget: budget.id, month: december))

    store.undo()
    XCTAssertTrue(try year.data().monthExceptions.isEmpty)
    XCTAssertTrue(store.canRedo)

    store.redo()
    XCTAssertEqual(try year.data().monthExceptions.map(\.amountE4), [AmountE4(whole: 20_000)])
    XCTAssertFalse(store.canRedo)
    store.undo()
    XCTAssertTrue(try year.data().monthExceptions.isEmpty, "the redo is one step of ⌘Z again")
  }

  func testALimitAfterAnUndoEndsTheChain() throws {
    let budget = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(budgets: [budget]))))
    let december = MonthKey(year: 2026, month: 12)
    XCTAssertTrue(store.setMonthLimit(AmountE4(whole: 20_000), budget: budget.id, month: december))
    store.undo()
    XCTAssertTrue(store.canRedo)
    XCTAssertTrue(store.setMonthLimit(AmountE4(whole: 30_000), budget: budget.id, month: december))
    XCTAssertFalse(store.canRedo)
  }

  func testTheBufferAndItsMarksAreMadeAgain() throws {
    let marked: Set<UUID> = [UUID()]
    XCTAssertTrue(store.setBuffer(MonthBufferSettings(amount: AmountE4(whole: 7_000))))
    XCTAssertTrue(store.setBufferMarks(marked))
    store.undo()
    store.undo()
    XCTAssertFalse(try year.data().buffer.isOn)
    store.redo()
    XCTAssertEqual(try year.data().buffer.amount, AmountE4(whole: 7_000))
    store.redo()
    XCTAssertEqual(try year.data().bufferMarks, marked)
    XCTAssertFalse(store.canRedo)
  }

  func testAnEventTemplateCreatedAndDeletedIsMadeAgain() throws {
    let template = EventTemplate(
      id: "mine", name: "Trip", isBuiltIn: false, eventKind: .trip, totalE4: AmountE4(whole: 10), lines: [])
    XCTAssertTrue(store.saveEventTemplate(template))
    store.undo()
    XCTAssertTrue(try year.data().eventTemplates.filter { $0.id == "mine" }.isEmpty)
    store.redo()
    XCTAssertEqual(try year.data().eventTemplates.filter { $0.id == "mine" }.count, 1)
    XCTAssertTrue(store.deleteEventTemplate(id: "mine"))
    store.undo()
    XCTAssertEqual(try year.data().eventTemplates.filter { $0.id == "mine" }.count, 1)
    store.redo()
    XCTAssertTrue(try year.data().eventTemplates.filter { $0.id == "mine" }.isEmpty)
  }

  // MARK: Subscriptions

  func testTheTermsAndTheDaysOfUseOfAPaymentAreMadeAgain() throws {
    let payment = ScheduledPayment(name: "Music", amountE4: AmountE4(whole: 300))
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(scheduled: [payment]))))
    var terms = SubscriptionTerms(paymentId: payment.id)
    terms.needed = true
    XCTAssertTrue(store.saveSubscriptionTerms(terms))
    let day = DateOnly(year: 2026, month: 9, day: 1)
    XCTAssertTrue(store.markSubscriptionUsed(payment: payment.id, on: day))

    store.undo()
    store.undo()
    XCTAssertTrue(try subscriptions.book().usage.isEmpty)
    XCTAssertTrue(try subscriptions.book().terms.isEmpty)
    store.redo()
    XCTAssertEqual(try subscriptions.book().terms.map(\.needed), [true])
    store.redo()
    XCTAssertEqual(try subscriptions.book().usage.map(\.day), [day])
    XCTAssertFalse(store.canRedo)
    store.undo()
    XCTAssertTrue(try subscriptions.book().usage.isEmpty)
  }

  func testRemovingADayOfUseIsMadeAgain() throws {
    let payment = ScheduledPayment(name: "Music", amountE4: AmountE4(whole: 300))
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(scheduled: [payment]))))
    let day = DateOnly(year: 2026, month: 9, day: 1)
    XCTAssertTrue(store.markSubscriptionUsed(payment: payment.id, on: day))
    let mark = try XCTUnwrap(try subscriptions.book().usage.first)
    XCTAssertTrue(store.removeSubscriptionUsage(ids: [mark.id]))
    store.undo()
    XCTAssertEqual(try subscriptions.book().usage.count, 1)
    store.redo()
    XCTAssertTrue(try subscriptions.book().usage.isEmpty)
  }

  // MARK: Planning

  func testAPaymentAddedThroughPlanningIsMadeAgainAsOneStep() throws {
    let payment = ScheduledPayment(name: "Rent", amountE4: AmountE4(whole: 900))
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(scheduled: [payment]))))
    store.undo()
    XCTAssertTrue(try planning.book().scheduled.isEmpty)
    store.redo()
    XCTAssertEqual(try planning.book().scheduled.map(\.id), [payment.id])
    store.undo()
    XCTAssertTrue(try planning.book().scheduled.isEmpty)
  }

  // MARK: Rules, rules applied to the past, tags and baskets

  func testTheBasketOfACategoryIsMadeAgain() throws {
    let category = CoreKit.Category(kind: .expense, name: "Fun")
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(categories: [category]))))
    XCTAssertTrue(store.setBasket(.wants, ofCategory: category.id))
    store.undo()
    XCTAssertNil(try spending.basket(ofCategory: category.id))
    XCTAssertTrue(store.canRedo)
    store.redo()
    XCTAssertEqual(try spending.basket(ofCategory: category.id), .wants)
    store.undo()
    XCTAssertNil(try spending.basket(ofCategory: category.id))
  }

  func testARuleAddedIsMadeAgain() throws {
    let rule = Rule(
      name: "Coffee", conditions: [.textContains("coffee")], actions: [.setCategory(UUID())])
    XCTAssertTrue(store.addRule(rule))
    store.undo()
    XCTAssertTrue(try spending.rules().isEmpty)
    store.redo()
    XCTAssertEqual(try spending.rules().map(\.id), [rule.id])
  }

  func testRulesAppliedToThePastAreMadeAgainAsOneStep() throws {
    XCTAssertTrue(store.save(try entry("coffee")))
    let past = try XCTUnwrap(try repository.entries(from: .distantPast, to: .distantFuture).first)
    var changed = past
    changed.transaction.note = "rewritten by a rule"
    let commit = RuleBackfillCommit(
      writes: [changed], tagLinksToAdd: [],
      undo: RuleBackfillUndo(entries: [past], tagLinksToRemove: []))
    XCTAssertTrue(store.applyBackfill(commit))
    XCTAssertEqual(
      try repository.entry(id: past.id)?.transaction.note, "rewritten by a rule")

    store.undo()
    XCTAssertEqual(try repository.entry(id: past.id)?.transaction.note, "coffee")
    XCTAssertTrue(store.canRedo)

    store.redo()
    XCTAssertEqual(
      try repository.entry(id: past.id)?.transaction.note, "rewritten by a rule")
    XCTAssertFalse(store.canRedo)
    store.undo()
    XCTAssertEqual(try repository.entry(id: past.id)?.transaction.note, "coffee")
  }

  func testAChangeOfTheTagDictionaryIsMadeAgain() throws {
    let tag = Tag(name: "Trip")
    XCTAssertTrue(store.apply(TagEdit(before: TagBook(), after: TagBook(tags: [tag]))))
    store.undo()
    XCTAssertTrue(try spending.tagBook().tags.isEmpty)
    store.redo()
    XCTAssertEqual(try spending.tagBook().tags.map(\.id), [tag.id])
  }

  // MARK: Files

  func testAFileAttachedIsPutBackWithItsBytes() throws {
    let owner = try entry("owner")
    XCTAssertTrue(store.save(owner))
    let file = try service.add(
      data: Data("synthetic".utf8), fileName: "a.pdf", to: .transaction, id: owner.id)
    store.recordAttachmentsAdded([file])

    store.undo()
    XCTAssertNil(try service.repository.attachment(id: file.id))
    store.redo()
    let back = try XCTUnwrap(try service.repository.attachment(id: file.id))
    XCTAssertEqual(try service.store.data(forHash: back.contentHash), Data("synthetic".utf8))
    XCTAssertEqual(service.availability(of: back), .present)
    store.undo()
    XCTAssertNil(try service.repository.attachment(id: file.id), "one step of ⌘Z again")
  }

  func testAFileSentToTheTrashIsSentAgain() throws {
    let owner = try entry("owner")
    XCTAssertTrue(store.save(owner))
    let file = try service.add(
      data: Data("synthetic".utf8), fileName: "a.pdf", to: .transaction, id: owner.id)
    XCTAssertTrue(store.trashAttachments(ids: [file.id]))
    store.undo()
    XCTAssertNil(try service.repository.attachment(id: file.id)?.trashedAt)
    store.redo()
    XCTAssertNotNil(try service.repository.attachment(id: file.id)?.trashedAt)
    XCTAssertFalse(store.canRedo)
  }

  func testAChangeOfAFileIsMadeAgain() throws {
    let owner = try entry("owner")
    XCTAssertTrue(store.save(owner))
    let file = try service.add(
      data: Data("synthetic".utf8), fileName: "a.pdf", to: .transaction, id: owner.id)
    var edited = file
    edited.note = "warranty card"
    XCTAssertTrue(store.changeAttachment(edited))
    store.undo()
    XCTAssertNil(try service.repository.attachment(id: file.id)?.note)
    store.redo()
    XCTAssertEqual(try service.repository.attachment(id: file.id)?.note, "warranty card")
  }

  // MARK: A move from another application

  func testAMoveFromAnotherApplicationIsMadeAgainWithItsImportRows() throws {
    let moved = try entry("moved")
    let record = StatementImportRecord(
      id: UUID().uuidString, accountID: "", profileID: "x", fileName: "old.csv",
      importedAt: Date(timeIntervalSince1970: 1_700_000_000), periodFrom: nil, periodTo: nil,
      rowCount: 1, newCount: 1, duplicateCount: 0, declinedCount: 0, unparsedCount: 0)
    XCTAssertTrue(store.applyMigration(PlanningChange(created: [moved]), imports: [record]))

    store.undo()
    XCTAssertNil(try repository.entry(id: moved.id))
    XCTAssertTrue(try imports.imports().isEmpty)
    XCTAssertTrue(store.canRedo)

    store.redo()
    XCTAssertEqual(try repository.entry(id: moved.id)?.transaction.note, "moved")
    XCTAssertEqual(try imports.imports().map(\.id), [record.id])
    XCTAssertFalse(store.canRedo)
    store.undo()
    XCTAssertNil(try repository.entry(id: moved.id), "one step of ⌘Z again")
  }

  // MARK: Bulk changes

  private func quality(_ id: UUID) throws -> Quality? {
    try repository.entry(id: id)?.parts.first?.quality
  }

  private func settle() async {
    if let write = store.backgroundWrite { _ = await write.value }
  }

  func testABulkChangeOfManyOperationsKeepsTheChainThroughTheBackgroundPath() async throws {
    let count = TransactionsStore.backgroundThreshold + 5
    var entries: [TransactionEntry] = []
    for index in 0..<count { entries.append(try entry("n\(index)", minutes: Double(index))) }
    try repository.insert(entries)
    let ids = entries.map(\.id)
    XCTAssertTrue(
      store.modifyMany(ids, file: #fileID) { fresh in
        var changed = fresh
        for index in changed.parts.indices { changed.parts[index].quality = .good }
        return changed
      })
    await settle()
    XCTAssertTrue(
      store.modifyMany(ids, file: #fileID) { fresh in
        var changed = fresh
        for index in changed.parts.indices { changed.parts[index].quality = .bad }
        return changed
      })
    await settle()

    XCTAssertEqual(try quality(ids[0]), .bad)
    store.undo()
    XCTAssertTrue(store.isWritingInBackground)
    await settle()
    XCTAssertNil(store.failure)
    XCTAssertEqual(try quality(ids[0]), .good)
    store.undo()
    await settle()
    XCTAssertEqual(try quality(ids[0]), nil)
    XCTAssertTrue(store.canRedo, "a large undo leaves what makes it again")

    store.redo()
    await settle()
    XCTAssertEqual(try quality(ids[0]), .good)
    XCTAssertTrue(store.canRedo, "a large redo does not end the rest of the chain")
    store.redo()
    await settle()
    XCTAssertEqual(try quality(ids[0]), .bad)
    XCTAssertFalse(store.canRedo)
  }
}
