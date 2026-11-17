import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("Deleting planning rows preserves every dependent for undo and redo")
struct PlanningDeletionSafetyTests {
  @Test(arguments: [
    "asset", "debt", "subscription", "budget", "category", "event", "account", "card", "bank",
  ])
  func deletionUndoAndRedoAreExact(owner: String) throws {
    let (stack, change) = try fixture(owner: owner)
    let repository = PlanningRepository(writer: stack.writer)
    let before = try stack.writer.read { try TestSupport.contents($0) }
    let undo = try repository.apply(change)
    let deleted = try stack.writer.read { try TestSupport.contents($0) }
    #expect(deleted != before)
    try repository.revert(undo)
    #expect(try stack.writer.read { try TestSupport.contents($0) } == before)
    let redo = try repository.apply(try #require(undo.change))
    #expect(try stack.writer.read { try TestSupport.contents($0) } == deleted)
    try repository.revert(redo)
    #expect(try stack.writer.read { try TestSupport.contents($0) } == before)
  }

  @Test func restoredAttachmentsAndSubscriptionExtrasAreJournaled() throws {
    let (stack, change) = try fixture(owner: "subscription")
    let exchange = try SyncExchange(writer: stack.writer, deviceId: "synthetic", deviceName: "Test")
    try exchange.setRecording(true)
    let repository = PlanningRepository(writer: stack.writer)
    let undo = try repository.apply(change)
    try stack.writer.write { try $0.execute(sql: "DELETE FROM sync_outbox") }
    try repository.revert(undo)
    try stack.writer.read { db in
      let tables = Set(try String.fetchAll(db, sql: "SELECT table_name FROM sync_outbox"))
      #expect(
        tables.isSuperset(of: [
          "scheduled_payments", "attachments", "subscription_terms", "subscription_usage",
          "subscription_users",
        ]))
    }
  }

  @Test func aFailedCompositeDeletionRollsBackItsCascadesAndJournal() throws {
    let (stack, deletion) = try fixture(owner: "subscription")
    let exchange = try SyncExchange(writer: stack.writer, deviceId: "synthetic", deviceName: "Test")
    try exchange.setRecording(true)
    let bank = Bank(name: "Used bank")
    let account = PaymentMethod(name: "Used account", kind: .cash, bankId: bank.id)
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          paymentMethods: [account], banks: [bank])))
    let before = try stack.writer.read { try TestSupport.contents($0) }
    var change = deletion
    change.delete.banks = [bank.id]
    #expect(throws: PlanningWriteError.referencedByOperations(bank.id)) {
      try repository.apply(change)
    }
    #expect(try stack.writer.read { try TestSupport.contents($0) } == before)
  }

  @Test func anAssetAndItsExpectedIncomeCanBeCreatedTogether() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let asset = Asset(name: "Synthetic holding", kind: .investment)
    let income = ExpectedIncome(name: "Dividend", totalE4: AmountE4(whole: 1), assetId: asset.id)
    let before = try stack.writer.read { try TestSupport.contents($0) }
    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          expected: [income], assets: [asset])))
    try repository.revert(undo)
    #expect(try stack.writer.read { try TestSupport.contents($0) } == before)
  }

  @Test func subscriptionDependentsKeepTheirOrderWhenOwnersAreDeletedInReverse() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let payments = (0..<3).map {
      ScheduledPayment(name: "Synthetic subscription \($0)", kind: .subscription, amountE4: .zero)
    }
    _ = try repository.apply(PlanningChange(upsert: PlanningRows(scheduled: payments)))
    try stack.writer.write { db in
      for payment in payments {
        try db.execute(
          sql: """
            INSERT INTO subscription_usage (id, payment_id, day) VALUES (?, ?, '2026-11-01')
            """, arguments: [UUID().uuidString, payment.id.uuidString])
      }
    }
    let before = try stack.writer.read { try TestSupport.contents($0) }
    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(
          scheduled: [payments[1].id, payments[0].id])))
    try repository.revert(undo)
    #expect(try stack.writer.read { try TestSupport.contents($0) } == before)
  }

  @Test func unreadableDependentsWithNullPrimaryKeysSurviveUndo() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let payment = ScheduledPayment(name: "Synthetic subscription", amountE4: .zero)
    _ = try repository.apply(PlanningChange(upsert: PlanningRows(scheduled: [payment])))
    try stack.writer.write { db in
      for _ in 0..<2 {
        try db.execute(
          sql: """
            INSERT INTO subscription_usage (id, payment_id, day) VALUES (NULL, ?, 'unreadable')
            """, arguments: [payment.id.uuidString])
      }
    }
    let before = try stack.writer.read { try TestSupport.contents($0) }
    let undo = try repository.apply(PlanningChange(delete: PlanningRowIDs(scheduled: [payment.id])))
    try repository.revert(undo)
    #expect(try stack.writer.read { try TestSupport.contents($0) } == before)
  }

  private func fixture(owner: String) throws -> (DatabaseStack, PlanningChange) {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let id = UUID()
    let key = id.uuidString
    let retainedId = UUID()
    var rows = PlanningRows()
    var gone = PlanningRowIDs()
    switch owner {
    case "asset":
      rows.assets = [
        Asset(id: id, name: "Synthetic asset", kind: .other),
        Asset(id: retainedId, name: "Retained asset", kind: .other),
      ]
      gone.assets = [id]
    case "debt":
      rows.debts = [
        Debt(id: id, direction: .iOwe, type: .loan, name: "Synthetic debt"),
        Debt(id: retainedId, direction: .iOwe, type: .loan, name: "Retained debt"),
      ]
      gone.debts = [id]
    case "subscription":
      rows.scheduled = [
        ScheduledPayment(
          id: id, name: "Synthetic subscription", kind: .subscription, amountE4: .zero),
        ScheduledPayment(
          id: retainedId, name: "Retained subscription", kind: .subscription, amountE4: .zero),
      ]
      gone.scheduled = [id]
    case "budget", "category":
      let category = CoreKit.Category(kind: .expense, name: "Synthetic category")
      rows.categories = [category]
      rows.budgets = [
        Budget(
          id: id, scope: .category, categoryId: category.id, amountE4: AmountE4(whole: 1))
      ]
      if owner == "budget" { gone.budgets = [id] } else { gone.categories = [category.id] }
    case "event":
      let day = DateOnly(year: 2026, month: 11, day: 1)
      rows.events = [Event(id: id, name: "Synthetic event", startDate: day, endDate: day)]
      gone.events = [id]
    case "account", "card":
      let account = PaymentMethod(name: "Synthetic account", kind: .cash)
      rows.paymentMethods = [account]
      rows.cards = [PaymentCard(id: id, accountId: account.id, name: "Synthetic card")]
      if owner == "account" { gone.paymentMethods = [account.id] } else { gone.cards = [id] }
    case "bank":
      rows.banks = [Bank(id: id, name: "Synthetic bank")]
      gone.banks = [id]
    default: Issue.record("Unknown synthetic owner")
    }
    _ = try repository.apply(PlanningChange(upsert: rows))
    try stack.writer.write { db in
      if owner == "asset" {
        try ExpectedIncome(name: "Rent", totalE4: AmountE4(whole: 1), assetId: id).insert(db)
      }
      switch owner {
      case "asset", "debt", "subscription":
        // Keep an unrelated later row so restoring the original rowid matters.
        for index in 0..<2 {
          try db.execute(
            sql: """
              INSERT INTO attachments
                (id, owner_kind, owner_id, content_hash, file_name, byte_size, added_at)
              VALUES (?, ?, ?, ?, 'synthetic.txt', 1, '2026-11-01T10:00:00Z')
              """,
            arguments: [
              UUID().uuidString, owner, index == 0 ? key : retainedId.uuidString,
              String(repeating: "a", count: 64),
            ])
        }
        if owner == "subscription" {
          let person = Person(name: "Synthetic person", relation: .friend)
          try person.insert(db)
          try db.execute(
            sql: """
              INSERT INTO subscription_terms (payment_id, service_type, yearly_plan_e4)
              VALUES (?, 'future-service', NULL);
              INSERT INTO subscription_usage (id, payment_id, day) VALUES (?, ?, '2026-11-01');
              INSERT INTO subscription_users (id, payment_id, person_id) VALUES (?, ?, ?);
              """,
            arguments: [key, UUID().uuidString, key, UUID().uuidString, key, person.id.uuidString])
        }
      case "budget", "category":
        try db.execute(
          sql: """
            INSERT INTO budget_month_exceptions (id, budget_id, month, amount_e4)
            VALUES (?, ?, '2026-11', 12345)
            """, arguments: [UUID().uuidString, key])
      case "event":
        try db.execute(
          sql: """
            INSERT INTO event_budget_items (id, event_id, title, planned_e4) VALUES (?, ?, 'Hotel', 1);
            INSERT INTO import_mappings (id, source_kind, source_category, target_event_id)
            VALUES (?, 'expense', 'Synthetic', ?);
            """, arguments: [UUID().uuidString, key, UUID().uuidString, key])
      case "account", "card":
        let account = try #require(rows.paymentMethods.first).id.uuidString
        try db.execute(
          sql: """
            INSERT INTO bank_conditions (id, payment_method_id, card_id, free_cash_e4)
            VALUES (?, ?, ?, 12345);
            INSERT INTO cashback_offers (id, payment_method_id, card_id, month, label, percent_e4)
            VALUES (?, ?, ?, '2026-11', 'Synthetic offer', 10000);
            """, arguments: [UUID().uuidString, account, key, UUID().uuidString, account, key])
        if owner == "account" {
          try db.execute(
            sql: """
              INSERT INTO credit_statements
                (id, payment_method_id, statement_on, minimum_e4, pay_by)
              VALUES (?, ?, '2026-11-01', 12345, '2026-11-20');
              INSERT INTO import_batches
                (id, source_file_name, imported_at, rows_total, rows_imported, rows_skipped,
                 payment_method_id)
              VALUES (?, 'synthetic.csv', '2026-11-01T10:00:00Z', 0, 0, 0, ?);
              """, arguments: [UUID().uuidString, account, UUID().uuidString, account])
        }
      case "bank":
        try db.execute(
          sql: """
            INSERT INTO bank_cashback_categories (id, bank_id, label, category_id)
            VALUES (?, ?, 'Synthetic label', 'synthetic-category')
            """, arguments: [UUID().uuidString, key])
      default: break
      }
    }
    return (stack, PlanningChange(delete: gone))
  }
}
