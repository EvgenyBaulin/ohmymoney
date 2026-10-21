import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// 2026-09-21 14:13:20.9995 UTC: half a millisecond before the next one begins, where a writer
/// that rounds to the millisecond stores 14:13:21.000 — later than it happened.
private let event = Date(timeIntervalSince1970: 1_790_000_000.9995)
/// What the database keeps of `event`: the millisecond it is in.
private let eventText = "2026-09-21 14:13:20.999"
/// 2026-09-21 14:13:20 UTC in seconds since the reference date, where the database counts its
/// milliseconds: a fraction added to it is the moment meant, to a tenth of a microsecond.
private let second: TimeInterval = 811_692_800
/// The instant `eventText` reads as.
private let eventMillisecond = Date(timeIntervalSinceReferenceDate: second + 0.999)

/// An instant goes into the database to the millisecond, and never reads back later than it
/// happened: it is kept as the last millisecond not after it, not rounded. A balance worked out
/// «now», right after an operation, a transfer or a count was written at the same «now»,
/// includes it — a rounded moment could lie up to half a millisecond ahead, and the balance
/// missed what had just been entered. Every instant the app writes goes by the same rule; a
/// value already stored reads and writes back unchanged.
@Suite("A stored instant is never later than it happened")
struct StoredInstantTests {
  private func text(_ stack: DatabaseStack, _ sql: String) throws -> String? {
    try stack.writer.read { db in try String.fetchOne(db, sql: sql) }
  }

  // MARK: Every moment column

  @Test func anOperationKeepsItsMomentsCutToTheMillisecond() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    var entry = try TestSupport.makeEntry(occurredAt: event)
    entry.transaction.paymentMethodId = fixture.paymentMethod.id
    entry.transaction.createdAt = event
    entry.transaction.updatedAt = event
    let repository = TransactionRepository(writer: stack.writer)
    try repository.save(entry)

    let id = entry.id.uuidString
    for column in ["occurred_at", "created_at", "updated_at"] {
      #expect(
        try text(stack, "SELECT \(column) FROM transactions WHERE id = '\(id)'") == eventText,
        "\(column)")
    }
    let read = try #require(try repository.entry(id: entry.id))
    #expect(read.transaction.occurredAt <= event)
    #expect(read.transaction.occurredAt == eventMillisecond)
    #expect(read.transaction.createdAt <= event)
    #expect(read.transaction.updatedAt <= event)
    #expect(try repository.entries(from: event, to: event).map(\.id) == [entry.id])

    _ = try repository.softDelete(id: entry.id, at: event)
    #expect(try text(stack, "SELECT deleted_at FROM transactions WHERE id = '\(id)'") == eventText)
    #expect(try text(stack, "SELECT updated_at FROM transactions WHERE id = '\(id)'") == eventText)
  }

  @Test func aTransferACountAndAJournalLineKeepTheirMomentsCutToTheMillisecond() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    try ReferenceRepository(writer: stack.writer).save(cash)
    let transfer = Transfer(
      occurredAt: event, fromAccountId: cash.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 5), toAccountId: fixture.paymentMethod.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 5), createdAt: event, updatedAt: event)
    let count = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 21), reconciledAt: event,
      actualTotalRubE4: .zero, kind: .accounts)
    let line = DebtEntry(
      debtId: fixture.debt.id, amountE4: AmountE4(whole: 1), kind: .borrowed,
      paymentMethodId: cash.id, occurredAt: event)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          debtEntries: [line], reconciliations: [count], transfers: [transfer])))

    for column in ["occurred_at", "created_at", "updated_at"] {
      #expect(try text(stack, "SELECT \(column) FROM transfers") == eventText, "\(column)")
    }
    #expect(try text(stack, "SELECT reconciled_at FROM reconciliations") == eventText)
    #expect(
      try text(stack, "SELECT occurred_at FROM debt_entries WHERE id = '\(line.id.uuidString)'")
        == eventText)

    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
    let read = try #require(dataset.transfers.first)
    #expect(read.occurredAt <= event)
    #expect(read.occurredAt == eventMillisecond)
    let readCount = try #require(dataset.planning.reconciliations.first)
    #expect(try #require(readCount.reconciledAt) <= event)
  }

  /// Notes of time — when a rate was fetched, an anomaly waved away, a category chosen, a model
  /// trained — go by the same rule as the moments of money.
  @Test func notesOfTimeAreCutTheSameWay() throws {
    let stack = try TestSupport.makeStack()
    try RateRepository(writer: stack.writer).save([
      Rate(
        date: DateOnly(year: 2026, month: 9, day: 21), currency: .usd,
        rubPerUnit: Decimal(string: "81.5")!, fetchedAt: event)
    ])
    try AnomalyRepository(writer: stack.writer).dismiss(
      rule: .largeExpense, subject: "subject", at: event)
    let models = ModelRepository(writer: stack.writer)
    try models.record(
      CategoryFeedback(
        text: "coffee", predictedCategoryId: nil, chosenCategoryId: nil, partId: nil,
        confidenceBp: nil, at: event))
    try models.save(
      ModelRepository.Row(
        kind: "category", version: 1, trainedAt: event, file: "model.json", checksum: "0"))

    #expect(try text(stack, "SELECT fetched_at FROM rates") == eventText)
    #expect(try text(stack, "SELECT at FROM anomaly_dismissals") == eventText)
    #expect(try text(stack, "SELECT at FROM category_feedback") == eventText)
    #expect(try text(stack, "SELECT trained_at FROM ml_models") == eventText)
    #expect(try #require(try models.feedback().first).at <= event)
  }

  /// A deletion stamps `updated_at` and `deleted_at` by the same rule; its ⌘Z gives back the
  /// moment the operation had before, as it was stored.
  @Test func aDeletionStampsItsMomentCutToTheMillisecondAndItsUndoGivesTheOldOneBack() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    var entry = try TestSupport.makeEntry()
    entry.transaction.paymentMethodId = fixture.paymentMethod.id
    let repository = TransactionRepository(writer: stack.writer)
    try repository.save(entry)
    let id = entry.id.uuidString
    let saved = try text(stack, "SELECT updated_at FROM transactions WHERE id = '\(id)'")
    let effects = try repository.softDelete(id: entry.id, at: event)
    #expect(try text(stack, "SELECT updated_at FROM transactions WHERE id = '\(id)'") == eventText)
    #expect(try text(stack, "SELECT deleted_at FROM transactions WHERE id = '\(id)'") == eventText)
    try repository.restore(id: entry.id, at: event.addingTimeInterval(60), effects: effects)
    #expect(saved != nil)
    #expect(try text(stack, "SELECT updated_at FROM transactions WHERE id = '\(id)'") == saved)
    #expect(try text(stack, "SELECT deleted_at FROM transactions WHERE id = '\(id)'") == nil)
  }

  // MARK: The rule itself

  /// The millisecond a moment is written as, for fractions on both sides of a boundary, down
  /// to a tenth of a microsecond and to the last `Date` before one: never one that reads back
  /// later than the moment, never one more than a millisecond earlier, and a whole millisecond
  /// stays where it is.
  @Test(arguments: [
    (0.0, "2026-09-21 14:13:20.000"),
    (0.0000001, "2026-09-21 14:13:20.000"),
    (0.0004, "2026-09-21 14:13:20.000"),
    (0.0005, "2026-09-21 14:13:20.000"),
    (0.000999, "2026-09-21 14:13:20.000"),
    (0.0009999, "2026-09-21 14:13:20.000"),
    (0.001, "2026-09-21 14:13:20.001"),
    (0.001999855, "2026-09-21 14:13:20.001"),
    (0.123, "2026-09-21 14:13:20.123"),
    (0.1236, "2026-09-21 14:13:20.123"),
    (0.5, "2026-09-21 14:13:20.500"),
    (0.999, "2026-09-21 14:13:20.999"),
    (0.9995, "2026-09-21 14:13:20.999"),
    (0.99999, "2026-09-21 14:13:20.999"),
    (0.9999999, "2026-09-21 14:13:20.999"),
  ])
  func theMillisecondIsCutNotRounded(fraction: Double, expected: String) throws {
    let date = Date(timeIntervalSinceReferenceDate: second + fraction)
    #expect(String.fromDatabaseValue(StoredInstant.databaseValue(date)) == expected)
    let read = try #require(StoredInstant.date(from: StoredInstant.databaseValue(date)))
    #expect(read <= date, "read back no later than it happened")
    #expect(date.timeIntervalSince(read) < 0.001, "and less than a millisecond earlier")
  }

  /// The last `Date` before a second begins is still in the second before, to its last
  /// millisecond — a writer that takes the moment to the microsecond first moves it on.
  @Test func theLastMomentBeforeASecondStaysInIt() throws {
    let date = Date(timeIntervalSinceReferenceDate: (second + 1).nextDown)
    #expect(
      String.fromDatabaseValue(StoredInstant.databaseValue(date)) == "2026-09-21 14:13:20.999")
    let read = try #require(StoredInstant.date(from: StoredInstant.databaseValue(date)))
    #expect(read <= date)
  }

  /// Seconds since 1970 plus a number of milliseconds make a `Date` a hair off the instant the
  /// database reads that millisecond as — below it for about a quarter of them. Such a moment
  /// is written as the millisecond before: the one that reads back no later than it. The same
  /// millisecond counted from the reference date keeps it.
  @Test func aMomentAHairBelowAWholeMillisecondIsKeptAsTheOneBefore() throws {
    let below = Date(timeIntervalSince1970: 1_790_000_000.123)
    let whole = Date(timeIntervalSinceReferenceDate: second + 0.123)
    #expect(below < whole, "seconds since 1970 land a hair below the millisecond")
    #expect(
      String.fromDatabaseValue(StoredInstant.databaseValue(below)) == "2026-09-21 14:13:20.122")
    #expect(
      String.fromDatabaseValue(StoredInstant.databaseValue(whole)) == "2026-09-21 14:13:20.123")

    var kept = 0
    for millisecond in 0..<1000 {
      let date = Date(timeIntervalSince1970: 1_790_000_000 + Double(millisecond) / 1000)
      let text = try #require(String.fromDatabaseValue(StoredInstant.databaseValue(date)))
      let read = try #require(StoredInstant.date(from: StoredInstant.databaseValue(date)))
      #expect(read <= date, "\(millisecond)")
      #expect(date.timeIntervalSince(read) < 0.001, "\(millisecond)")
      let meant = Date(timeIntervalSinceReferenceDate: second + Double(millisecond) / 1000)
      if date >= meant {
        #expect(text.hasSuffix(String(format: ".%03d", millisecond)), "\(millisecond)")
        kept += 1
      } else {
        #expect(text.hasSuffix(String(format: ".%03d", millisecond - 1)), "\(millisecond)")
      }
    }
    #expect(kept == 752, "three in four keep their millisecond")
  }

  /// The moments the app makes of a day — its start, its noon, its last millisecond
  /// (`CalendarContext.endOfDay`), a second after them — keep the millisecond they name, every
  /// day of the century, in a zone without and in one with a change of clocks.
  @Test func theMomentsOfADayKeepTheirMillisecond() throws {
    for zone in ["Europe/Moscow", "America/New_York"] {
      let calendar = CalendarContext(timeZone: TimeZone(identifier: zone)!)
      var day = DateOnly(year: 2001, month: 1, day: 1)
      while day.year < 2101 {
        let start = calendar.startOfDay(day)
        for moment in [
          start, calendar.noon(of: day), calendar.endOfDay(day), start.addingTimeInterval(1),
        ] {
          let millisecond = try #require(StoredInstant.millisecond(of: moment))
          #expect(StoredInstant.instant(ofMillisecond: millisecond) == moment, "\(zone) \(day)")
        }
        let last = try #require(StoredInstant.millisecond(of: calendar.endOfDay(day)))
        let next = try #require(
          StoredInstant.millisecond(of: calendar.startOfDay(day.adding(days: 1))))
        #expect(next - last == 1, "\(zone) \(day): the day ends a millisecond before the next")
        day = day.adding(days: 1)
      }
    }
  }

  /// Any moment of the clock reads back no later than it happened, and less than a millisecond
  /// earlier: random moments of 2026 to the tenth of a microsecond, and every `Date` of two
  /// milliseconds around a boundary.
  @Test func anyMomentReadsBackNoLaterThanItHappened() throws {
    var generator = SplitMix(seed: 1_790_000_000)
    for _ in 0..<200_000 {
      // A moment of 2026 to the tenth of a microsecond, as the clock gives one.
      let tenths = Double(generator.next() % 315_360_000_000_000)
      let date = Date(timeIntervalSinceReferenceDate: 788_918_400 + tenths / 10_000_000)
      let millisecond = try #require(StoredInstant.millisecond(of: date))
      let read = StoredInstant.instant(ofMillisecond: millisecond)
      #expect(read <= date)
      #expect(date.timeIntervalSince(read) < 0.001)
    }
    var interval = second + 0.001
    while interval < second + 0.003 {
      let date = Date(timeIntervalSinceReferenceDate: interval)
      let read = try #require(StoredInstant.date(from: StoredInstant.databaseValue(date)))
      #expect(read <= date)
      #expect(date.timeIntervalSince(read) < 0.001)
      interval = interval.nextUp
    }
  }

  /// Moments before 1970, at the far ends GRDB can write and at the last millisecond of a day
  /// (`CalendarContext.endOfDay`) keep the millisecond they name.
  @Test func farAndBoundaryMomentsKeepTheirMillisecond() throws {
    #expect(
      String.fromDatabaseValue(StoredInstant.databaseValue(Date(timeIntervalSince1970: -0.0005)))
        == "1969-12-31 23:59:59.999")
    #expect(
      StoredInstant.databaseValue(.distantPast) == Date.distantPast.databaseValue,
      "a whole moment is written exactly as GRDB wrote it")
    #expect(StoredInstant.databaseValue(.distantFuture) == Date.distantFuture.databaseValue)
    let calendar = CalendarContext(timeZone: TimeZone(identifier: "Europe/Moscow")!)
    let endOfDay = calendar.endOfDay(DateOnly(year: 2026, month: 9, day: 21))
    #expect(
      String.fromDatabaseValue(StoredInstant.databaseValue(endOfDay)) == "2026-09-21 20:59:59.999")
  }

  /// A value already stored — by 1.0.0, by 1.1.0, rounded as it was then — reads as the
  /// millisecond it names and is written back to the very same text, for any millisecond:
  /// nothing stored is ever rewritten by reading and saving it again.
  @Test func aStoredValueReadsAndWritesBackUnchanged() throws {
    var generator = SplitMix(seed: 20_260_926)
    for _ in 0..<20_000 {
      // Any millisecond from 2001 to the end of 2100.
      let millisecond = Int64(generator.next() % 3_155_760_000_000)
      let whole = Date(timeIntervalSinceReferenceDate: Double(millisecond) / 1000)
      let stored = whole.databaseValue  // as GRDB wrote it before
      let read = try #require(StoredInstant.date(from: stored))
      #expect(StoredInstant.databaseValue(read) == stored)
      #expect(StoredInstant.databaseValue(whole) == stored)
      #expect(abs(read.timeIntervalSince(whole)) < 0.000_001)
    }
  }

  /// A row a 1.1.0 build saved at a moment it rounded up keeps its text when the operation is
  /// saved again: the edit rewrites the row with the moments it read.
  @Test func anOperationSavedAgainKeepsTheTextOfItsMoments() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let id = UUID()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO transactions (id, kind, occurred_at, created_at, updated_at, currency,
            amount_e4, amount_rub_e4, payment_method_id)
          VALUES (?, 'expense', '2026-09-21 14:13:21.000', '2026-09-21 14:13:20.001',
            '2026-09-21 23:59:59.999', 'RUB', 10000, 10000, ?)
          """,
        arguments: [id.uuidString, fixture.paymentMethod.id.uuidString])
      try db.execute(
        sql: """
          INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4,
            amount_rub_e4)
          VALUES (?, ?, ?, 10000, 10000)
          """,
        arguments: [UUID().uuidString, id.uuidString, fixture.category.id.uuidString])
    }
    let repository = TransactionRepository(writer: stack.writer)
    var entry = try #require(try repository.entry(id: id))
    entry.transaction.note = "edited"
    try repository.save(entry)
    let row = try #require(
      try stack.writer.read { db in
        try GRDB.Row.fetchOne(
          db, sql: "SELECT occurred_at, created_at, updated_at FROM transactions WHERE id = ?",
          arguments: [id.uuidString])
      })
    #expect(row["occurred_at"] as String? == "2026-09-21 14:13:21.000")
    #expect(row["created_at"] as String? == "2026-09-21 14:13:20.001")
    #expect(row["updated_at"] as String? == "2026-09-21 23:59:59.999")
  }

  /// Every form GRDB reads keeps reading: to the second, to a tenth, with a `T`, with an
  /// offset, a number of seconds; and a number keeps its fraction, since it names no
  /// millisecond.
  @Test func everyReadableFormStillReads() throws {
    func text(_ fraction: Double) -> Date {
      Date(timeIntervalSinceReferenceDate: second + fraction)
    }
    let forms: [(DatabaseValue, Date)] = [
      ("2026-09-21 14:13:20".databaseValue, text(0)),
      ("2026-09-21 14:13:20.5".databaseValue, text(0.5)),
      ("2026-09-21T14:13:20.250".databaseValue, text(0.25)),
      ("2026-09-21 17:13:20.000+03:00".databaseValue, text(0)),
      ("2026-09-21 14:13:20.123456".databaseValue, text(0.123)),
      ("2026-09-21 14:13:20.999999".databaseValue, text(0.999)),
      (1_790_000_000.25.databaseValue, Date(timeIntervalSince1970: 1_790_000_000.25)),
      (1_790_000_000.9995.databaseValue, event),
    ]
    for (value, expected) in forms {
      #expect(try #require(StoredInstant.date(from: value)) == expected, "\(value)")
    }
    #expect(StoredInstant.date(from: "soon".databaseValue) == nil)
    #expect(StoredInstant.date(from: .null) == nil)
  }
}

/// A fixed sequence of numbers, the same on every run and every machine.
private struct SplitMix {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
