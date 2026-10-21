import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// What the update to 1.2 brought into the schema refuses exactly what it promises to: every
/// check of the cards, the cashback, the counts and the plans refuses a bad value and takes a
/// good one; one rule per holder, month and category; a card named by a row is always a card of
/// that row's own account, whoever writes it; and the keys hold, cascade or let go as they say.
@Suite("The checks of the cards refuse exactly what they promise")
struct Schema0005CheckTests {
  private struct Fixture {
    var stack: DatabaseStack
    /// Two accounts, each with a card.
    var tbank: String
    var sber: String
    var black: String
    var sberCard: String
    var category: String
    var event: String
    var goal: String
    var debt: String
  }

  private func fixture() throws -> Fixture {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let sber = PaymentMethod(name: "Сбер", kind: .card, currency: .rub)
    try ReferenceRepository(writer: stack.writer).save(sber)
    let tbank = references.paymentMethod.id.uuidString
    let black = UUID().uuidString
    let sberCard = UUID().uuidString
    try stack.writer.write { db in
      try db.execute(
        sql:
          "INSERT INTO cards (id, payment_method_id, name) VALUES (?, ?, 'Black'), (?, ?, 'Сбер')",
        arguments: [black, tbank, sberCard, sber.id.uuidString])
    }
    return Fixture(
      stack: stack, tbank: tbank, sber: sber.id.uuidString, black: black, sberCard: sberCard,
      category: references.category.id.uuidString, event: references.event.id.uuidString,
      goal: references.goal.id.uuidString, debt: references.debt.id.uuidString)
  }

  /// What SQLite says of the statement — taken, or refused with the message of a check or a
  /// trigger; nothing of it stays either way.
  private enum Verdict: Equatable {
    case taken
    case refused(String)
  }

  private func verdict(
    _ stack: DatabaseStack, _ sql: String, _ arguments: StatementArguments = []
  ) throws -> Verdict {
    var result = Verdict.taken
    try stack.writer.writeWithoutTransaction { db in
      try db.inSavepoint {
        do {
          try db.execute(sql: sql, arguments: arguments)
        } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
          result = .refused(error.message ?? "")
        }
        return .rollback
      }
    }
    return result
  }

  private func takes(
    _ stack: DatabaseStack, _ sql: String, _ arguments: StatementArguments = []
  ) throws -> Bool {
    try verdict(stack, sql, arguments) == .taken
  }

  /// An operation written straight into SQLite, and its id.
  private func insertOperation(
    account: String?, card: String?, cashback: (String?, Int64?) = (nil, nil)
  ) -> (sql: String, arguments: StatementArguments, id: String) {
    let id = UUID().uuidString
    return (
      """
      INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
        payment_method_id, created_at, updated_at, card_id, cashback_currency, cashback_e4)
      VALUES (?, 'expense', '2026-09-01 10:00:00.000', 'RUB', 10000, 10000, ?,
        '2026-09-01 10:00:00.000', '2026-09-01 10:00:00.000', ?, ?, ?)
      """,
      [id, account, card, cashback.0, cashback.1], id
    )
  }

  // MARK: Every check

  @Test func aCardNeedsANameAndAnAccount() throws {
    let f = try fixture()
    let sql = "INSERT INTO cards (id, payment_method_id, name, archived) VALUES (?, ?, ?, ?)"
    #expect(try takes(f.stack, sql, [UUID().uuidString, f.tbank, "Virtual", 0]))
    #expect(try takes(f.stack, sql, [UUID().uuidString, f.tbank, " Virtual ", 1]))
    #expect(try !takes(f.stack, sql, [UUID().uuidString, f.tbank, "   ", 0]))
    #expect(try !takes(f.stack, sql, [UUID().uuidString, f.tbank, "", 0]))
    #expect(try !takes(f.stack, sql, [UUID().uuidString, f.tbank, "Virtual", 2]))
    #expect(try !takes(f.stack, sql, [UUID().uuidString, UUID().uuidString, "Virtual", 0]))
    #expect(try !takes(f.stack, sql, [UUID().uuidString, nil, "Virtual", 0]))
  }

  @Test func aPercentIsFromZeroToAHundred() throws {
    let f = try fixture()
    let sql =
      "INSERT INTO cashback_rules (id, payment_method_id, card_id, percent_e4) VALUES (?, ?, ?, ?)"
    for (percent, taken) in [
      (Int64(-1), false), (0, true), (15_000, true), (1_000_000, true), (1_000_001, false),
    ] {
      #expect(
        try takes(f.stack, sql, [UUID().uuidString, f.tbank, f.black, percent]) == taken,
        "\(percent)")
    }
    #expect(try !takes(f.stack, sql, [UUID().uuidString, f.tbank, f.black, nil]))
  }

  @Test func aMonthIsYearDashMonth() throws {
    let f = try fixture()
    let sql = """
      INSERT INTO cashback_rules (id, payment_method_id, card_id, month, percent_e4)
      VALUES (?, ?, ?, ?, 10000)
      """
    for (month, taken) in [
      (String?.none, true), ("2026-09", true), ("2026-12", true), ("2026-9", false),
      ("26-09", false), ("2026-09-01", false), ("сент", false), ("", false),
    ] {
      #expect(
        try takes(f.stack, sql, [UUID().uuidString, f.tbank, f.black, month]) == taken,
        "\(month ?? "NULL")")
    }
  }

  @Test func theCashbackOfAnOperationIsACurrencyAndAnAmountTogether() throws {
    let f = try fixture()
    for (currency, amount, taken) in [
      (String?.none, Int64?.none, true), ("RUB", 450_000, true), ("RUB", 0, true),
      ("USD", 12_345, true), (nil, 450_000, false), ("RUB", nil, false), ("RUB", -1, false),
      ("rub", 450_000, false), ("RU", 450_000, false), ("RUBL", 450_000, false),
      ("R1B", 450_000, false),
    ] {
      let (sql, arguments, _) = insertOperation(
        account: f.tbank, card: nil, cashback: (currency, amount))
      #expect(
        try takes(f.stack, sql, arguments) == taken,
        "\(currency ?? "NULL") \(amount.map(String.init) ?? "NULL")")
    }
  }

  /// A count records its difference only when it compares: a starting point has nothing to
  /// record. The origin is a word of an opening only.
  @Test func aModeOnlyOnACountThatComparesAndAnOriginOnlyOnAnOpening() throws {
    let f = try fixture()
    let at = "2026-09-01 10:00:00.000"
    let sheet = UUID().uuidString
    let opening = UUID().uuidString
    try f.stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO reconciliations (id, date, actual_total_rub_e4, reconciled_at, kind)
          VALUES (?, '2026-09-01', 0, ?, 'accounts'), (?, '2026-08-31', 0, ?, 'opening')
          """,
        arguments: [sheet, at, opening, at])
    }
    let count = """
      INSERT INTO reconciliation_balances (id, reconciliation_id, payment_method_id, currency,
        actual_e4, expected_e4, difference_e4, records_difference)
      VALUES (?, ?, ?, 'RUB', 100, ?, ?, ?)
      """
    for (expected, difference, mode, taken) in [
      (Int64?.none, Int64?.none, Int64?.none, true), (nil, nil, 1, false), (nil, nil, 0, false),
      (100, 0, 1, true), (150, -50, 0, true), (100, 0, nil, true), (100, 0, 2, false),
      (100, 0, -1, false),
    ] {
      #expect(
        try takes(f.stack, count, [UUID().uuidString, sheet, f.tbank, expected, difference, mode])
          == taken,
        "expected \(expected.map(String.init) ?? "NULL"), mode \(mode.map(String.init) ?? "NULL")")
    }

    let origin = """
      INSERT INTO reconciliations (id, date, actual_total_rub_e4, reconciled_at, kind, origin)
      VALUES (?, '2026-09-02', 0, ?, ?, ?)
      """
    for (kind, value, taken) in [
      ("opening", String?.none, true), ("opening", "setup", true), ("opening", "account", true),
      ("opening", "merge", true), ("opening", "other", false), ("opening", "Setup", false),
      ("accounts", "setup", false), ("total", "merge", false), ("accounts", nil, true),
    ] {
      #expect(
        try takes(f.stack, origin, [UUID().uuidString, at, kind, value]) == taken,
        "\(kind) \(value ?? "NULL")")
    }
  }

  @Test func thePlanOfAGoalStartsInAMonth() throws {
    let f = try fixture()
    let sql = "UPDATE goals SET plan_start_month = ? WHERE id = ?"
    for (month, taken) in [
      (String?.none, true), ("2026-09", true), ("26-09", false), ("2026-9", false),
      ("2026-09-01", false), ("September", false),
    ] {
      #expect(try takes(f.stack, sql, [month, f.goal]) == taken, "\(month ?? "NULL")")
    }
  }

  // MARK: One rule per key

  /// Two rules of one card, one month and one category are one too many; the same rule on
  /// another card, in another month or for another category is another rule. An account's own
  /// rules (no card) follow the same key.
  @Test func oneRulePerHolderMonthAndCategory() throws {
    let f = try fixture()
    let insert = """
      INSERT INTO cashback_rules (id, payment_method_id, card_id, category_id, month, percent_e4)
      VALUES (?, ?, ?, ?, ?, ?)
      """
    func add(
      _ account: String, _ card: String?, _ category: String?, _ month: String?
    ) throws
      -> Bool
    {
      var taken = false
      try f.stack.writer.write { db in
        do {
          try db.execute(
            sql: insert,
            arguments: [UUID().uuidString, account, card, category, month, 10_000])
          taken = true
        } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
          taken = false
        }
      }
      return taken
    }
    // «Всегда · всё остальное» once per card.
    #expect(try add(f.tbank, f.black, nil, nil))
    #expect(try !add(f.tbank, f.black, nil, nil))
    #expect(try add(f.sber, f.sberCard, nil, nil))
    // Another month, another category: other rules.
    #expect(try add(f.tbank, f.black, nil, "2026-09"))
    #expect(try !add(f.tbank, f.black, nil, "2026-09"))
    #expect(try add(f.tbank, f.black, f.category, nil))
    #expect(try add(f.tbank, f.black, f.category, "2026-09"))
    #expect(try !add(f.tbank, f.black, f.category, "2026-09"))
    // The account's own rule is not the card's.
    #expect(try add(f.tbank, nil, nil, nil))
    #expect(try !add(f.tbank, nil, nil, nil))
    #expect(try add(f.tbank, nil, f.category, nil))
    #expect(try !add(f.tbank, nil, f.category, nil))
  }

  // MARK: The six triggers

  @Test func anOperationNamesOnlyACardOfItsOwnAccount() throws {
    let f = try fixture()
    let (own, ownArguments, _) = insertOperation(account: f.tbank, card: f.black)
    #expect(try verdict(f.stack, own, ownArguments) == .taken)
    let (other, otherArguments, _) = insertOperation(account: f.sber, card: f.black)
    #expect(try verdict(f.stack, other, otherArguments) == .refused("card_of_another_account"))
    let (none, noneArguments, _) = insertOperation(account: nil, card: f.black)
    #expect(try verdict(f.stack, none, noneArguments) == .refused("card_of_another_account"))
    let (missing, missingArguments, _) = insertOperation(
      account: f.tbank, card: UUID().uuidString)
    #expect(try verdict(f.stack, missing, missingArguments) != .taken)

    // Updated: the card to one of another account, or the account from under its card.
    let (sql, arguments, id) = insertOperation(account: f.tbank, card: f.black)
    try f.stack.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    #expect(
      try verdict(f.stack, "UPDATE transactions SET card_id = ? WHERE id = ?", [f.sberCard, id])
        == .refused("card_of_another_account"))
    #expect(
      try verdict(
        f.stack, "UPDATE transactions SET payment_method_id = ? WHERE id = ?", [f.sber, id])
        == .refused("card_of_another_account"))
    #expect(
      try verdict(
        f.stack, "UPDATE transactions SET payment_method_id = NULL WHERE id = ?", [id])
        == .refused("card_of_another_account"))
    // Both together, to the other account and its card; or the card let go: taken.
    #expect(
      try verdict(
        f.stack, "UPDATE transactions SET payment_method_id = ?, card_id = ? WHERE id = ?",
        [f.sber, f.sberCard, id]) == .taken)
    #expect(
      try verdict(
        f.stack, "UPDATE transactions SET payment_method_id = ?, card_id = NULL WHERE id = ?",
        [f.sber, id]) == .taken)
    // Any other column moves freely.
    #expect(
      try verdict(f.stack, "UPDATE transactions SET note = 'coffee' WHERE id = ?", [id]) == .taken)
  }

  @Test func aScheduledPaymentNamesOnlyACardOfItsOwnAccount() throws {
    let f = try fixture()
    let insert = """
      INSERT INTO scheduled_payments (id, name, kind, amount_e4, currency, payment_method_id,
        freq, card_id)
      VALUES (?, 'Rent', 'bill', 10000, 'RUB', ?, 'monthly', ?)
      """
    let id = UUID().uuidString
    #expect(try verdict(f.stack, insert, [id, f.tbank, f.black]) == .taken)
    #expect(
      try verdict(f.stack, insert, [UUID().uuidString, f.sber, f.black])
        == .refused("card_of_another_account"))
    #expect(
      try verdict(f.stack, insert, [UUID().uuidString, nil, f.black])
        == .refused("card_of_another_account"))
    try f.stack.writer.write { db in
      try db.execute(sql: insert, arguments: [id, f.tbank, f.black])
    }
    #expect(
      try verdict(
        f.stack, "UPDATE scheduled_payments SET card_id = ? WHERE id = ?", [f.sberCard, id])
        == .refused("card_of_another_account"))
    #expect(
      try verdict(
        f.stack, "UPDATE scheduled_payments SET payment_method_id = ? WHERE id = ?", [f.sber, id])
        == .refused("card_of_another_account"))
    #expect(
      try verdict(f.stack, "UPDATE scheduled_payments SET name = 'Flat' WHERE id = ?", [id])
        == .taken)
  }

  @Test func aRuleNamesOnlyACardOfItsOwnAccount() throws {
    let f = try fixture()
    let insert = """
      INSERT INTO cashback_rules (id, payment_method_id, card_id, percent_e4)
      VALUES (?, ?, ?, 10000)
      """
    let id = UUID().uuidString
    #expect(try verdict(f.stack, insert, [id, f.tbank, f.black]) == .taken)
    #expect(
      try verdict(f.stack, insert, [UUID().uuidString, f.sber, f.black])
        == .refused("card_of_another_account"))
    try f.stack.writer.write { db in try db.execute(sql: insert, arguments: [id, f.tbank, f.black])
    }
    #expect(
      try verdict(f.stack, "UPDATE cashback_rules SET card_id = ? WHERE id = ?", [f.sberCard, id])
        == .refused("card_of_another_account"))
    #expect(
      try verdict(
        f.stack, "UPDATE cashback_rules SET payment_method_id = ? WHERE id = ?", [f.sber, id])
        == .refused("card_of_another_account"))
    #expect(
      try verdict(f.stack, "UPDATE cashback_rules SET percent_e4 = 5000 WHERE id = ?", [id])
        == .taken)
  }

  /// The six triggers of the cards are in the schema, by name, and the three of the main card
  /// of an account that came later.
  @Test func theSixTriggersAreThere() throws {
    let stack = try TestSupport.makeStack()
    let triggers = try stack.writer.read { db in
      try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'")
    }
    #expect(
      triggers == [
        "card_of_account_transactions_insert", "card_of_account_transactions_update",
        "card_of_account_scheduled_insert", "card_of_account_scheduled_update",
        "card_of_account_cashback_insert", "card_of_account_cashback_update",
        "main_card_of_account_insert", "main_card_of_account_update", "main_card_follows_card",
      ])
  }

  /// A merge of two accounts moves the cards first and the rows that name them after: then every
  /// row it moves names a card of its new account. The other way round the first row moved names
  /// a card still on the account it left, and the merge stops — so the order is what makes it.
  @Test func aMergeMovesCardsBeforeTheirOperations() throws {
    let f = try fixture()
    let (sql, arguments, _) = insertOperation(account: f.tbank, card: f.black)
    try f.stack.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    func repoint(_ columns: [(String, String)]) throws -> Verdict {
      var result = Verdict.taken
      try f.stack.writer.writeWithoutTransaction { db in
        try db.inSavepoint {
          do {
            for (table, column) in columns {
              try db.execute(
                sql: "UPDATE \(table) SET \(column) = ? WHERE \(column) = ?",
                arguments: [f.sber, f.tbank])
            }
          } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            result = .refused(error.message ?? "")
          }
          return .rollback
        }
      }
      return result
    }
    let cardsFirst = [
      ("cards", "payment_method_id"), ("transactions", "payment_method_id"),
      ("cashback_rules", "payment_method_id"),
    ]
    #expect(try repoint(cardsFirst) == .taken)
    #expect(try repoint(cardsFirst.reversed()) == .refused("card_of_another_account"))
  }

  // MARK: The keys

  @Test func theKeysHoldCascadeOrLetGoAsTheySay() throws {
    let f = try fixture()
    let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try ReferenceRepository(writer: f.stack.writer).save(cash)
    let doomed = PaymentMethod(name: "Closed card", kind: .card, currency: .rub)
    try ReferenceRepository(writer: f.stack.writer).save(doomed)
    let doomedCard = UUID().uuidString
    let payment = UUID().uuidString
    let expectation = UUID().uuidString
    try f.stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO cards (id, payment_method_id, name) VALUES (?, ?, 'Closed');
          INSERT INTO cashback_rules (id, payment_method_id, card_id, percent_e4)
            VALUES (?, ?, ?, 10000), (?, ?, NULL, 20000);
          INSERT INTO cashback_rules (id, payment_method_id, card_id, category_id, percent_e4)
            VALUES (?, ?, ?, ?, 30000);
          INSERT INTO scheduled_payments (id, name, kind, amount_e4, currency, payment_method_id,
            freq, event_id) VALUES (?, 'Tickets', 'bill', 10000, 'RUB', ?, 'monthly', ?);
          INSERT INTO expected_income (id, name, kind, total_e4, currency, payment_method_id)
            VALUES (?, 'Salary', 'one_off', 10000, 'RUB', ?);
          """,
        arguments: [
          doomedCard, doomed.id.uuidString,
          UUID().uuidString, doomed.id.uuidString, doomedCard, UUID().uuidString,
          cash.id.uuidString,
          UUID().uuidString, f.tbank, f.black, f.category,
          payment, f.tbank, f.event,
          expectation, doomed.id.uuidString,
        ])
    }
    func count(_ sql: String, _ arguments: StatementArguments = []) throws -> Int {
      try f.stack.writer.read { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    // A card an operation names cannot go.
    let (sql, arguments, _) = insertOperation(account: f.tbank, card: f.black)
    try f.stack.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    #expect(try !takes(f.stack, "DELETE FROM cards WHERE id = ?", [f.black]))
    // An account deleted takes its cards and every rule on it; its expectation lets it go.
    try f.stack.writer.write { db in
      try db.execute(
        sql: "DELETE FROM payment_methods WHERE id = ?", arguments: [doomed.id.uuidString])
    }
    #expect(try count("SELECT COUNT(*) FROM cards WHERE id = ?", [doomedCard]) == 0)
    #expect(
      try count(
        "SELECT COUNT(*) FROM cashback_rules WHERE payment_method_id = ?", [doomed.id.uuidString])
        == 0)
    #expect(
      try count(
        "SELECT COUNT(*) FROM expected_income WHERE id = ? AND payment_method_id IS NULL",
        [expectation]) == 1)
    // A category deleted takes its rules.
    try f.stack.writer.write { db in
      try db.execute(sql: "DELETE FROM categories WHERE id = ?", arguments: [f.category])
    }
    #expect(try count("SELECT COUNT(*) FROM cashback_rules WHERE category_id IS NOT NULL") == 0)
    // An event deleted lets its payments go.
    try f.stack.writer.write { db in
      try db.execute(sql: "DELETE FROM events WHERE id = ?", arguments: [f.event])
    }
    #expect(
      try count(
        "SELECT COUNT(*) FROM scheduled_payments WHERE id = ? AND event_id IS NULL", [payment])
        == 1)
    #expect(
      try f.stack.writer.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") }
        .isEmpty)
  }

  // MARK: The records

  /// Every new column is written and read back by its record as it was.
  @Test func theRecordsRoundTripEveryNewColumn() throws {
    let f = try fixture()
    let tbank = try #require(UUID(uuidString: f.tbank))
    let black = try #require(UUID(uuidString: f.black))
    let card = PaymentCard(
      accountId: tbank, name: "Virtual", aliases: ["виртуалка", "virt"], sort: 3, archived: true)
    let rules = [
      CashbackRule(
        accountId: tbank, cardId: black, categoryId: UUID(uuidString: f.category),
        month: MonthKey(year: 2026, month: 9), percent: try #require(CashbackPercent(e4: 15_000))),
      CashbackRule(accountId: tbank, percent: .zero),
    ]
    let operation = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
      amountE4: AmountE4(whole: 350), paymentMethodId: tbank,
      createdAt: Date(timeIntervalSince1970: 1_790_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_790_000_000), cardId: black,
      cashback: Money(amount: AmountE4(whole: 35), currency: .rub))
    let payment = ScheduledPayment(
      name: "Netflix", amountE4: AmountE4(whole: 999), paymentMethodId: tbank, cardId: black,
      eventId: UUID(uuidString: f.event))
    let expectation = ExpectedIncome(
      name: "Salary", totalE4: AmountE4(whole: 100_000), paymentMethodId: tbank)
    let goal = Goal(
      name: "Trip", targetE4: AmountE4(whole: 1_000), monthlyPlanE4: AmountE4(whole: 100),
      planStartMonth: MonthKey(year: 2026, month: 10))
    let debt = Debt(
      direction: .iOwe, type: .personal, name: "Gone",
      deletedAt: Date(timeIntervalSince1970: 1_790_001_234.5))
    let opening = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 1),
      reconciledAt: Date(timeIntervalSince1970: 1_790_000_000), actualTotalRubE4: .zero,
      kind: .opening, origin: .merge)
    let count = ReconciledBalance(
      reconciliationId: opening.id, accountId: tbank, currency: .rub,
      actualE4: AmountE4(whole: 10), expectedE4: AmountE4(whole: 10), differenceE4: .zero,
      recordsDifference: false)
    try f.stack.writer.write { db in
      try card.insert(db)
      for rule in rules { try rule.insert(db) }
      try operation.insert(db)
      try payment.insert(db)
      try expectation.insert(db)
      try goal.insert(db)
      try debt.insert(db)
      try opening.insert(db)
      try count.insert(db)
    }
    try f.stack.writer.read { (db: Database) throws in
      #expect(try PaymentCard.fetchOne(db, key: card.id.uuidString) == card)
      #expect(try CashbackRule.fetchOne(db, key: rules[0].id.uuidString) == rules[0])
      #expect(try CashbackRule.fetchOne(db, key: rules[1].id.uuidString) == rules[1])
      #expect(try CoreKit.Transaction.fetchOne(db, key: operation.id.uuidString) == operation)
      #expect(try ScheduledPayment.fetchOne(db, key: payment.id.uuidString) == payment)
      #expect(try ExpectedIncome.fetchOne(db, key: expectation.id.uuidString) == expectation)
      #expect(try Goal.fetchOne(db, key: goal.id.uuidString) == goal)
      let readDebt = try #require(try Debt.fetchOne(db, key: debt.id.uuidString))
      #expect(readDebt == debt)
      #expect(readDebt.isDeleted)
      #expect(try Reconciliation.fetchOne(db, key: opening.id.uuidString) == opening)
      #expect(try ReconciledBalance.fetchOne(db, key: count.id.uuidString) == count)
      #expect(
        try String.fetchOne(
          db, sql: "SELECT percent_e4 || ' ' || month FROM cashback_rules WHERE id = ?",
          arguments: [rules[0].id.uuidString]) == "15000 2026-09")
      #expect(
        try String.fetchOne(
          db, sql: "SELECT cashback_currency || ' ' || cashback_e4 FROM transactions WHERE id = ?",
          arguments: [operation.id.uuidString]) == "RUB 350000")
      #expect(
        try String.fetchOne(
          db, sql: "SELECT aliases FROM cards WHERE id = ?", arguments: [card.id.uuidString])
          == "виртуалка\nvirt")
    }
  }

  /// A value only a hand edit leaves reads as nothing, and never stops the read: a percent out
  /// of range reads as 0 %, a mode that is not 0 or 1 as none, an origin or a cashback half
  /// written as none.
  @Test func aValueOnlyAHandEditLeavesReadsAsNothing() throws {
    let f = try fixture()
    let sheet = UUID().uuidString
    let count = UUID().uuidString
    let rule = UUID().uuidString
    let (sql, arguments, operation) = insertOperation(account: f.tbank, card: nil)
    try f.stack.writer.write { db in
      try db.execute(sql: sql, arguments: arguments)
      try db.execute(
        sql: """
          INSERT INTO reconciliations (id, date, actual_total_rub_e4, reconciled_at, kind)
          VALUES (?, '2026-09-01', 0, '2026-09-01 10:00:00.000', 'opening');
          INSERT INTO reconciliation_balances (id, reconciliation_id, payment_method_id, currency,
            actual_e4, expected_e4, difference_e4) VALUES (?, ?, ?, 'RUB', 100, 100, 0);
          INSERT INTO cashback_rules (id, payment_method_id, card_id, percent_e4)
            VALUES (?, ?, ?, 10000);
          """,
        arguments: [sheet, count, sheet, f.tbank, rule, f.tbank, f.black])
    }
    try f.stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql: "UPDATE cashback_rules SET percent_e4 = 2000000 WHERE id = ?", arguments: [rule])
      try db.execute(
        sql: "UPDATE reconciliation_balances SET records_difference = 7 WHERE id = ?",
        arguments: [count])
      try db.execute(
        sql: "UPDATE reconciliations SET origin = 'import' WHERE id = ?", arguments: [sheet])
      try db.execute(
        sql: "UPDATE transactions SET cashback_e4 = 5 WHERE id = ?", arguments: [operation])
      try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
    }
    try f.stack.writer.read { (db: Database) throws in
      #expect(try CashbackRule.fetchOne(db, key: rule)?.percent == .zero)
      #expect(try ReconciledBalance.fetchOne(db, key: count)?.recordsDifference == nil)
      #expect(try Reconciliation.fetchOne(db, key: sheet)?.origin == nil)
      #expect(try CoreKit.Transaction.fetchOne(db, key: operation)?.cashback == nil)
    }
    try f.stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql: "UPDATE cashback_rules SET percent_e4 = 'much' WHERE id = ?", arguments: [rule])
      try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
    }
    #expect(
      try f.stack.writer.read { db in try CashbackRule.fetchOne(db, key: rule)?.percent } == .zero)
  }
}

/// The settings the update to 1.2 adds read and write as the settings table keeps them: the
/// valuation of goal money a word, the counts kept as real differences one id per line, the
/// answers about counts one line each; the categories of the reconciliation are read and never
/// written back.
@Suite("The new planning settings as the settings table keeps them")
struct PlanningSettingsStorageTests {
  @Test func theNewKeysRoundTrip() {
    let kept: Set<UUID> = [UUID(), UUID(), UUID()]
    let answers = [UUID(): true, UUID(): false]
    let settings = PlanningSettings(
      goalSavingsValuation: .deposits, firstCountKept: kept, beforeCountAnswers: answers)
    let stored = settings.storedValues
    #expect(stored[PlanningSettings.goalSavingsValuationKey] == .some("deposits"))
    let keptText = stored[PlanningSettings.firstCountKeptKey] ?? nil
    #expect(keptText == kept.map(\.uuidString).sorted().joined(separator: "\n"))
    let rows = stored.compactMapValues { $0 }
    let read = PlanningSettings(storedValues: rows)
    #expect(read == settings)
  }

  @Test func emptyListsDeleteTheirKeysAndTheValuationIsAlwaysWritten() {
    let stored = PlanningSettings().storedValues
    #expect(stored[PlanningSettings.goalSavingsValuationKey] == .some("today"))
    #expect(stored.keys.contains(PlanningSettings.firstCountKeptKey))
    #expect(stored[PlanningSettings.firstCountKeptKey] == .some(nil))
    #expect(stored[PlanningSettings.beforeCountAnswersKey] == .some(nil))
  }

  @Test func anUnknownValuationIsToday() {
    for text in ["", "yesterday", "DEPOSITS", "1"] {
      #expect(
        PlanningSettings(storedValues: [PlanningSettings.goalSavingsValuationKey: text])
          .goalSavingsValuation == .today, "\(text)")
    }
    #expect(
      PlanningSettings(storedValues: [PlanningSettings.goalSavingsValuationKey: " deposits "])
        .goalSavingsValuation == .deposits)
  }

  @Test func aLineThatIsNoIdIsSkipped() {
    let id = UUID()
    let read = PlanningSettings(storedValues: [
      PlanningSettings.firstCountKeptKey: "not an id\n \(id.uuidString) \n\n",
      PlanningSettings.beforeCountAnswersKey: "\(id.uuidString) before\nnonsense after",
    ])
    #expect(read.firstCountKept == [id])
    #expect(read.beforeCountAnswers == [id: true])
  }

  /// The categories of the reconciliation are read with the settings and never written by them:
  /// a screen writing back what it read could undo what the reconciliation chose meanwhile.
  @Test func theReconcileCategoriesAreReadNeverWritten() {
    let expense = UUID()
    let income = UUID()
    let read = PlanningSettings(storedValues: [
      PlanningSettings.reconcileExpenseCategoryKey: expense.uuidString,
      PlanningSettings.reconcileIncomeCategoryKey: " \(income.uuidString) ",
    ])
    #expect(read.reconcileExpenseCategoryId == expense)
    #expect(read.reconcileIncomeCategoryId == income)
    #expect(read.limitlessCategoryIds == [expense, income])
    #expect(!read.storedValues.keys.contains(PlanningSettings.reconcileExpenseCategoryKey))
    #expect(!read.storedValues.keys.contains(PlanningSettings.reconcileIncomeCategoryKey))
    #expect(!PlanningSettings.storageKeys.contains(PlanningSettings.reconcileExpenseCategoryKey))
    #expect(!PlanningSettings.storageKeys.contains(PlanningSettings.reconcileIncomeCategoryKey))
    #expect(PlanningSettings.readKeys.contains(PlanningSettings.reconcileExpenseCategoryKey))
    #expect(PlanningSettings.readKeys.contains(PlanningSettings.reconcileIncomeCategoryKey))
    #expect(Set(PlanningSettings.storageKeys).isSubset(of: PlanningSettings.readKeys))
    for key in [
      PlanningSettings.goalSavingsValuationKey, PlanningSettings.firstCountKeptKey,
      PlanningSettings.beforeCountAnswersKey,
    ] {
      #expect(PlanningSettings.storageKeys.contains(key))
    }
  }
}
