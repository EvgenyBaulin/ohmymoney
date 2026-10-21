import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The checks the accounts brought into the schema refuse exactly what they promise to refuse:
/// thousands of drawn values — codes in lower case, too short, too long, with digits, spaces,
/// accents and separators; amounts below, at and above zero; half-filled pairs; differences
/// that are not their arithmetic — are written straight into SQLite, and each is accepted
/// exactly when a rule written apart from the schema says it is valid. The keys between the
/// new tables hold or cascade as the schema says.
@Suite("The checks of the accounts refuse exactly what they promise")
struct AccountsSchemaCheckPropertyTests {
  private struct Fixture {
    var stack: DatabaseStack
    var card: String
    var cash: String
    var rubleOperation: String
    var dollarOperation: String
    var debt: String
  }

  private func fixture() throws -> Fixture {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try ReferenceRepository(writer: stack.writer).save(cash)
    let ruble = UUID().uuidString
    let dollar = UUID().uuidString
    try stack.writer.write { db in
      for (id, currency) in [(ruble, "RUB"), (dollar, "USD")] {
        try db.execute(
          sql: """
            INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
              payment_method_id, created_at, updated_at)
            VALUES (?, 'expense', '2026-09-01 10:00:00.000', ?, 10000, 900000, ?, 'x', 'x')
            """,
          arguments: [id, currency, references.paymentMethod.id.uuidString])
      }
    }
    return Fixture(
      stack: stack, card: references.paymentMethod.id.uuidString, cash: cash.id.uuidString,
      rubleOperation: ruble, dollarOperation: dollar, debt: references.debt.id.uuidString)
  }

  /// Whether SQLite takes the statement; nothing of it stays either way.
  private func accepts(
    _ stack: DatabaseStack, _ sql: String, _ arguments: StatementArguments
  ) throws -> Bool {
    var accepted = false
    try stack.writer.writeWithoutTransaction { db in
      try db.inSavepoint {
        do {
          try db.execute(sql: sql, arguments: arguments)
          accepted = true
        } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
          accepted = false
        }
        return .rollback
      }
    }
    return accepted
  }

  /// A drawn code: mostly three letters, often not quite.
  private static func code(_ random: inout SeededRandom) -> String? {
    let pool: [String?] = [
      nil, "RUB", "USD", "KZT", "EUR", "rub", "Usd", "US", "USDT", "", "   ", "R B", "R1B", "RÜB",
      "ÉUR", "US\n", "US,", "RUB ", " RUB",
    ]
    if random.chance(1, outOf: 3) {
      let letters = Array("ABCXYZabz09 ,-É\u{301}")
      let length = random.int(in: 0...5)
      return String((0..<length).map { _ in letters[random.int(in: 0..<letters.count)] })
    }
    return pool[random.int(in: 0..<pool.count)]
  }

  /// Three characters, each an upper-case Latin letter.
  private static func isCode(_ text: String?) -> Bool {
    guard let text else { return false }
    let scalars = Array(text.unicodeScalars)
    return scalars.count == 3 && scalars.allSatisfy { ("A"..."Z").contains($0) }
  }

  private static func amount(_ random: inout SeededRandom) -> Int64? {
    [nil, -1_000_000, -1, 0, 1, 9_000_000, 1_000_000_000_000][random.int(in: 0...6)]
  }

  /// `other_currencies` holds only upper-case letters and commas — the codes after the main
  /// one, joined — and '' for none.
  @Test func theOtherCurrenciesOfAnAccountAreLettersAndCommasOnly() throws {
    let fixture = try fixture()
    var random = SeededRandom(seed: 1)
    let alphabet = Array("ABZaz09 ,;-É\n")
    for round in 0..<600 {
      let text = String(
        (0..<random.int(in: 0...8)).map { _ in
          alphabet[random.int(in: 0..<alphabet.count)]
        })
      let valid = text.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || $0 == "," }
      #expect(
        try accepts(
          fixture.stack, "UPDATE payment_methods SET other_currencies = ? WHERE id = ?",
          [text, fixture.card]) == valid, "round \(round): «\(text)»")
    }
  }

  /// What an account was charged: both halves or neither, a code of another currency than the
  /// operation's own, and more than zero.
  @Test func theChargeOfAnOperationIsWholeInAnotherCurrencyAndAboveZero() throws {
    let fixture = try fixture()
    var random = SeededRandom(seed: 2)
    for round in 0..<1_500 {
      let currency = Self.code(&random)
      let amount = Self.amount(&random)
      let dollars = random.chance(1, outOf: 2)
      let own = dollars ? "USD" : "RUB"
      let valid =
        (currency == nil && amount == nil)
        || (Self.isCode(currency) && currency != own && (amount ?? 0) > 0)
      #expect(
        try accepts(
          fixture.stack,
          "UPDATE transactions SET account_currency = ?, account_amount_e4 = ? WHERE id = ?",
          [currency, amount, dollars ? fixture.dollarOperation : fixture.rubleOperation])
          == valid, "round \(round): \(String(describing: currency)) \(String(describing: amount))")
    }
  }

  /// A transfer goes from somewhere to somewhere else — another account, or another currency of
  /// the same one —, moves more than zero on both ends in valid codes, and in one currency
  /// receives what it sends.
  @Test func aTransferIsBetweenTwoPlacesAndInOneCurrencyLosesNothing() throws {
    let fixture = try fixture()
    var random = SeededRandom(seed: 3)
    let accounts = [fixture.card, fixture.cash]
    let sql = """
      INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
        from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at, updated_at)
      VALUES (?, '2026-09-10 10:00:00.000', ?, ?, ?, ?, ?, ?, 'x', 'x')
      """
    for round in 0..<1_500 {
      let from = accounts[random.int(in: 0...1)]
      let to = accounts[random.int(in: 0...1)]
      let fromCurrency =
        random.chance(3, outOf: 4) ? ["RUB", "USD"][random.int(in: 0...1)] : Self.code(&random)
      let toCurrency =
        random.chance(3, outOf: 4) ? ["RUB", "USD"][random.int(in: 0...1)] : Self.code(&random)
      let sent = random.chance(1, outOf: 5) ? Self.amount(&random) : 100
      let received = random.chance(1, outOf: 3) ? Self.amount(&random) : sent
      let valid =
        Self.isCode(fromCurrency) && Self.isCode(toCurrency) && (sent ?? 0) > 0
        && (received ?? 0) > 0 && !(from == to && fromCurrency == toCurrency)
        && (fromCurrency != toCurrency || sent == received)
      #expect(
        try accepts(
          fixture.stack, sql,
          [UUID().uuidString, from, fromCurrency, sent, to, toCurrency, received]) == valid,
        "round \(round)")
    }
  }

  /// A counted balance: a valid code; an expected balance and a difference together or not at
  /// all; the difference is actual − expected; an operation only for a difference that is not
  /// zero.
  @Test func aCountedBalanceIsItsOwnArithmetic() throws {
    let fixture = try fixture()
    try fixture.stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO reconciliations (id, date, actual_total_rub_e4, kind, reconciled_at)
          VALUES ('r', '2026-09-10', 0, 'accounts', '2026-09-10 10:00:00.000')
          """)
    }
    var random = SeededRandom(seed: 4)
    let sql = """
      INSERT INTO reconciliation_balances (id, reconciliation_id, payment_method_id, currency,
        actual_e4, expected_e4, difference_e4, transaction_id)
      VALUES (?, 'r', ?, ?, ?, ?, ?, ?)
      """
    for round in 0..<1_500 {
      let currency = random.chance(3, outOf: 4) ? "RUB" : Self.code(&random)
      let actual = Int64(random.int(in: -3...3)) * 100
      let expected: Int64? = random.chance(1, outOf: 3) ? nil : Int64(random.int(in: -3...3)) * 100
      let difference: Int64?
      switch random.int(in: 0...3) {
      case 0: difference = nil
      case 1: difference = Int64(random.int(in: -6...6)) * 100
      default: difference = expected.map { actual - $0 }
      }
      let operation = random.chance(1, outOf: 3) ? fixture.rubleOperation : nil
      let valid =
        Self.isCode(currency) && (expected == nil) == (difference == nil)
        && (difference == nil || difference == actual - (expected ?? 0))
        && (operation == nil || (difference != nil && difference != 0))
      #expect(
        try accepts(
          fixture.stack, sql,
          [UUID().uuidString, fixture.card, currency, actual, expected, difference, operation])
          == valid, "round \(round)")
    }
  }

  /// A reconciliation of a known kind; one of accounts, or an opening, has its moment.
  @Test func aReconciliationHasAKnownKindAndTheAccountsOneItsMoment() throws {
    let fixture = try fixture()
    let kinds = ["total", "accounts", "opening", "Total", "weekly", ""]
    for kind in kinds {
      for moment in [nil, "2026-09-10 10:00:00.000"] as [String?] {
        let valid =
          ["total", "accounts", "opening"].contains(kind) && (kind == "total" || moment != nil)
        #expect(
          try accepts(
            fixture.stack,
            """
            INSERT INTO reconciliations (id, date, actual_total_rub_e4, kind, reconciled_at)
            VALUES (?, '2026-09-10', 0, ?, ?)
            """, [UUID().uuidString, kind, moment]) == valid,
          "\(kind) \(String(describing: moment))")
      }
    }
  }

  /// A line of a debt journal says what moved on its account with both halves or neither, in a
  /// valid code, above zero; a goal is in a valid code.
  @Test func aJournalLineAndAGoalHoldValidCodes() throws {
    let fixture = try fixture()
    var random = SeededRandom(seed: 6)
    for round in 0..<800 {
      let currency = Self.code(&random)
      let amount = Self.amount(&random)
      let valid = (currency == nil && amount == nil) || (Self.isCode(currency) && (amount ?? 0) > 0)
      #expect(
        try accepts(
          fixture.stack,
          """
          INSERT INTO debt_entries (id, debt_id, amount_e4, kind, account_currency,
            account_amount_e4)
          VALUES (?, ?, 100, 'borrowed', ?, ?)
          """, [UUID().uuidString, fixture.debt, currency, amount]) == valid, "round \(round)")
      let goalCurrency = Self.code(&random)
      #expect(
        try accepts(
          fixture.stack,
          "INSERT INTO goals (id, name, target_e4, currency) VALUES (?, 'Trip', 1, ?)",
          [UUID().uuidString, goalCurrency]) == Self.isCode(goalCurrency), "round \(round) goal")
    }
  }

  /// A group has a name that is not only spaces, and its flags are 0 or 1.
  @Test func aGroupHasANameAndItsFlagsAreFlags() throws {
    let fixture = try fixture()
    for name in ["", " ", "   ", "Россия", " KZ ", "a"] as [String?] + [nil] {
      let valid = name.map { !$0.trimmingCharacters(in: [" "]).isEmpty } ?? false
      #expect(
        try accepts(
          fixture.stack, "INSERT INTO account_groups (id, name) VALUES (?, ?)",
          [UUID().uuidString, name]) == valid, "«\(String(describing: name))»")
    }
    for flag in [-1, 0, 1, 2] {
      let valid = flag == 0 || flag == 1
      #expect(
        try accepts(
          fixture.stack, "INSERT INTO account_groups (id, name, in_summary) VALUES (?, 'G', ?)",
          [UUID().uuidString, flag]) == valid)
      #expect(
        try accepts(
          fixture.stack, "INSERT INTO account_groups (id, name, archived) VALUES (?, 'G', ?)",
          [UUID().uuidString, flag]) == valid)
      #expect(
        try accepts(
          fixture.stack, "INSERT INTO templates (id, text, archived) VALUES (?, 'x', ?)",
          [UUID().uuidString, flag]) == valid)
    }
  }

  /// The keys between the new tables: an account a transfer points at stays; a part a refund
  /// takes back from stays, even when its operation is deleted; the counts of a reconciliation
  /// go with it and those of an account with the account; an operation that recorded a
  /// difference leaves the count without it; a group deleted leaves its accounts without one.
  @Test func theKeysOfTheAccountsHoldOrCascadeAsTheSchemaSays() throws {
    let fixture = try fixture()
    let stack = fixture.stack
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO account_groups (id, name) VALUES ('g', 'Russia');
          INSERT INTO payment_methods (id, name, kind, group_id) VALUES ('lonely', 'Lonely', 'card', 'g');
          INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
            from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at, updated_at)
          VALUES ('t', '2026-09-10 10:00:00.000', ?, 'RUB', 100, ?, 'RUB', 100, 'x', 'x');
          INSERT INTO reconciliations (id, date, actual_total_rub_e4, kind, reconciled_at)
          VALUES ('r', '2026-09-10', 0, 'accounts', '2026-09-10 10:00:00.000');
          INSERT INTO reconciliation_balances (id, reconciliation_id, payment_method_id, currency,
            actual_e4, expected_e4, difference_e4, transaction_id)
          VALUES ('b1', 'r', ?, 'RUB', 100, 90, 10, ?),
                 ('b2', 'r', 'lonely', 'RUB', 5, NULL, NULL, NULL);
          INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4)
          VALUES ('purchase-part', ?, 10000, 900000);
          INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
            created_at, updated_at)
          VALUES ('refund', 'refund', '2026-09-02 10:00:00.000', 'RUB', 100, 100, 'x', 'x');
          INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4,
            refund_of_part_id)
          VALUES ('refund-part', 'refund', 100, 100, 'purchase-part');
          INSERT INTO debt_entries (id, debt_id, amount_e4, kind, payment_method_id)
          VALUES ('line', ?, 100, 'borrowed', 'lonely');
          """,
        arguments: [
          fixture.card, fixture.cash, fixture.card, fixture.dollarOperation, fixture.rubleOperation,
          fixture.debt,
        ])
    }
    func count(_ sql: String) throws -> Int {
      try stack.writer.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }
    #expect(!(try accepts(stack, "DELETE FROM payment_methods WHERE id = ?", [fixture.cash])))
    #expect(!(try accepts(stack, "DELETE FROM transaction_parts WHERE id = 'purchase-part'", [])))
    #expect(
      !(try accepts(stack, "DELETE FROM transactions WHERE id = ?", [fixture.rubleOperation])))

    try stack.writer.write { db in
      try db.execute(
        sql: "DELETE FROM transactions WHERE id = ?", arguments: [fixture.dollarOperation])
    }
    #expect(
      try count("SELECT COUNT(*) FROM reconciliation_balances WHERE transaction_id IS NULL") == 2)
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM payment_methods WHERE id = 'lonely'")
    }
    #expect(try count("SELECT COUNT(*) FROM reconciliation_balances") == 1)
    #expect(
      try count("SELECT COUNT(*) FROM debt_entries WHERE id = 'line' AND payment_method_id IS NULL")
        == 1)
    try stack.writer.write { db in
      try db.execute(
        sql: "INSERT INTO payment_methods (id, name, group_id) VALUES ('filed', 'F', 'g')")
      try db.execute(sql: "DELETE FROM account_groups WHERE id = 'g'")
    }
    #expect(
      try count("SELECT COUNT(*) FROM payment_methods WHERE id = 'filed' AND group_id IS NULL") == 1
    )
    try stack.writer.write { db in try db.execute(sql: "DELETE FROM reconciliations WHERE id = 'r'")
    }
    #expect(try count("SELECT COUNT(*) FROM reconciliation_balances") == 0)
    #expect(try count("SELECT COUNT(*) FROM transfers") == 1)
    #expect(
      try stack.writer.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") }.isEmpty)
  }
}
