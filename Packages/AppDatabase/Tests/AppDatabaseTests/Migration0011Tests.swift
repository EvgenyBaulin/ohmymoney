import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update to the travel columns (`0011_travel`) only adds: a database of 1.12 keeps every
/// value, an operation without a zone reads as recorded in Moscow, an event without a trip
/// currency reads as before and a card without foreign terms is «условия не заведены». The
/// records read and write every new column.
@Suite("The travel columns come in without touching a value")
struct Migration0011Tests {
  private static let older = FilteredSchemaSource(upTo: "0010_scenarios")

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0011-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  @Test func aNewDatabaseHasTheColumnsEmpty() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0016_rate_source")
    #expect(stack.applied.onDisk == 16)
    try stack.writer.read { db in
      let transactions = try db.columns(in: "transactions")
      let zone = try #require(transactions.first { $0.name == "time_zone" })
      #expect(zone.defaultValueSQL == nil, "no default: an old row is NULL, which reads as Moscow")
      let events = try db.columns(in: "events").map(\.name)
      #expect(events.contains("trip_currency") && events.contains("budget_currency"))
      let cards = try db.columns(in: "cards").map(\.name)
      for column in [
        "fx_fee_e4", "atm_fee_percent_e4", "atm_fee_fixed_e4", "atm_fee_fixed_currency",
      ] {
        #expect(cards.contains(column), "\(column)")
      }
    }
  }

  @Test func aDatabaseOf112KeepsEveryValueAndAddsNothingElse() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let account = UUID().uuidString
    let card = UUID().uuidString
    let trip = Event(
      name: "Бали", kind: .trip, startDate: DateOnly(year: 2026, month: 10, day: 1),
      endDate: DateOnly(year: 2026, month: 10, day: 20), budgetE4: AmountE4(whole: 90_000))
    let operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
      amountE4: AmountE4(whole: 500))
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: "INSERT INTO payment_methods (id, name) VALUES (?, 'Основной')",
          arguments: [account])
        try db.execute(
          sql: "INSERT INTO cards (id, payment_method_id, name) VALUES (?, ?, 'Чёрная')",
          arguments: [card, account])
        try LegacyWriter.insert(trip, db: db)
        try LegacyWriter.insert(operation, db: db)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == [
          "0011_travel", "0012_sync", "0013_spending_rules",
          "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0016_rate_source",
        ])

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 6)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE time_zone IS NOT NULL") == 0)
      #expect(
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM events WHERE trip_currency IS NOT NULL
              OR budget_currency IS NOT NULL
            """) == 0)
      #expect(
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM cards WHERE fx_fee_e4 IS NOT NULL
              OR atm_fee_percent_e4 IS NOT NULL OR atm_fee_fixed_e4 IS NOT NULL
            """) == 0)
      let read = try CoreKit.Transaction.fetchOne(db, key: operation.id.uuidString)
      #expect(read?.timeZoneId == nil)
      let readCard = try PaymentCard.fetchOne(db, key: card)
      #expect(readCard?.foreign.isEmpty == true)
    }
  }

  @Test func theRecordsReadAndWriteTheNewColumns() throws {
    let stack = try TestSupport.makeStack()
    let accountId = UUID()
    let card = PaymentCard(
      accountId: accountId, name: "Туристическая",
      foreign: CardForeignTerms(
        conversionFee: CashbackPercent(decimal: Decimal(string: "1.5")!),
        atmFeePercent: CashbackPercent(decimal: 2),
        atmFeeFixed: Money(amount: AmountE4(whole: 3), currency: .usd)))
    let trip = Event(
      name: "Турция", kind: .trip, startDate: DateOnly(year: 2026, month: 10, day: 5),
      endDate: DateOnly(year: 2026, month: 10, day: 15), budgetE4: AmountE4(whole: 45_000),
      tripCurrency: CurrencyCode("TRY"), budgetCurrency: .rub)
    var operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
      amountE4: AmountE4(whole: 100), timeZoneId: "Asia/Makassar")
    try stack.writer.write { db in
      try db.execute(
        sql: "INSERT INTO payment_methods (id, name) VALUES (?, 'A')",
        arguments: [accountId.uuidString])
      try card.insert(db)
      try trip.insert(db)
      try operation.insert(db)
    }
    try stack.writer.read { db in
      #expect(try PaymentCard.fetchOne(db, key: card.id.uuidString) == card)
      #expect(try Event.fetchOne(db, key: trip.id.uuidString) == trip)
      let read = try CoreKit.Transaction.fetchOne(db, key: operation.id.uuidString)
      #expect(read?.timeZoneId == "Asia/Makassar")
    }
    operation.timeZoneId = nil
    try stack.writer.write { try operation.update($0) }
    try stack.writer.read { db in
      let read = try CoreKit.Transaction.fetchOne(db, key: operation.id.uuidString)
      #expect(read?.timeZoneId == nil)
    }
  }

  @Test func theNewColumnsTravelInTheCSV() throws {
    let card = PaymentCard(
      accountId: UUID(), name: "A",
      foreign: CardForeignTerms(
        conversionFee: CashbackPercent(decimal: Decimal(string: "1.5")!),
        atmFeeFixed: Money(amount: AmountE4(whole: 3), currency: .usd)))
    let row = ExportTables.row(card)
    #expect(row.count == ExportTables.cards.columns.count)
    #expect(Array(row.suffix(7).prefix(4)) == ["1.5", "", "3", "USD"])
    let plain = ExportTables.row(PaymentCard(accountId: UUID(), name: "B"))
    #expect(Array(plain.suffix(7).prefix(4)) == ["", "", "", ""])
    let operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 1), timeZoneId: "Asia/Tokyo")
    #expect(ExportTables.row(operation).suffix(6).first == "Asia/Tokyo")
    #expect(ExportTables.row(operation).count == ExportTables.transactions.columns.count)
    let trip = Event(
      name: "T", kind: .trip, startDate: DateOnly(year: 2026, month: 1, day: 1),
      endDate: DateOnly(year: 2026, month: 1, day: 2), tripCurrency: .usd, budgetCurrency: .rub)
    #expect(Array(ExportTables.row(trip).suffix(2)) == ["USD", "RUB"])
    #expect(ExportTables.row(trip).count == ExportTables.events.columns.count)
  }
}
