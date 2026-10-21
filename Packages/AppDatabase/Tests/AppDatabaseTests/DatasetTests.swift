import AppCore
import CoreKit
import Foundation
import GRDB
import SQLite3
import Testing

@testable import AppDatabase

@Suite("The dataset loads in one read, whole and cancellable")
struct DatasetTests {
  // MARK: One snapshot

  /// `load` gives exactly what the repositories give one by one: the live operations with
  /// their parts, every link, the reference books with their archived rows, the debts with
  /// the closed ones, the cashback setting and the caller's version.
  @Test func theSnapshotIsWhatTheRepositoriesReturn() async throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample()
    let transactions = TransactionRepository(writer: stack.writer)
    let references = ReferenceRepository(writer: stack.writer)
    try transactions.insert(TestSupport.batch(set))
    var archived = try #require(set.categories.first { !$0.isSystem && $0.parentId == nil })
    archived.archived = true
    try references.save(archived)
    var closed = try #require(set.debts.first)
    closed.closed = true
    try references.save(closed)
    var gone = try #require(set.people.first)
    gone.archived = true
    try references.save(gone)
    try SettingsRepository(writer: stack.writer).set(
      AnalyticsSettings.cashbackCategoryKey, to: set.cashbackCategoryId.uuidString)

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 7)

    #expect(dataset.version == 7)
    let alive = try transactions.entries(from: .distantPast, to: .distantFuture)
    #expect(set.entries.contains { $0.transaction.isDeleted })
    #expect(dataset.entries.count == set.entries.filter { !$0.transaction.isDeleted }.count)
    #expect(byId(dataset.entries) == byId(alive))
    #expect(dataset.categories == (try references.categories(includeArchived: true)))
    #expect(dataset.categories.contains { $0.id == archived.id && $0.archived })
    #expect(dataset.people == (try references.people(includeArchived: true)))
    #expect(dataset.places == (try references.places(includeArchived: true)))
    #expect(dataset.events == (try references.events(includeArchived: true)))
    #expect(dataset.paymentMethods == (try references.paymentMethods(includeArchived: true)))
    #expect(dataset.goals == (try references.goals(includeArchived: true)))
    #expect(dataset.debts == (try references.debts(includeClosed: true)))
    #expect(dataset.debts.contains { $0.id == closed.id && $0.closed })
    #expect(!set.links.isEmpty)
    #expect(Set(dataset.links) == Set(set.links))
    #expect(dataset.settings.cashbackCategoryId == set.cashbackCategoryId)
  }

  /// The planning book comes in the same read: every table of the planning, the journals
  /// of every debt — the closed ones too — the reconciliations oldest first, and the
  /// planning settings.
  @Test func theSnapshotCarriesThePlanningBook() async throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let references = ReferenceRepository(writer: stack.writer)
    let closed = Debt(direction: .iOwe, type: .loan, name: "Old loan", closed: true)
    try references.save(closed)
    let closedLine = DebtEntry(debtId: closed.id, amountE4: AmountE4(whole: -500), kind: .payment)
    try references.save(closedLine)
    // Written newest first: the book still reads them oldest first, by day and then by the
    // instant within the day.
    let later = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 17), reconciledAt: PlanningTests.instant(hour: 20),
      actualTotalRubE4: AmountE4(whole: 2))
    let earlier = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 1), actualTotalRubE4: AmountE4(whole: 1))
    let planning = PlanningRepository(writer: stack.writer)
    _ = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(reconciliations: [later, earlier]),
        settings: [PlanningSettings.savingsTargetKey: "2500"]))

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 3)

    #expect(dataset.planning == (try planning.book()))
    #expect(dataset.planning.scheduled == fixture.rows.scheduled)
    #expect(dataset.planning.prices == fixture.rows.prices)
    #expect(dataset.planning.expected == fixture.rows.expected)
    #expect(dataset.planning.expectedLinks == fixture.rows.expectedLinks)
    #expect(dataset.planning.budgets == fixture.rows.budgets)
    #expect(
      dataset.planning.reconciliations.map(\.id)
        == [earlier.id, fixture.reconciliation.id, later.id])
    #expect(Set(dataset.planning.debtEntries) == [fixture.line, closedLine])
    #expect(dataset.planning.settings.savingsTargetBp == 2_500)
    #expect(dataset.planning.settings.reconcileEveryDays == 30)
    #expect(dataset.planning.settings.dismissedReminders == ["reconcile", "sched:x:2026-09-01"])
  }

  /// The history read back from the database makes the very ledger the core makes from
  /// the generator: every row, in the same order, with the same rubles, contributions and
  /// resolved qualities — the parts come back in the order they were written.
  @Test func theLoadedHistoryMakesTheLedgerOfTheGenerator() async throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample(months: 12)
    try TransactionRepository(writer: stack.writer).insert(TestSupport.batch(set))
    try SettingsRepository(writer: stack.writer).set(
      AnalyticsSettings.cashbackCategoryKey, to: set.cashbackCategoryId.uuidString)

    let loaded = try await DatasetRepository(writer: stack.writer).load(version: 1)
    let fromDatabase = Ledger(dataset: loaded, calendar: TestSupport.sampleCalendar)
    let fromGenerator = Ledger(
      dataset: TestSupport.dataset(set.assigningAccounts()), calendar: TestSupport.sampleCalendar)

    #expect(fromDatabase.rows.count > set.entries.count)
    #expect(fromDatabase.rows == fromGenerator.rows)
    for part in set.links.map(\.partId) {
      #expect(fromDatabase.returned(forPart: part) == fromGenerator.returned(forPart: part))
    }
  }

  // MARK: Long histories

  /// Past the SQLite limit on bound parameters: no read of a long history sends one id per
  /// operation. The limit is set to SQLite's own default on the connection, since the
  /// system library may be built with a higher one and the Windows port will not be.
  @Test func everyReadWorksPastTheLimitOnBoundParameters() async throws {
    let stack = try TestSupport.makeStack()
    try await stack.writer.writeWithoutTransaction { db in
      _ = sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_VARIABLE_NUMBER, 32_766)
    }
    // The limit is real: a list of 33 000 values is refused.
    await #expect(throws: (any Error).self) {
      try await stack.writer.read { db in
        try Row.fetchAll(
          db, sql: "SELECT 1 WHERE 1 IN (\(databaseQuestionMarks(count: 33_000)))",
          arguments: StatementArguments(Array(repeating: 1, count: 33_000))
        ).count
      }
    }

    let count = 33_500
    let entries = try (0..<count).map { number in
      var draft = TransactionDraft(
        occurredAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(number) * 60),
        amount: AmountE4(whole: 100), note: "row \(number)")
      draft.parts = [
        PartDraft(
          quality: .good, qualitySource: .manual, amount: AmountE4(whole: 100),
          reimbursable: true)
      ]
      return try draft.materialize()
    }
    let transactions = TransactionRepository(writer: stack.writer)
    try transactions.insert(entries)

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    #expect(dataset.entries.count == count)
    #expect(dataset.entries.allSatisfy { $0.parts.count == 1 })
    #expect(try transactions.entries(from: .distantPast, to: .distantFuture).count == count)
    #expect(try transactions.recentEntries(limit: 40_000).count == count)
    #expect(try transactions.entries(ids: entries.map(\.id)).count == count)
    #expect(try transactions.owedParts().count == count)
    #expect(try transactions.entriesRatedByHand().count == count)
  }

  // MARK: Cancellation

  /// Cancelling the task stops the load where it is: it ends with `CancellationError`, the
  /// statements after the one under way never run, and the reader serves the next load
  /// right away. The cancel is sent from inside the read, the moment the parts start to
  /// come, so it lands in the middle of a load on any machine. How quickly it lands — within
  /// 100 ms on about 20 000 operations — is a question of the machine's speed, and
  /// `make bench` asks it (`PerformanceTests.aLoadIsCancelledWithinAHundredMilliseconds`).
  @Test(.timeLimit(.minutes(5)))
  func aCancelledLoadStopsWhereItIs() async throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    try TransactionRepository(writer: stack.writer).insert(
      TestSupport.batch(TestSupport.sample(months: 3)))
    let repository = DatasetRepository(writer: stack.writer)
    let loaded = try await repository.load(version: 0).entries.count
    let trigger = CancelTrigger()

    let writer = stack.writer
    // The task hands back only how it ended: a snapshot in a failure message would print
    // every operation.
    let task = Task { () -> (any Error)? in
      do {
        _ = try await writer.read { db in
          db.trace(options: .statement) { trigger.saw($0.expandedDescription) }
          defer { db.trace(options: [], nil) }
          return try DatasetRepository.dataset(db, version: 1)
        }
        return nil
      } catch {
        return error
      }
    }
    trigger.arm(task)
    let failure = await task.value

    #expect(failure is CancellationError, "the load ended with \(failure.map { type(of: $0) })")
    #expect(trigger.statements.count == 2, "the cancel did not land on the parts")
    #expect(
      !trigger.statements.contains { $0.contains("reimbursement_links") },
      "the load read on after it was cancelled")
    #expect(try await repository.load(version: 2).entries.count == loaded)
  }

  /// Cancels a task from inside its read, when the statement of the parts starts. The trace
  /// runs on the reader's queue; it waits there until the task is known, so the cancel never
  /// misses the statement it is meant for.
  private final class CancelTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private let known = DispatchSemaphore(value: 0)
    private var task: Task<(any Error)?, Never>?
    private var seen: [String] = []

    var statements: [String] { lock.withLock { seen } }

    func arm(_ task: Task<(any Error)?, Never>) {
      lock.withLock { self.task = task }
      known.signal()
    }

    func saw(_ sql: String) {
      lock.withLock { seen.append(sql) }
      guard sql.contains("transaction_parts") else { return }
      known.wait()
      lock.withLock { task }?.cancel()
    }
  }

  // MARK: A row the app cannot read

  /// An id that is not a UUID comes only from a writer other than the app — a hand edit,
  /// another program. Reading on past the row would leave its money out of every figure
  /// without a word, so the load fails; and it fails saying what it met, not that something
  /// was «not found», so the journal points at the damage.
  @Test func aRowWithAnUnreadableIdStopsTheLoadAndSaysSo() async throws {
    let stack = try TestSupport.makeStack()
    try TransactionRepository(writer: stack.writer).save(try TestSupport.makeEntry(note: "fine"))
    try await stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO transactions
            (id, kind, occurred_at, amount_e4, amount_rub_e4, created_at, updated_at)
          VALUES ('not-a-uuid', 'expense', '2026-09-24 12:00:00.000', 10000, 10000,
                  '2026-09-24 12:00:00.000', '2026-09-24 12:00:00.000')
          """)
    }

    await #expect(throws: UnreadableValue(column: "id")) {
      _ = try await DatasetRepository(writer: stack.writer).load(version: 0)
    }
  }

  // MARK: Writing a history

  /// All or nothing: one operation that does not add up stops the whole insert before
  /// anything is written.
  @Test func anOperationThatDoesNotAddUpWritesNothing() throws {
    let stack = try TestSupport.makeStack()
    let transactions = TransactionRepository(writer: stack.writer)
    var entries = try (0..<3).map { try TestSupport.makeEntry(note: "row \($0)") }
    entries[1].parts[0].amountE4 = AmountE4(raw: 1)

    #expect(throws: DatabaseError.unbalancedParts) { try transactions.insert(entries) }
    #expect(try transactions.count() == 0)
  }

  /// The database refuses a row half-way — a part filed under a category that is not
  /// there — and the rows before it are rolled back with it.
  @Test func aRowTheDatabaseRefusesRollsTheWholeInsertBack() throws {
    let stack = try TestSupport.makeStack()
    let transactions = TransactionRepository(writer: stack.writer)
    var entries = try (0..<1_000).map { try TestSupport.makeEntry(note: "row \($0)") }
    entries[999].parts[0].categoryId = UUID()

    #expect(throws: (any Error).self) { try transactions.insert(entries) }
    #expect(try transactions.count() == 0)

    // An id that is already there is refused the same way.
    try transactions.insert(Array(entries.prefix(10)))
    #expect(throws: (any Error).self) { try transactions.insert(Array(entries[5..<20])) }
    #expect(try transactions.count() == 10)
  }

  /// The Debug menu writes the same seed twice; the batch save writes over its own rows
  /// instead of refusing them.
  @Test func savingTheSameHistoryTwiceWritesOverItsOwnRows() throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample(months: 2)
    let transactions = TransactionRepository(writer: stack.writer)
    try transactions.save(TestSupport.batch(set))
    try transactions.save(TestSupport.batch(set))

    let counts = try ExportRepository(writer: stack.writer).rowCounts()
    #expect(counts["transactions"] == set.entries.count)
    #expect(counts["transaction_parts"] == set.entries.map(\.parts.count).reduce(0, +))
    #expect(counts["reimbursement_links"] == set.links.count)
    #expect(counts["debt_entries"] == set.debtEntries.count)
    #expect(counts["categories"] == set.categories.count)
  }

  private func byId(_ entries: [TransactionEntry]) -> [UUID: TransactionEntry] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
  }
}
