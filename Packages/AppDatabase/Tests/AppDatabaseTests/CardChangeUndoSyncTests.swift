import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// A card turned into a credit card, and a card's own balance switched on, are one planning
/// change each, taken back by ⌘Z and made again by ⌘⇧Z. The other device is brought up to date
/// at any of the four moments in between — a spread of subsets of them is tried, none, each alone, alternating and all — and ends with the
/// same books, no row put off, no card on another account's operation, and the first device
/// ends exactly as it was before the change.
@Suite("Undo and redo of a card change with a sync in between")
struct CardChangeUndoSyncTests {
  let fixture = CardToCreditCardWriteTests()
  let start = DateOnly(year: 2026, month: 3, day: 1)

  func change(
    ownBalance: Bool, past: CardPastOperations, book: CardToCreditCardWriteTests.Book
  ) throws -> PlanningChange {
    let at = fixture.at("2026-04-01")
    if ownBalance {
      let plan = try CardOwnBalance.plan(
        separating: book.black.id, past: past, cards: [book.black, book.plain],
        accounts: [book.debit]
      ).get()
      return .cardConversion(plan, at: at)
    }
    return .cardConversion(try fixture.plan(book, past), at: at)
  }

  @Test(
    arguments: [false, true],
    [CardPastOperations.all, .none, .onAndAfter(DateOnly(year: 2026, month: 3, day: 1))])
  func theOtherDeviceFollowsEveryOrderOfSyncs(
    ownBalance: Bool, past: CardPastOperations
  ) throws {
    for syncs in [0, 1, 2, 4, 8, 5, 10, 15] {
      try followsTheSyncs(ownBalance: ownBalance, past: past, syncs: syncs)
    }
  }

  func followsTheSyncs(ownBalance: Bool, past: CardPastOperations, syncs: Int) throws {
    let mac = try TestDevice("mac-\(syncs)")
    let phone = try TestDevice("phone-\(syncs)")
    let folder = InMemoryFolder()
    let book = try fixture.book(mac.stack)
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    let label = "own \(ownBalance), \(past), syncs \(syncs)"
    #expect(try mac.books() == phone.books(), "\(label): before the change")
    let before = try SyncContractsPropertyTests.nonServiceTables(mac.stack)
    let phoneBefore = try SyncContractsPropertyTests.nonServiceTables(phone.stack)

    func syncIf(_ bit: Int) throws {
      if syncs & (1 << bit) != 0 { try SyncContractsPropertyTests.settle([mac, phone], folder) }
    }

    let repository = PlanningRepository(writer: mac.stack.writer, liveCounts: fixture.context)
    let forward = try change(ownBalance: ownBalance, past: past, book: book)
    let undo = try repository.apply(forward)
    try syncIf(0)
    try repository.revert(undo, at: fixture.at("2026-04-02"))
    try syncIf(1)
    let redo = try repository.apply(try #require(undo.change))
    try syncIf(2)
    try repository.revert(redo, at: fixture.at("2026-04-03"))
    try syncIf(3)
    try SyncContractsPropertyTests.settle([mac, phone], folder)

    let after = try SyncContractsPropertyTests.nonServiceTables(mac.stack)
    #expect(
      after == before,
      "\(label): \(PlanningUndoPropertyTests.difference(before, after))")
    #expect(try mac.books() == phone.books(), "\(label): the devices differ")
    for device in [mac, phone] {
      let outcome = try device.exchange.exchange(with: folder)
      #expect(outcome.deferred == 0 && outcome.conflictsOpen == 0, "\(label): \(device.id)")
      #expect(try fixture.cardsOfOtherAccounts(device.stack) == 0, "\(label): \(device.id)")
      #expect(try DatabaseCheck.run(device.stack.writer).isHealthy, "\(label): \(device.id)")
    }
    // The change taken back leaves the phone with what it had before it (the rows it holds
    // on top of the books — its own service rows — are not compared).
    let phoneAfter = try SyncContractsPropertyTests.nonServiceTables(phone.stack)
    for table in ["payment_methods", "cards", "scheduled_payments", "cashback_rules"] {
      #expect(
        Set(phoneAfter[table]?.rows.map { $0.dropFirst() } ?? [])
          == Set(phoneBefore[table]?.rows.map { $0.dropFirst() } ?? []),
        "\(label): \(table) on the phone")
    }
  }

  /// The change is applied and left: an edit of the moved card on the phone travels back.
  @Test(arguments: [false, true])
  func aCardEditedOnThePhoneAfterTheChangeComesBack(ownBalance: Bool) throws {
    let mac = try TestDevice("mac-edit")
    let phone = try TestDevice("phone-edit")
    let folder = InMemoryFolder()
    let book = try fixture.book(mac.stack)
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    let repository = PlanningRepository(writer: mac.stack.writer, liveCounts: fixture.context)
    _ = try repository.apply(try change(ownBalance: ownBalance, past: .all, book: book))
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    try phone.sql(
      "UPDATE cards SET name = 'Renamed on the phone' WHERE id = ?", [book.black.id.uuidString])
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    let name = try mac.stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT name FROM cards WHERE id = ?", arguments: [book.black.id.uuidString])
    }
    #expect(name == "Renamed on the phone")
    #expect(try mac.books() == phone.books())
    #expect(try fixture.cardsOfOtherAccounts(mac.stack) == 0)
  }

  func isOn(_ device: TestDevice, card: UUID) throws -> Bool {
    let (cards, accounts) = try device.stack.writer.read { db in
      (try PaymentCard.fetchAll(db), try PaymentMethod.fetchAll(db))
    }
    let found = try #require(cards.first { $0.id == card })
    return CardOwnBalance.isOn(for: found, accounts: accounts)
  }

  func agree(_ mac: TestDevice, _ phone: TestDevice, _ card: UUID, on: Bool, _ step: String) throws
  {
    #expect(try isOn(mac, card: card) == on, "\(step): the Mac")
    #expect(try isOn(phone, card: card) == on, "\(step): the phone")
    #expect(try mac.books() == phone.books(), "\(step): the books differ")
    for device in [mac, phone] {
      #expect(try device.count("sync_deferred") == 0, "\(step): \(device.id) puts rows off")
      #expect(try fixture.cardsOfOtherAccounts(device.stack) == 0, "\(step): \(device.id)")
    }
  }

  /// Own balance on, then off (the two accounts merge), then ⌘Z of the merge, then ⌘⇧Z of it:
  /// the other device is brought up to date after every step and agrees on the switch, the
  /// books and the cards.
  @Test func switchingOwnBalanceOffAndItsUndoAndRedoFollowOnTheOtherDevice() async throws {
    let mac = try TestDevice("mac-off")
    let phone = try TestDevice("phone-off")
    let folder = InMemoryFolder()
    let book = try fixture.book(mac.stack)
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    let repository = PlanningRepository(writer: mac.stack.writer, liveCounts: fixture.context)
    let plan = try CardOwnBalance.plan(
      separating: book.black.id, past: .all, cards: [book.black, book.plain],
      accounts: [book.debit]
    ).get()
    _ = try repository.apply(.cardConversion(plan, at: fixture.at("2026-04-01")))
    // Each account is counted on its own, as the merge asks before it takes them together.
    try fixture.count(book.debit.id, 12_000, at: fixture.at("2026-04-02"), stack: mac.stack)
    try fixture.count(plan.account.id, 3_000, at: fixture.at("2026-04-02"), stack: mac.stack)
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    try agree(mac, phone, book.black.id, on: true, "on")

    let now = fixture.at("2026-04-03")
    let dataset = try await DatasetRepository(writer: mac.stack.writer).load(version: 0)
    let summary = AccountsSnapshot.build(
      dataset: dataset, now: now, calendar: .utc, rubPerUnit: [:], localeIdentifier: "en_US")
    let (merge, needs) = AccountMerge.plan(
      source: plan.account, target: plan.former, transfers: dataset.transfers,
      balances: summary.balances, at: now)
    #expect(needs.isEmpty)
    let undo = try repository.apply(PlanningChange(at: now, mergingAccounts: merge))
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    try agree(mac, phone, book.black.id, on: false, "off")

    try repository.revert(undo, at: now)
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    try agree(mac, phone, book.black.id, on: true, "off undone")

    let redo = try repository.apply(try #require(undo.change))
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    try agree(mac, phone, book.black.id, on: false, "off again")

    try repository.revert(redo, at: now)
    try SyncContractsPropertyTests.settle([mac, phone], folder)
    try agree(mac, phone, book.black.id, on: true, "off undone twice")
    #expect(try DatabaseCheck.run(phone.stack.writer).isHealthy)
  }
}
