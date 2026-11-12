import AppCore
import CoreAnalytics
import CoreCSV
import CoreKit
import CorePlanning
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to the rate that changes, the points that burn, the digital ruble, the bank
/// subscription and the credit pause (`0027_savings_points_digital_pause`) only adds columns: a
/// database of the previous schema keeps every value, and the new columns start empty. They
/// travel through the records, the CSV, the archive's database and the exchange.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether or
/// not another migration lands after it.
@Suite("Schema 27 comes in without touching a value")
struct Migration0027Tests {
  static let name = "0027_savings_points_digital_pause"
  static let account = "55555555-5555-4555-8555-555555555555"
  static let points = "56565656-5656-4565-8565-565656565656"
  static let debt = "22222222-2222-4222-8222-222222222222"
  static let payment = "33333333-3333-4333-8333-333333333333"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0027-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  private static let seed = """
    INSERT INTO payment_methods
      (id, name, interest_rate, interest_period, interest_day)
    VALUES ('\(account)', 'Savings', '16', 'monthly', 31);
    INSERT INTO payment_methods (id, name) VALUES ('\(points)', 'Points');
    INSERT INTO debts (id, direction, type, name, monthly_payment_e4, payment_day)
      VALUES ('\(debt)', 'i_owe', 'loan', 'Loan', 50000000, 10);
    INSERT INTO scheduled_payments
      (id, name, kind, amount_e4, payment_method_id, freq, next_date)
      VALUES ('\(payment)', 'Bank pro', 'subscription', 3990000, '\(account)', 'monthly',
              '2026-12-01');
    INSERT INTO subscription_terms (payment_id) VALUES ('\(payment)');
    """

  private static let filled = """
    UPDATE payment_methods SET interest_base = 'min_balance', interest_next_rate = '12.5',
      interest_next_rate_on = '2026-12-01' WHERE id = '\(account)';
    UPDATE payment_methods SET points_burn_on = '2026-12-31', points_burn_e4 = 5000000,
      digital_ruble = 1, piggy = 1 WHERE id = '\(points)';
    UPDATE debts SET pause_from = '2027-01-01', pause_to = '2027-03-31',
      pause_kind = 'restructuring' WHERE id = '\(debt)';
    UPDATE subscription_terms SET bank_benefit_e4 = 1500000, bank_cashback_share = '40';
    """

  @Test func aNewDatabaseHasTheColumnsWithoutChecksAndTheKeyIsUnchanged() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    #expect(try stack.appliedMigrations().count >= 27)
    try stack.writer.read { (db: Database) throws in
      for (table, column, type) in [
        ("payment_methods", "interest_base", "TEXT"),
        ("payment_methods", "interest_next_rate", "TEXT"),
        ("payment_methods", "interest_next_rate_on", "TEXT"),
        ("payment_methods", "points_burn_on", "TEXT"),
        ("payment_methods", "points_burn_e4", "INTEGER"),
        ("payment_methods", "digital_ruble", "INTEGER"), ("payment_methods", "piggy", "INTEGER"),
        ("subscription_terms", "bank_benefit_e4", "INTEGER"),
        ("subscription_terms", "bank_cashback_share", "TEXT"),
        ("debts", "pause_from", "TEXT"), ("debts", "pause_to", "TEXT"),
        ("debts", "pause_kind", "TEXT"),
      ] {
        let found = try #require(try db.columns(in: table).first { $0.name == column })
        #expect(found.type.uppercased() == type, "\(table).\(column)")
        #expect(!found.isNotNull, "\(table).\(column) can stay empty")
        let sql =
          try String.fetchOne(
            db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]) ?? ""
        #expect(!sql.contains("\(column) TEXT CHECK"), "an added column carries no CHECK")
        #expect(!sql.contains("\(column) INTEGER CHECK"), "an added column carries no CHECK")
      }
      // The kind of an account keeps its CHECK: the digital ruble is a flag, not a kind.
      let kinds =
        try String.fetchOne(
          db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'payment_methods'")
        ?? ""
      #expect(kinds.contains("'card', 'cash', 'account', 'other'"))
    }
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndTheNewFieldsAreEmpty() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO payment_methods
              (id, name, interest_rate, interest_period, interest_day)
            VALUES ('\(Self.account)', 'Savings', '16', 'monthly', 31);
            INSERT INTO payment_methods (id, name) VALUES ('\(Self.points)', 'Points');
            INSERT INTO debts (id, direction, type, name, monthly_payment_e4, payment_day)
              VALUES ('\(Self.debt)', 'i_owe', 'loan', 'Loan', 50000000, 10);
            INSERT INTO scheduled_payments
              (id, name, kind, amount_e4, payment_method_id, freq, next_date)
              VALUES ('\(Self.payment)', 'Bank pro', 'subscription', 3990000,
                      '\(Self.account)', 'monthly', '2026-12-01');
            INSERT INTO subscription_terms (payment_id) VALUES ('\(Self.payment)');
            """)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == TestSupport.migrationNames.filter { $0 >= Self.name })
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      let savings = try #require(
        try PaymentMethod.fetchAll(db).first { $0.id.uuidString.lowercased() == Self.account })
      let terms = try #require(savings.interest)
      #expect(terms.rate == 16 && terms.base == .daily)
      #expect(terms.nextRate == nil && terms.nextRateOn == nil)
      #expect(savings.pointsBurn == nil && !savings.digitalRuble && !savings.piggy)
      #expect(try Debt.fetchAll(db).first?.pause == nil)
      let subscription = try #require(try SubscriptionTerms.fetchAll(db).first)
      #expect(subscription.bankBenefitE4 == nil && subscription.bankCashbackShare == nil)
    }
  }

  @Test func theNewFieldsRoundTripThroughTheRecords() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try stack.writer.read { (db: Database) throws in
      let accounts = try PaymentMethod.fetchAll(db)
      let savings = try #require(accounts.first { $0.id.uuidString.lowercased() == Self.account })
      let terms = try #require(savings.interest)
      #expect(terms.base == .minBalance)
      #expect(terms.nextRate == Decimal(string: "12.5"))
      #expect(terms.nextRateOn == DateOnly(year: 2026, month: 12, day: 1))
      let holder = try #require(accounts.first { $0.id.uuidString.lowercased() == Self.points })
      #expect(holder.pointsBurn?.on == DateOnly(year: 2026, month: 12, day: 31))
      #expect(holder.pointsBurn?.amountE4 == AmountE4(whole: 500))
      #expect(holder.digitalRuble && holder.piggy)
      let debt = try #require(try Debt.fetchAll(db).first)
      #expect(debt.pause?.kind == .restructuring)
      #expect(debt.pause?.from == DateOnly(year: 2027, month: 1, day: 1))
      #expect(debt.pause?.to == DateOnly(year: 2027, month: 3, day: 31))
      let subscription = try #require(try SubscriptionTerms.fetchAll(db).first)
      #expect(subscription.bankBenefitE4 == AmountE4(whole: 150))
      #expect(subscription.bankCashbackShare == 40)
    }
    // Saving the records back writes the same values.
    try stack.writer.write { db in
      for account in try PaymentMethod.fetchAll(db) { try account.save(db) }
      for debt in try Debt.fetchAll(db) { try debt.save(db) }
      for terms in try SubscriptionTerms.fetchAll(db) { try terms.save(db) }
    }
    let kept = try stack.writer.read { db in
      try Row.fetchOne(
        db,
        sql: """
          SELECT interest_base, interest_next_rate, interest_next_rate_on FROM payment_methods
          WHERE id = ?
          """, arguments: [Self.account])
    }
    #expect(kept?["interest_base"] as String? == "min_balance")
    #expect(kept?["interest_next_rate"] as String? == "12.5")
    #expect(kept?["interest_next_rate_on"] as String? == "2026-12-01")
  }

  @Test func damagedValuesReadAsNoneInsteadOfStoppingTheHistory() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          UPDATE payment_methods SET interest_base = 'weekly', interest_next_rate = 'abc',
            interest_next_rate_on = 'tomorrow', points_burn_on = 'soon', digital_ruble = 'yes'
            WHERE id = '\(Self.account)';
          UPDATE debts SET pause_from = '2027-03-01', pause_to = '2027-01-01', pause_kind = 'x';
          UPDATE subscription_terms SET bank_benefit_e4 = -5, bank_cashback_share = '300';
          """)
    }
    try stack.writer.read { (db: Database) throws in
      let savings = try #require(
        try PaymentMethod.fetchAll(db).first { $0.id.uuidString.lowercased() == Self.account })
      #expect(savings.interest?.base == .daily && savings.interest?.nextRate == nil)
      #expect(savings.pointsBurn == nil)
      #expect(try Debt.fetchAll(db).first?.pause == nil)
      let subscription = try #require(try SubscriptionTerms.fetchAll(db).first)
      #expect(subscription.bankBenefitE4 == nil && subscription.bankCashbackShare == nil)
    }
    let report = try DatabaseCheck.run(stack.writer)
    #expect(report.findings.contains { $0.rule == .pauseOutOfOrder && $0.count == 1 })
    #expect(report.findings.contains { $0.rule == .nextRateIncomplete } == false)
  }

  @Test func theCheckOfTheDatabaseFindsAHalfTypedRateAndAHalfTypedPause() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          UPDATE payment_methods SET interest_next_rate = '12' WHERE id = '\(Self.account)';
          UPDATE debts SET pause_from = '2027-01-01';
          """)
    }
    let report = try DatabaseCheck.run(stack.writer)
    #expect(report.findings.contains { $0.rule == .nextRateIncomplete && $0.count == 1 })
    #expect(report.findings.contains { $0.rule == .pauseOutOfOrder && $0.count == 1 })
    #expect(report.findings.allSatisfy { !$0.isRepairable || $0.rule != .pauseOutOfOrder })
    let healthy = try TestSupport.makeStack()
    try healthy.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    #expect(try DatabaseCheck.run(healthy.writer).isHealthy)
  }

  @Test func theNewColumnsGoLastInTheCSVAndTheNumberOfFilesIsUnchanged() throws {
    #expect(ExportTables.all.count == 55)
    #expect(Array(ExportTables.paymentMethods.columns.suffix(7)) == [
      "interest_base", "interest_next_rate", "interest_next_rate_on", "points_burn_on",
      "points_burn", "digital_ruble", "piggy",
    ])
    #expect(Array(ExportTables.debts.columns.suffix(3)) == [
      "pause_from", "pause_to", "pause_kind",
    ])
    #expect(Array(ExportTables.subscriptionTerms.columns.suffix(2)) == [
      "bank_benefit", "bank_cashback_share",
    ])
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    let tables = try ExportRepository(writer: stack.writer).tables()
    func rows(_ table: ExportTable) throws -> [[String: String]] {
      let file = try #require(tables.first { $0.fileName == table.fileName })
      let text = String(decoding: file.data, as: UTF8.self)
      #expect(text.hasPrefix(table.columns.joined(separator: ",")))
      return try CSVReader.dictionaries(from: file.data)
    }
    let accounts = try rows(ExportTables.paymentMethods)
    let savings = try #require(accounts.first { $0["id"]?.lowercased() == Self.account })
    #expect(savings["interest_base"] == "min_balance")
    #expect(savings["interest_next_rate"] == "12.5")
    #expect(savings["interest_next_rate_on"] == "2026-12-01")
    let holder = try #require(accounts.first { $0["id"]?.lowercased() == Self.points })
    #expect(holder["points_burn_on"] == "2026-12-31" && holder["points_burn"] == "500")
    #expect(holder["digital_ruble"] == "true" && holder["piggy"] == "true")
    let debt = try #require(try rows(ExportTables.debts).first)
    #expect(debt["pause_from"] == "2027-01-01" && debt["pause_to"] == "2027-03-31")
    #expect(debt["pause_kind"] == "restructuring")
    let subscription = try #require(try rows(ExportTables.subscriptionTerms).first)
    #expect(subscription["bank_benefit"] == "150" && subscription["bank_cashback_share"] == "40")
  }

  @Test func theNewColumnsTravelToTheOtherDeviceWithTheirRows() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(Self.seed)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try mac.sql(Self.filled)
    let queued = try mac.stack.writer.read { (db: Database) throws in
      try String.fetchAll(db, sql: "SELECT DISTINCT table_name FROM sync_outbox ORDER BY 1")
    }
    #expect(Set(queued) == ["debts", "payment_methods", "subscription_terms"])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try phone.stack.writer.read { (db: Database) throws in
      let accounts = try PaymentMethod.fetchAll(db)
      #expect(
        accounts.first { $0.id.uuidString.lowercased() == Self.account }?.interest?.nextRate
          == Decimal(string: "12.5"))
      #expect(
        accounts.first { $0.id.uuidString.lowercased() == Self.points }?.digitalRuble == true)
      #expect(try Debt.fetchAll(db).first?.pause?.kind == .restructuring)
      #expect(try SubscriptionTerms.fetchAll(db).first?.bankCashbackShare == 40)
    }
    #expect(try mac.books() == phone.books())
  }

  @Test func theAnonymizedCopyKeepsTheNumbersDaysAndFlagsAndRenamesTheAccounts() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { (db: Database) throws in
      let accounts = try PaymentMethod.fetchAll(db)
      #expect(accounts.allSatisfy { $0.name != "Savings" && $0.name != "Points" })
      let savings = try #require(
        accounts.first { $0.id.uuidString.lowercased() == Self.account })
      #expect(savings.interest?.base == .minBalance)
      #expect(savings.interest?.nextRate == Decimal(string: "12.5"))
      let holder = try #require(accounts.first { $0.id.uuidString.lowercased() == Self.points })
      #expect(holder.pointsBurn?.amountE4 == AmountE4(whole: 500) && holder.digitalRuble)
      #expect(try Debt.fetchAll(db).first?.pause?.to == DateOnly(year: 2027, month: 3, day: 31))
      #expect(try SubscriptionTerms.fetchAll(db).first?.bankBenefitE4 == AmountE4(whole: 150))
    }
  }
}
