import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The whole road of an older database with one card, no main account and operations written
/// without one: the update makes «Основной счёт» for those operations; the setup of the
/// accounts picks the card as main and counts both; the owner then merges «Основной счёт» into
/// the card. At the end every operation — the bin's too — is on the card, the card alone is
/// main, no key points nowhere, no operation changed but for its account, and the card holds
/// what the two held together: nothing counted twice, nothing lost.
@Suite("The account the update made merges into the owner's card")
struct CreatedMainAccountMergeTests {
  @Test(arguments: Array(UInt64(701)...UInt64(716)))
  func theMadeAccountMergesIntoTheCardAndNothingIsCountedTwice(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(
      seed: seed, operations: 120, accounts: 1...1, flags: RandomLegacyDatabase.Flags.none,
      unassigned: true)
    defer { book.remove() }
    let card = try #require(book.accounts.first)
    // The road starts from a live card and operations without an account; a draw without them
    // has nothing to merge.
    guard !card.archived,
      MainAccountModel.main(accounts: book.accounts, operations: book.operationAccounts) == .created
    else { return }

    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource,
      context: MigrationContext(mainAccountName: "Основной счёт"))
    defer { try? stack.close() }
    let calendar = TestSupport.sampleCalendar
    let accounts = try stack.writer.read { db in try PaymentMethod.order(Column.rowID).fetchAll(db)
    }
    #expect(accounts.count == 2)
    let cardId = try #require(UUID(uuidString: card.id))
    let made = try #require(accounts.first { $0.id != cardId })
    #expect(made.isDefault && made.name == "Основной счёт")
    let operationsBefore = try stack.writer.read { db in
      try ExactTables.read(db)["transactions"]!.dropping("payment_method_id")
    }

    // The setup: the card is main, and both are counted in every currency they hold or moved
    // money in — an older card moved money in the currency of each of its operations.
    let moved = Self.balances(
      try stack.writer.read { db in try DatasetRepository.dataset(db, version: 0) },
      at: Date(timeIntervalSince1970: 1_790_000_000), calendar: calendar
    ).keys
    var opening: [BalanceKey: AmountE4] = [:]
    for account in accounts {
      for currency in Set(
        account.currencies + moved.filter { $0.accountId == account.id }.map(\.currency))
      {
        opening[BalanceKey(accountId: account.id, currency: currency)] =
          AmountE4(whole: account.id == cardId ? 1_000 : 200)
      }
    }
    try AccountRepository(writer: stack.writer).finishSetup(
      AccountSetupPlan(
        accounts: accounts, mainAccountId: cardId, openingBalances: opening,
        at: Date(timeIntervalSince1970: 1_790_000_000)),
      calendar: calendar)

    // The update filed «Основной счёт» under a bank of its own name, and only accounts of one
    // bank merge: the owner merges that bank into the card's first, one planning change.
    let filed = try stack.writer.read { db in
      (try Bank.fetchAll(db), try PaymentMethod.fetchAll(db))
    }
    let madeBank = try #require(filed.1.first { $0.id == made.id }?.bankId)
    let cardBank = try #require(filed.1.first { $0.id == cardId }?.bankId)
    if madeBank != cardBank {
      let banks = try BankMerge.plan(
        merging: madeBank, into: cardBank, banks: filed.0, accounts: filed.1
      ).get()
      _ = try PlanningRepository(writer: stack.writer).apply(
        PlanningChange(
          upsert: PlanningRows(paymentMethods: banks.movedAccounts),
          delete: PlanningRowIDs(banks: [banks.merged.id])))
    }

    // The merge of «Основной счёт» into the card, the way the settings work it out.
    let at = Date(timeIntervalSince1970: 1_790_100_000)
    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
    let balances = Self.balances(dataset, at: at, calendar: calendar)
    let source = try #require(dataset.paymentMethods.first { $0.id == made.id })
    let target = try #require(dataset.paymentMethods.first { $0.id == cardId })
    let (plan, needsBalance) = AccountMerge.plan(
      source: source, target: target, transfers: dataset.transfers, balances: balances, at: at)
    #expect(needsBalance.isEmpty, "seed \(seed): both were counted")
    try AccountRepository(writer: stack.writer).merge(plan, calendar: calendar)

    try stack.writer.read { (db: Database) throws in
      #expect(
        try String.fetchAll(db, sql: "SELECT DISTINCT payment_method_id FROM transactions")
          == [cardId.uuidString], "seed \(seed): an operation is not on the card")
      #expect(
        try String.fetchAll(
          db, sql: "SELECT id FROM payment_methods WHERE is_default = 1 AND archived = 0")
          == [cardId.uuidString], "seed \(seed)")
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty, "seed \(seed)")
      #expect(
        try ExactTables.read(db)["transactions"]!.dropping("payment_method_id") == operationsBefore,
        "seed \(seed): an operation changed")
    }
    let merged = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 2) }
    let after = Self.balances(merged, at: at, calendar: calendar)
    #expect(!plan.opening.isEmpty, "seed \(seed)")
    for currency in Set(plan.opening.keys.map(\.currency)) {
      let into = BalanceKey(accountId: cardId, currency: currency)
      let from = BalanceKey(accountId: made.id, currency: currency)
      let together =
        (balances.balance(into, at: at) ?? .zero) + (balances.balance(from, at: at) ?? .zero)
      #expect(after.balance(into, at: at) == together, "seed \(seed): \(currency.code)")
      #expect(after.balance(from, at: at) ?? .zero == .zero, "seed \(seed): \(currency.code)")
    }
  }

  /// The road is walked on most of the drawn databases, not passed over.
  @Test func mostDrawsWalkTheRoad() throws {
    var walked = 0
    for seed in UInt64(701)...UInt64(716) {
      let book = try RandomLegacyDatabase(
        seed: seed, operations: 120, accounts: 1...1, flags: RandomLegacyDatabase.Flags.none,
        unassigned: true)
      defer { book.remove() }
      if let card = book.accounts.first, !card.archived,
        MainAccountModel.main(accounts: book.accounts, operations: book.operationAccounts)
          == .created
      {
        walked += 1
      }
    }
    #expect(walked >= 8, "only \(walked) of 16")
  }

  private static func balances(
    _ dataset: Dataset, at: Date, calendar: CalendarContext
  ) -> AccountBalances {
    AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries,
      debts: Dictionary(uniqueKeysWithValues: dataset.debts.map { ($0.id, $0) }),
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: at, calendar: calendar)
  }
}
