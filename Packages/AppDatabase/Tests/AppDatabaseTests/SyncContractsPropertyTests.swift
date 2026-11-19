import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only; every random choice comes from a seed.

struct ContractsDice: RandomNumberGenerator {
  var state: UInt64
  init(_ seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func uuid() -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &self) }
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
  mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
  mutating func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &self) < percent }
}

/// The columns and tables that the schemas 33 and 34 and the write order of accounts and cards
/// brought, written on two devices in random order and read on the other through the journal:
/// the books end equal, nothing waits for ever, and every zone and every answer is as written.
@Suite("The exchange keeps the new columns and tables whatever the order of batches")
struct SyncContractsPropertyTests {
  static let zones: [String?] = [
    nil, "Europe/Moscow", "Asia/Makassar", "America/Los_Angeles", "Pacific/Auckland",
    "Asia/Kolkata", "Mars/Olympus",
  ]
  let at = Date(timeIntervalSince1970: 1_790_000_000)

  /// Both devices exchange until neither has anything to say, then once more to be sure.
  static func settle(_ devices: [TestDevice], _ folder: any JournalFolder) throws {
    for _ in 0..<10 {
      var moved = 0
      for device in devices {
        let outcome = try device.exchange.exchange(with: folder)
        moved += outcome.entriesWritten + outcome.recordsApplied
      }
      if moved == 0 { return }
    }
  }

  static func nonServiceTables(_ stack: DatabaseStack) throws -> [String: ExactTable] {
    try PlanningUndoPropertyTests.contents(stack).filter { !$0.key.hasPrefix("sync_") }
  }

  struct Written {
    var transferZones: [String: String?] = [:]
    var reconciliationZones: [String: String?] = [:]
    var accounts: [String: String] = [:]  // account id → main card id
    var dues: [String: String?] = [:]  // due id → moved_to
  }

  /// The accounts a device made, with a main card each: the account is written with its card
  /// and its main card in one change.
  static func newAccount(
    _ dice: inout ContractsDice, name: String, on device: TestDevice, at: Date,
    written: inout Written
  ) throws -> UUID {
    var account = PaymentMethod(id: dice.uuid(), name: name, kind: .card, currency: .rub)
    let card = PaymentCard(id: dice.uuid(), accountId: account.id, name: "\(name) card")
    account.mainCardId = card.id
    _ = try PlanningRepository(writer: device.stack.writer).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [account], cards: [card]), at: at))
    written.accounts[account.id.uuidString] = card.id.uuidString
    return account.id
  }

  static func transfer(
    _ dice: inout ContractsDice, from: UUID, to: UUID, on device: TestDevice, written: inout Written
  ) throws {
    let id = dice.uuid().uuidString
    let zone = dice.pick(zones)
    let hour = Int.random(in: 0..<24, using: &dice)
    let amount = Int64.random(in: 1...900, using: &dice) * 10_000
    try device.sql(
      """
      INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
        from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at, updated_at,
        time_zone)
      VALUES (?, ?, ?, 'RUB', ?, ?, 'RUB', ?, '2026-11-01 00:00:00.000',
        '2026-11-01 00:00:00.000', ?)
      """,
      [
        id,
        String(format: "2026-11-%02d %02d:15:00.000", Int.random(in: 1...28, using: &dice), hour),
        from.uuidString, amount, to.uuidString, amount, zone,
      ])
    written.transferZones.updateValue(zone, forKey: id)
  }

  static func reconciliation(
    _ dice: inout ContractsDice, account: UUID, on device: TestDevice, written: inout Written
  ) throws {
    let id = dice.uuid().uuidString
    let zone = dice.pick(zones)
    let day = Int.random(in: 1...28, using: &dice)
    try device.sql(
      """
      INSERT INTO reconciliations (id, date, actual_total_rub_e4, reconciled_at, kind, time_zone)
      VALUES (?, ?, 0, ?, 'accounts', ?)
      """,
      [
        id, String(format: "2026-11-%02d", day), String(format: "2026-11-%02d 21:30:00.000", day),
        zone,
      ])
    try device.sql(
      """
      INSERT INTO reconciliation_balances (id, reconciliation_id, payment_method_id, currency,
        actual_e4) VALUES (?, ?, ?, 'RUB', 5000000)
      """,
      [dice.uuid().uuidString, id, account.uuidString])
    written.reconciliationZones.updateValue(zone, forKey: id)
  }

  static func answer(
    _ income: UUID, due: DateOnly, movedTo: DateOnly?, on device: TestDevice,
    written: inout Written
  ) throws {
    let mark = ExpectedIncomeDue(expectedIncomeId: income, due: due, movedTo: movedTo)
    _ = try PlanningRepository(writer: device.stack.writer).apply(
      PlanningChange(upsert: PlanningRows(expectedDues: [mark])))
    written.dues.updateValue(movedTo?.iso, forKey: mark.id.uuidString)
  }

  static func insertIncome(_ id: UUID, on device: TestDevice) throws {
    try device.sql(
      """
      INSERT INTO expected_income (id, name, kind, total_e4, currency, due_date, freq, day,
        parts_expected, closed)
      VALUES (?, 'Salary', 'recurring', 1000000000, 'RUB', '2026-01-05', 'monthly', 5, 1, 0)
      """, [id.uuidString])
  }

  /// Two devices write at random — accounts with main cards, transfers and counts in a zone,
  /// answers for dues of incomes (each device its own months) — and exchange at random moments:
  /// a batch holds whatever was written since the last exchange, so every seed is another
  /// grouping and another order of arrival.
  @Test(arguments: Array(UInt64(1)...UInt64(20)))
  func randomBatchesOnTwoDevicesEndWithEqualBooksAndEveryValueAsWritten(seed: UInt64) throws {
    var dice = ContractsDice(seed &* 7919)
    let mac = try TestDevice("mac-\(seed)")
    let phone = try TestDevice("phone-\(seed)")
    let folder = InMemoryFolder()
    var written = Written()

    // Both know the incomes from the start.
    let incomes = [dice.uuid(), dice.uuid()]
    for income in incomes { try Self.insertIncome(income, on: mac) }
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)

    var accounts: [(TestDevice, UUID)] = []
    var known: [UUID] = []
    let steps = Int.random(in: 14...30, using: &dice)
    for step in 0..<steps {
      let device = dice.chance(50) ? mac : phone
      switch Int.random(in: 0..<10, using: &dice) {
      case 0...2:
        let id = try Self.newAccount(
          &dice, name: "A\(step)", on: device, at: at, written: &written)
        accounts.append((device, id))
        known.append(id)
      case 3...5:
        // A transfer between two accounts the device itself made, so the transfer is never the
        // first to meet an account the other device has not got yet.
        let own = accounts.filter { $0.0.id == device.id }.map(\.1)
        guard own.count >= 2 else { continue }
        let from = dice.pick(own)
        let to = dice.pick(own.filter { $0 != from })
        try Self.transfer(&dice, from: from, to: to, on: device, written: &written)
      case 6...7:
        let own = accounts.filter { $0.0.id == device.id }.map(\.1)
        guard !own.isEmpty else { continue }
        try Self.reconciliation(
          &dice, account: dice.pick(own), on: device, written: &written)
      default:
        // Months decide whose answer it is: the Mac answers odd months, the phone even ones.
        let month = Int.random(in: 1...6, using: &dice)
        let odd = month % 2 == 1
        let answering = odd ? mac : phone
        let income = dice.pick(incomes)
        let moved: DateOnly? =
          dice.chance(50)
          ? nil : DateOnly(year: 2026, month: month, day: Int.random(in: 6...27, using: &dice))
        try Self.answer(
          income, due: DateOnly(year: 2026, month: month, day: 5), movedTo: moved,
          on: answering, written: &written)
      }
      if dice.chance(35) { _ = try mac.exchange.exchange(with: folder) }
      if dice.chance(35) { _ = try phone.exchange.exchange(with: folder) }
    }
    try Self.settle([mac, phone], folder)

    #expect(try mac.books() == phone.books(), "seed \(seed)")
    for device in [mac, phone] {
      let outcome = try device.exchange.exchange(with: folder)
      #expect(outcome.deferred == 0, "seed \(seed): \(device.id) still defers rows")
      #expect(outcome.conflictsOpen == 0, "seed \(seed)")
      #expect(try device.count("sync_deferred") == 0)
      #expect(try DatabaseCheck.run(device.stack.writer).isHealthy, "seed \(seed)")
      try device.stack.writer.read { (db: Database) throws in
        for (id, zone) in written.transferZones {
          let stored = try Row.fetchOne(
            db, sql: "SELECT time_zone FROM transfers WHERE id = ?", arguments: [id])
          #expect(stored != nil, "seed \(seed): transfer \(id) is lost on \(device.id)")
          let value: String? = stored?["time_zone"]
          #expect(value == zone, "seed \(seed): the zone of transfer \(id) changed")
        }
        for (id, zone) in written.reconciliationZones {
          let stored = try Row.fetchOne(
            db, sql: "SELECT time_zone FROM reconciliations WHERE id = ?", arguments: [id])
          #expect(stored != nil, "seed \(seed): count \(id) is lost on \(device.id)")
          let value: String? = stored?["time_zone"]
          #expect(value == zone, "seed \(seed): the zone of count \(id) changed")
          #expect(
            try Int.fetchOne(
              db, sql: "SELECT COUNT(*) FROM reconciliation_balances WHERE reconciliation_id = ?",
              arguments: [id]) == 1)
        }
        for (account, card) in written.accounts {
          let main = try String.fetchOne(
            db, sql: "SELECT main_card_id FROM payment_methods WHERE id = ?", arguments: [account])
          #expect(main == card, "seed \(seed): the main card of \(account) is not on \(device.id)")
        }
        for (id, moved) in written.dues {
          let row = try Row.fetchOne(
            db, sql: "SELECT due_on, moved_to FROM expected_income_dues WHERE id = ?",
            arguments: [id])
          #expect(row != nil, "seed \(seed): answer \(id) is lost on \(device.id)")
          let value: String? = row?["moved_to"]
          #expect(value == moved, "seed \(seed): answer \(id) changed")
        }
        let stored = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM expected_income_dues") ?? -1
        #expect(
          stored == written.dues.count,
          "seed \(seed): \(stored) rows, \(written.dues.count) written")
      }
    }
  }

  /// A device that joins after everything was written takes all of it from the files: the
  /// snapshot path and the journal path end in the same books.
  @Test(arguments: Array(UInt64(101)...UInt64(105)))
  func aDeviceJoiningLaterTakesTheNewColumnsAndTablesInOneExchange(seed: UInt64) throws {
    var dice = ContractsDice(seed)
    let mac = try TestDevice("mac-\(seed)")
    let folder = InMemoryFolder()
    var written = Written()
    let income = dice.uuid()
    try Self.insertIncome(income, on: mac)
    var ids: [UUID] = []
    for index in 0..<Int.random(in: 2...5, using: &dice) {
      ids.append(
        try Self.newAccount(&dice, name: "J\(index)", on: mac, at: at, written: &written))
    }
    for _ in 0..<Int.random(in: 2...6, using: &dice) {
      let from = dice.pick(ids)
      try Self.transfer(
        &dice, from: from, to: dice.pick(ids.filter { $0 != from }), on: mac, written: &written)
      try Self.reconciliation(&dice, account: dice.pick(ids), on: mac, written: &written)
    }
    for month in 1...Int.random(in: 1...6, using: &dice) {
      try Self.answer(
        income, due: DateOnly(year: 2026, month: month, day: 5),
        movedTo: dice.chance(50) ? nil : DateOnly(year: 2026, month: month, day: 20), on: mac,
        written: &written)
    }
    _ = try mac.exchange.exchange(with: folder)
    let phone = try TestDevice("phone-\(seed)")
    let taken = try phone.exchange.exchange(with: folder)
    #expect(taken.deferred == 0, "seed \(seed)")
    try Self.settle([mac, phone], folder)
    #expect(try mac.books() == phone.books(), "seed \(seed)")
    #expect(try phone.count("transfers") == written.transferZones.count)
    #expect(try phone.count("reconciliations") == written.reconciliationZones.count)
    let stored = try phone.count("expected_income_dues")
    #expect(
      stored == written.dues.count, "seed \(seed): \(stored) rows, \(written.dues.count) written")
  }

  // MARK: The same income due answered differently on two devices

  private static func choice(_ dice: inout ContractsDice, _ due: DateOnly) -> DateOnly? {
    dice.chance(40)
      ? nil : DateOnly(year: due.year, month: due.month, day: Int.random(in: 6...28, using: &dice))
  }

  private static func storedAnswer(_ device: TestDevice, _ id: UUID) throws -> [String?]? {
    try device.stack.writer.read { (db: Database) throws in
      try Row.fetchOne(
        db, sql: "SELECT due_on, moved_to FROM expected_income_dues WHERE id = ?",
        arguments: [id.uuidString]
      ).map { [$0["due_on"] as String?, $0["moved_to"] as String?] }
    }
  }

  /// Two devices answer the very same due before either hears the other — every pair of
  /// answers (skip against move, move against another move, the same answer twice) in either
  /// order of the exchanges: one row each, never put off; either the books agree by themselves
  /// or both owners are told, and a choice makes them agree on the chosen answer.
  @Test(arguments: Array(UInt64(201)...UInt64(230)))
  func twoAnswersForOneDueNeverDivergeUnseenAndAChoiceSettlesThem(seed: UInt64) throws {
    var dice = ContractsDice(seed)
    let mac = try TestDevice("mac-\(seed)")
    let phone = try TestDevice("phone-\(seed)")
    let folder = InMemoryFolder()
    let income = dice.uuid()
    try Self.insertIncome(income, on: mac)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)

    let due = DateOnly(year: 2026, month: Int.random(in: 1...12, using: &dice), day: 5)
    let macAnswer = Self.choice(&dice, due)
    let phoneAnswer = dice.chance(15) ? macAnswer : Self.choice(&dice, due)
    var ignored = Written()
    try Self.answer(income, due: due, movedTo: macAnswer, on: mac, written: &ignored)
    try Self.answer(income, due: due, movedTo: phoneAnswer, on: phone, written: &ignored)
    let id = ExpectedIncomeDue.id(incomeId: income, due: due)

    let order = dice.chance(50) ? [mac, phone] : [phone, mac]
    for _ in 0..<3 { for device in order { _ = try device.exchange.exchange(with: folder) } }

    for device in [mac, phone] {
      #expect(try device.count("expected_income_dues") == 1, "seed \(seed)")
      #expect(try device.count("sync_deferred") == 0, "seed \(seed)")
    }
    let key = RecordKey(table: "expected_income_dues", uuid: id.uuidString)
    if macAnswer == phoneAnswer {
      // The same answer written twice is no disagreement: the books agree whatever is listed.
      #expect(try Self.storedAnswer(mac, id) == Self.storedAnswer(phone, id), "seed \(seed)")
      return
    }
    // Two different answers to one due are never settled silently: both owners are told, about
    // this row only.
    #expect(try mac.exchange.conflicts().map(\.key) == [key], "seed \(seed): the Mac")
    #expect(try phone.exchange.conflicts().map(\.key) == [key], "seed \(seed): the phone")
    // The Mac's answer is chosen, from either side.
    if seed % 2 == 0 {
      try mac.exchange.keepMine(key)
    } else {
      try phone.exchange.takeTheirs(key)
    }
    try Self.settle([mac, phone], folder)
    #expect(try mac.exchange.conflicts().isEmpty, "seed \(seed)")
    #expect(try phone.exchange.conflicts().isEmpty, "seed \(seed)")
    let expected = [due.iso, macAnswer?.iso] as [String?]
    #expect(try Self.storedAnswer(mac, id) == expected, "seed \(seed)")
    #expect(try Self.storedAnswer(phone, id) == expected, "seed \(seed)")
    #expect(try mac.books() == phone.books(), "seed \(seed)")
  }

  /// A skip against a move of one due is a visible conflict on both devices, and the owner's
  /// choice on either side — in either order of the exchanges — leaves both with that answer.
  @Test(arguments: [true, false], Array(0..<4))
  func aSkipAgainstAMoveIsShownAndTheChosenAnswerWinsOnBoth(
    macFirst: Bool, choice: Int
  ) throws {
    let mac = try TestDevice("mac-visible")
    let phone = try TestDevice("phone-visible")
    let folder = InMemoryFolder()
    let income = UUID(uuidString: "A6969696-9696-4696-8696-969696969696")!
    try Self.insertIncome(income, on: mac)
    try Self.settle([mac, phone], folder)
    let due = DateOnly(year: 2026, month: 9, day: 5)
    var ignored = Written()
    try Self.answer(income, due: due, movedTo: nil, on: mac, written: &ignored)
    try Self.answer(
      income, due: due, movedTo: DateOnly(year: 2026, month: 9, day: 25), on: phone,
      written: &ignored)
    let order = macFirst ? [mac, phone] : [phone, mac]
    for _ in 0..<3 { for device in order { _ = try device.exchange.exchange(with: folder) } }
    let key = RecordKey(
      table: "expected_income_dues",
      uuid: ExpectedIncomeDue.id(incomeId: income, due: due).uuidString)
    let macSees = try mac.exchange.conflicts().map(\.key)
    let phoneSees = try phone.exchange.conflicts().map(\.key)
    #expect(macSees == [key] && phoneSees == [key])
    // 0: the Mac keeps its skip; 1: the phone keeps its move; 2: the Mac takes the phone's move;
    // 3: the phone takes the Mac's skip.
    switch choice {
    case 0: try mac.exchange.keepMine(key)
    case 1: try phone.exchange.keepMine(key)
    case 2: try mac.exchange.takeTheirs(key)
    default: try phone.exchange.takeTheirs(key)
    }
    try Self.settle([mac, phone], folder)
    // The owner decided on one device; the other is told by the next file.
    #expect(try mac.books() == phone.books())
    #expect(try mac.exchange.conflicts().isEmpty && phone.exchange.conflicts().isEmpty)
    let id = ExpectedIncomeDue.id(incomeId: income, due: due)
    let macValue = try Self.storedAnswer(mac, id)
    let skip = [due.iso, nil] as [String?]
    #expect(macValue == (choice == 0 || choice == 3 ? skip : [due.iso, "2026-09-25"]))
    #expect(try Self.storedAnswer(phone, id) == macValue)
  }
}
