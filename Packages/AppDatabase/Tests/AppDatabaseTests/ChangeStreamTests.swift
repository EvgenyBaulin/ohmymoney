import AppCore
import CoreKit
import Foundation
import Testing

@testable import AppDatabase

@Suite("Changes to the ledger tables are announced, and only announced")
struct ChangeStreamTests {
  private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
  }

  /// Counts the observation's callbacks. GRDB runs them on the writer's queue inside the
  /// commit, so the count sits behind a lock, readable right after the write returns.
  private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
  }

  /// The app writes synchronously from the main thread while the pipeline listens. Ten
  /// writes in a row from the main actor: none of them waits on the listener, at least one
  /// change arrives, and cancelling the listener ends the stream. That the observation ends
  /// with it is the next test.
  @Test(.timeLimit(.minutes(1))) @MainActor
  func tenWritesInARowFromTheMainThreadDoNotWaitForTheListener() async throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = TransactionRepository(writer: stack.writer)
    let changes = stack.ledgerChanges()
    let counter = Counter()
    let listener = Task {
      for await _ in changes { await counter.increment() }
    }

    for number in 0..<10 {
      try repository.save(try TestSupport.makeEntry(note: "row \(number)"))
    }

    // The listener's task may not have begun to observe when the ten writes were done — the
    // main actor wrote them before the task ran — and a change made before the observation
    // starts is not announced. So one more write each second, until one arrives.
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    var nextWrite = clock.now + .seconds(1)
    var more = 0
    while await counter.value == 0, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
      if clock.now >= nextWrite {
        try repository.save(try TestSupport.makeEntry(note: "more \(more)"))
        more += 1
        nextWrite = clock.now + .seconds(1)
      }
    }
    let received = await counter.value
    #expect(received >= 1)
    #expect(received <= 10 + more)

    listener.cancel()
    await listener.value
    // With the stream gone, writes go on as before.
    try repository.save(try TestSupport.makeEntry(note: "after"))
    #expect(try repository.count() == 11 + more)
  }

  /// Cancelling the listener stops the observation itself, not only the stream. A yield on a
  /// finished stream is silently dropped, so this watches the callback GRDB runs inside the
  /// commit, before the write returns. Once the listener is gone, a write still reaches a
  /// second, live observation — and no longer the first one, although its stream is still
  /// held here.
  @Test(.timeLimit(.minutes(1)))
  func cancellingTheListenerStopsTheObservation() async throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let first = Tally()
    let changes = stack.ledgerChanges(onChange: { first.increment() })
    let listener = Task { for await _ in changes {} }

    try repository.save(try TestSupport.makeEntry(note: "before"))
    let seen = first.value
    #expect(seen >= 1)

    listener.cancel()
    await listener.value

    let second = Tally()
    let live = stack.ledgerChanges(onChange: { second.increment() })
    try repository.save(try TestSupport.makeEntry(note: "after"))
    #expect(second.value >= 1)
    #expect(first.value == seen)
    withExtendedLifetime((changes, live)) {}
  }

  /// Writes that go around the store are announced too: a part written off from the
  /// reimbursement sheet, a rate saved by the rate step.
  @Test(.timeLimit(.minutes(1)))
  func writesAroundTheStoreAreAnnounced() async throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    draft.parts = [PartDraft(amount: AmountE4(whole: 1_000), reimbursable: true)]
    let dinner = try draft.materialize()
    try repository.save(dinner)
    var changes = stack.ledgerChanges().makeAsyncIterator()

    try repository.writeOffPart(id: dinner.parts[0].id)
    #expect(await changes.next() != nil)
    try RateRepository(writer: stack.writer).save([
      Rate(
        date: DateOnly(year: 2026, month: 9, day: 17), currency: .usd, rubPerUnit: 82)
    ])
    #expect(await changes.next() != nil)
  }

  /// The pipeline rebuilds the numbers when the stream says something changed, and the
  /// numbers are made of the `Dataset`. A table the dataset reads and the stream does not
  /// watch is a write the screens never see — whoever makes it. The tables read are taken
  /// from the statements the load really runs, so a table added to the dataset later is
  /// caught too.
  @Test func everyTableTheDatasetReadsIsWatched() throws {
    let stack = try TestSupport.makeStack()
    let tables = try stack.writer.read { db in
      try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'grdb_%'")
    }
    let statements = Statements()
    try stack.writer.read { db in
      db.trace(options: .statement) { statements.append($0.expandedDescription) }
      _ = try DatasetRepository.dataset(db, version: 0)
      db.trace(options: [], nil)
    }
    let read = tables.filter { table in
      statements.all.contains { sql in
        sql.range(of: #"(FROM|JOIN)\s+"?\#(table)"?(\s|$)"#, options: .regularExpression) != nil
      }
    }

    #expect(read.contains("transactions"), "the statements of the load were not seen")
    #expect(Set(read).subtracting(DatabaseStack.ledgerTables).sorted() == [])
  }

  /// The tables of the accounts are ledger tables: balances are made of the transfers and the
  /// counts, and the groups decide what the total shows. So are the cards and their cashback
  /// rules: what Analytics shows of the cashback expected is made of them. And the assets with
  /// their valuations: the capital is made of them.
  @Test func theTablesOfTheAccountsAreWatched() throws {
    for table in [
      "account_groups", "transfers", "reconciliation_balances", "cards", "cashback_rules",
      "banks", "assets", "asset_valuations", "debt_instalments", "debt_costs",
      "allocation_rules", "custom_currencies",
    ] {
      #expect(DatabaseStack.ledgerTables.contains(table), "\(table) is not watched")
    }
    #expect(DatabaseStack.ledgerTables.count == 33)
    #expect(Set(DatabaseStack.ledgerTables).count == DatabaseStack.ledgerTables.count)
  }

  /// A write to any of them is announced, whoever makes it.
  @Test func aWriteToTheTablesOfTheAccountsIsAnnounced() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card")
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    try ReferenceRepository(writer: stack.writer).save(card)
    try ReferenceRepository(writer: stack.writer).save(cash)
    let seen = Tally()
    let changes = stack.ledgerChanges(onChange: { seen.increment() })
    let at = Date(timeIntervalSince1970: 1_789_000_000)

    try stack.writer.write { db in
      try AccountGroup(name: "Russia").insert(db)
    }
    #expect(seen.value >= 1, "a group was not announced")
    try stack.writer.write { db in
      try Transfer(
        occurredAt: at, fromAccountId: card.id, fromCurrency: .rub,
        fromAmountE4: AmountE4(whole: 1), toAccountId: cash.id, toCurrency: .rub,
        toAmountE4: AmountE4(whole: 1)
      ).insert(db)
    }
    #expect(seen.value >= 2, "a transfer was not announced")
    let sheet = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 1), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .accounts)
    try stack.writer.write { db in try sheet.insert(db) }
    let before = seen.value
    try stack.writer.write { db in
      try ReconciledBalance(
        reconciliationId: sheet.id, accountId: card.id, currency: .rub, actualE4: .zero
      ).insert(db)
    }
    #expect(seen.value > before, "a count was not announced")
    withExtendedLifetime(changes) {}
  }

  /// «Это нормально» writes a row the anomalies are rebuilt from; the stream announces it
  /// like any other write the numbers depend on.
  @Test func aDismissedAnomalyIsAnnounced() throws {
    let stack = try TestSupport.makeStack()
    let seen = Tally()
    let changes = stack.ledgerChanges(onChange: { seen.increment() })

    try AnomalyRepository(writer: stack.writer).dismiss(rule: .categorySpike, subject: "week")
    #expect(seen.value >= 1, "the dismissal was not announced")
    try AnomalyRepository(writer: stack.writer).restore(rule: .categorySpike, subject: "week")
    #expect(seen.value >= 2, "the restore was not announced")
    withExtendedLifetime(changes) {}
  }

  /// The copy after every change listens wider than the numbers do: a pinned template or a
  /// switched-on currency changes nothing the ledger reads, yet it is the owner's data and
  /// has to reach the next copy.
  @Test func theCopiesWatchTheTemplatesAndTheCurrenciesBesideTheLedger() {
    #expect(Set(DatabaseStack.dataTables).isSuperset(of: DatabaseStack.ledgerTables))
    #expect(DatabaseStack.dataTables.contains("templates"))
    #expect(DatabaseStack.dataTables.contains("currencies"))
    #expect(!DatabaseStack.ledgerTables.contains("templates"))
    #expect(!DatabaseStack.ledgerTables.contains("currencies"))
  }

  /// A write that only touches the currencies — Settings → Currencies — arrives on the stream
  /// the copies listen to.
  @Test(.timeLimit(.minutes(1)))
  func aWriteToTheCurrenciesAloneIsAnnouncedForTheCopies() async throws {
    let stack = try TestSupport.makeStack()
    var changes = stack.dataChanges().makeAsyncIterator()

    try await stack.writer.write { db in
      try db.execute(
        sql: "INSERT OR REPLACE INTO currencies (code, enabled, sort) VALUES ('EUR', 1, 99)")
    }

    let arrived: Void? = await changes.next()
    #expect(arrived != nil, "a write to the currencies alone was not announced to the copies")
  }

  /// The SQL the trace saw, behind a lock: GRDB calls the trace on the reader's queue.
  private final class Statements: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var all: [String] { lock.withLock { list } }
    func append(_ sql: String) { lock.withLock { list.append(sql) } }
  }
}

@Suite("The last reconciliation")
struct ReconciliationTests {
  /// Until a reconciliation is made there is no latest one; after that, it is the latest by
  /// day.
  @Test func theLatestDateIsNilUntilThereIsOne() throws {
    let stack = try TestSupport.makeStack()
    let repository = ReconciliationRepository(writer: stack.writer)
    #expect(try repository.latestDate() == nil)

    try stack.writer.write { db in
      for (id, day) in [("a", "2026-09-15"), ("b", "2026-08-31")] {
        try db.execute(
          sql: """
            INSERT INTO reconciliations (id, date, actual_total_rub_e4) VALUES (?, ?, 0)
            """,
          arguments: [id, day])
      }
    }
    #expect(try repository.latestDate() == DateOnly(year: 2026, month: 9, day: 15))
  }
}
