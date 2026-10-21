import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// What the counts wrote reaches the lists with the write that moved them: the store lays the
/// operations of the differences made, rewritten or taken away over what it reports, reads
/// planning again when a count's numbers moved, and its ⌘Z hands the differences as they were
/// back to the settle — a difference the write took to zero comes back as the owner left it.
@MainActor
final class LiveCountsOverlayTests: XCTestCase {
  private var stack: DatabaseStack!
  private var transactions: TransactionRepository!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var store: TransactionsStore!
  private var writes: [StoreWrite] = []
  private let card = PaymentMethod(name: "T-Bank", kind: .card, currency: .rub, isDefault: true)
  private let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
  private let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
  private let salary = CoreKit.Category(kind: .income, name: "Salary")

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let context = LiveCountsContext(calendar: .utc, categoryName: "Сверка")
    transactions = TransactionRepository(writer: stack.writer, liveCounts: context)
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer, liveCounts: context)
    for account in [card, cash] { try references.save(account) }
    for category in [groceries, salary] { try references.save(category) }
    store = TransactionsStore(repository: transactions, references: references)
    store.attach(transactions, references: references, planning: planning)
    writes = []
    store.didWrite = { [weak self] in self?.writes.append($0) }
  }

  private var key: BalanceKey { BalanceKey(accountId: card.id, currency: .rub) }

  private func at(_ day: Int, hour: Int = 12) -> Date {
    CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: day))
      .addingTimeInterval(TimeInterval(hour * 3_600))
  }

  private func operation(
    _ whole: Int64, _ kind: TransactionKind = .expense, on day: Int
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind, occurredAt: at(day), amount: AmountE4(whole: whole), paymentMethodId: card.id)
    draft.parts = [
      PartDraft(
        categoryId: kind == .expense ? groceries.id : salary.id, amount: AmountE4(whole: whole))
    ]
    return try draft.materialize(now: at(day))
  }

  /// One count of the card, handed to the settle the way the sheet hands it: `expected` is what
  /// the books hold then, `nil` for the first count.
  @discardableResult
  private func count(_ whole: Int64, at moment: Date, expected: Int64?) throws -> ReconciledBalance
  {
    let reconciliation = Reconciliation(
      date: CalendarContext.utc.day(of: moment), reconciledAt: moment, actualTotalRubE4: .zero,
      kind: .accounts)
    let row = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: card.id, currency: .rub,
      actualE4: AmountE4(whole: whole), expectedE4: expected.map { AmountE4(whole: $0) },
      differenceE4: expected.map { AmountE4(whole: whole - $0) },
      recordsDifference: expected == nil ? nil : true)
    var upsert = PlanningRows.empty
    upsert.reconciliations = [reconciliation]
    upsert.reconciledBalances = [row]
    _ = try planning.apply(PlanningChange(upsert: upsert, at: moment, settles: [key]))
    return row
  }

  /// The card first counted 01.09 at 50,000, +100,000 on 03.09 and −12,000 on 05.09 on time,
  /// counted 130,000 on 20.09: «Сверка» −8,000. Returns that operation.
  private func september() throws -> TransactionEntry {
    try count(50_000, at: at(1, hour: 9), expected: nil)
    try transactions.save(try operation(100_000, .income, on: 3))
    try transactions.save(try operation(12_000, on: 5))
    let later = try count(130_000, at: at(20, hour: 10), expected: 138_000)
    let difference = try XCTUnwrap(
      try transactions.entry(id: ReconcileDifferenceIds.operation(forCount: later.id)))
    XCTAssertEqual(difference.transaction.amountE4, AmountE4(whole: 8_000))
    return difference
  }

  /// A taxi of 3,000 dated 10.09 entered on the 21st: the store reports the difference rewritten
  /// to 5,000 with the taxi, and planning read again.
  func testABackdatedSaveLaysTheRewrittenDifferenceOverTheLists() throws {
    let difference = try september()
    writes = []
    XCTAssertTrue(store.save(try operation(3_000, on: 10)))
    let write = try XCTUnwrap(writes.last)
    let laid = try XCTUnwrap(write.upserted.first { $0.id == difference.id })
    XCTAssertEqual(laid.transaction.amountE4, AmountE4(whole: 5_000))
    XCTAssertTrue(write.planningChanged)

    store.undo()
    let undone = try XCTUnwrap(writes.last)
    XCTAssertEqual(
      undone.upserted.first { $0.id == difference.id }?.transaction.amountE4,
      AmountE4(whole: 8_000))
    XCTAssertEqual(
      try transactions.entry(id: difference.id)?.transaction.amountE4, AmountE4(whole: 8_000))
  }

  /// The owner files «Сверка» −8,000 under «Groceries» with a comment, then enters the 8,000
  /// that were missing: the difference is zero and its operation goes — the store says so. ⌘Z
  /// of the entry brings it back as he left it.
  func testUndoOfASaveThatZeroedADifferenceBringsTheOwnersOperationBack() throws {
    var difference = try september()
    difference.transaction.note = "for mum"
    difference.parts[0].categoryId = groceries.id
    try transactions.save(difference)
    let filed = try XCTUnwrap(try transactions.entry(id: difference.id))
    writes = []

    XCTAssertTrue(store.save(try operation(8_000, on: 12)))
    XCTAssertEqual(writes.last?.removed, [difference.id])
    XCTAssertNil(try transactions.entry(id: difference.id))

    store.undo()
    XCTAssertEqual(try transactions.entry(id: difference.id), filed)
    let laid = try XCTUnwrap(writes.last?.upserted.first { $0.id == difference.id })
    XCTAssertEqual(laid.transaction.note, "for mum")
    XCTAssertEqual(laid.parts.map(\.categoryId), [groceries.id])
  }

  /// The inspector kept the difference as it was at 8,000 while a backdated taxi made it 5,000;
  /// its comment is then saved: it lands, over the 5,000 the count gives it now.
  func testAStaleCopyOfADifferenceSavesItsCommentOverTheAmountOfNow() throws {
    let open = try september()
    XCTAssertTrue(store.save(try operation(3_000, on: 10)))
    var edited = open
    edited.transaction.note = "lost at the market"
    edited.transaction.updatedAt = at(21)
    XCTAssertEqual(store.saveEdit(edited, calendar: .utc), .saved)
    let written = try XCTUnwrap(try transactions.entry(id: open.id))
    XCTAssertEqual(written.transaction.note, "lost at the market")
    XCTAssertEqual(written.transaction.amountE4, AmountE4(whole: 5_000))
    XCTAssertEqual(written.parts.map(\.amountE4), [AmountE4(whole: 5_000)])
  }

  /// A bulk move of the September groceries to the cash takes their 12,000 out of the card's
  /// window — the card now misses 20,000 — and its ⌘Z brings the difference of 8,000 back; the
  /// store reports both.
  func testABulkChangeAndItsUndoLayTheDifference() throws {
    let difference = try september()
    let groceriesIds = try transactions.entries(from: .distantPast, to: .distantFuture)
      .filter { $0.transaction.kind == .expense && $0.id != difference.id }.map(\.id)
    writes = []
    XCTAssertTrue(store.apply(.paymentMethod(cash.id), to: groceriesIds))
    let moved = try XCTUnwrap(try transactions.entry(id: difference.id))
    XCTAssertEqual(moved.transaction.kind, .expense)
    XCTAssertEqual(moved.transaction.amountE4, AmountE4(whole: 20_000))
    XCTAssertEqual(
      writes.last?.upserted.first { $0.id == difference.id }?.transaction.amountE4,
      AmountE4(whole: 20_000))
    XCTAssertTrue(writes.last?.planningChanged == true)

    store.undo()
    let back = try XCTUnwrap(try transactions.entry(id: difference.id))
    XCTAssertEqual(back.transaction.amountE4, AmountE4(whole: 8_000))
    XCTAssertEqual(
      writes.last?.upserted.first { $0.id == difference.id }?.transaction.amountE4,
      AmountE4(whole: 8_000))
  }
}
