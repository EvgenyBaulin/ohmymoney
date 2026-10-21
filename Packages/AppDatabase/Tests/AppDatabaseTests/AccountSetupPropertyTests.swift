import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The setup of the accounts after the update, finished or put off, on older databases drawn at
/// random: exactly one live account is main — the one chosen, or the one «Позже» keeps or makes —,
/// no operation is left without an account, the counts the owner gave are the first
/// reconciliation, every currency an account holds is switched on, and nothing of the history
/// moves: every operation keeps its account, its money and its time of writing.
@Suite("The setup of the accounts after the update keeps the history")
struct AccountSetupPropertyTests {
  private static let context = MigrationContext(mainAccountName: "Основной счёт")

  /// The operations as they are, but for the account the setup may give those with none.
  private static func operations(_ db: Database) throws -> ExactTable {
    try ExactTables.read(db)["transactions"]!.dropping("payment_method_id")
  }

  private static func liveMains(_ db: Database) throws -> [String] {
    try String.fetchAll(
      db, sql: "SELECT id FROM payment_methods WHERE is_default = 1 AND archived = 0")
  }

  /// «Позже» on an updated older database: the main account the update chose stays main, no
  /// operation moves, and the setup is marked put off.
  @Test(arguments: Array(UInt64(601)...UInt64(615)))
  func puttingTheSetupOffKeepsTheMainAccountAndTheHistory(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    let (before, mainBefore) = try stack.writer.read { db in
      (try Self.operations(db), try Self.liveMains(db))
    }

    try AccountRepository(writer: stack.writer).postponeSetup(
      mainAccountName: "Основной счёт", defaultCurrency: .rub,
      at: Date(timeIntervalSince1970: 1_790_000_000))

    try stack.writer.read { (db: Database) throws in
      let mains = try Self.liveMains(db)
      #expect(mains.count == 1, "seed \(seed)")
      if !mainBefore.isEmpty { #expect(mains == mainBefore, "seed \(seed)") }
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL")
          == 0)
      #expect(try Self.operations(db) == before, "seed \(seed): an operation changed")
      #expect(
        try String.fetchOne(
          db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [AccountSettings.setupKey]
        )
          == AccountSettings.Setup.later.rawValue)
    }
    #expect(try AccountRepository(writer: stack.writer).ensureMainAccount() == nil, "seed \(seed)")
  }

  /// The setup finished with the accounts as they are, a main account picked at random among
  /// the live ones and counts drawn for some of their currencies — below zero too —: that
  /// account alone is main, the counts are one opening reconciliation of the setup — starting
  /// points —, only the balances typed are written (an account left empty stays uncounted), the
  /// currencies held are on, and the history does not move.
  @Test(arguments: Array(UInt64(621)...UInt64(640)))
  func finishingTheSetupMakesThePickedAccountMainAndCountsTheBalances(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed, accounts: 1...5)
    defer { book.remove() }
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    var random = SeededRandom(seed: seed)
    let (before, accounts) = try stack.writer.read { db in
      (try Self.operations(db), try PaymentMethod.fetchAll(db))
    }
    let live = accounts.filter { !$0.archived }
    guard let main = live.isEmpty ? nil : live[random.int(in: 0..<live.count)] else { return }
    var opening: [BalanceKey: AmountE4] = [:]
    for account in live where random.chance(2, outOf: 3) {
      for currency in account.currencies {
        opening[BalanceKey(accountId: account.id, currency: currency)] =
          AmountE4(raw: Int64(random.int(in: -5_000...900_000)) * 100)
      }
    }
    let plan = AccountSetupPlan(
      accounts: accounts, mainAccountId: main.id, openingBalances: opening,
      at: Date(timeIntervalSince1970: 1_790_000_000))

    try AccountRepository(writer: stack.writer).finishSetup(
      plan, calendar: TestSupport.sampleCalendar)

    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
    try stack.writer.read { (db: Database) throws in
      #expect(try Self.liveMains(db) == [main.id.uuidString], "seed \(seed)")
      #expect(try Self.operations(db) == before, "seed \(seed): an operation changed")
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL")
          == 0)
    }
    let openings = dataset.planning.reconciliations.filter { $0.kind == .opening }
    #expect(openings.count == (opening.isEmpty ? 0 : 1), "seed \(seed)")
    #expect(openings.allSatisfy { $0.origin == .setup }, "seed \(seed): not the setup's")
    let counted = Dictionary(
      uniqueKeysWithValues: dataset.planning.reconciledBalances.map { ($0.key, $0) })
    #expect(counted.count == opening.count, "seed \(seed)")
    for account in live {
      for currency in account.currencies {
        let key = BalanceKey(accountId: account.id, currency: currency)
        #expect(
          (counted[key] != nil) == (opening[key] != nil),
          "seed \(seed): \(key) counted though nothing was typed, or the other way")
      }
    }
    for (key, amount) in opening {
      let balance = try #require(counted[key], "seed \(seed): \(key) was not counted")
      #expect(balance.actualE4 == amount)
      #expect(balance.isStartingPoint, "seed \(seed): the first count compares")
    }
    let enabled = Set(try SettingsRepository(writer: stack.writer).enabledCurrencies())
    for account in live {
      #expect(Set(account.currencies).isSubset(of: enabled), "seed \(seed): \(account.currencies)")
    }
    #expect(dataset.accountSettings.setup == .done)
    #expect(try AccountRepository(writer: stack.writer).ensureMainAccount() == nil, "seed \(seed)")
  }
}
