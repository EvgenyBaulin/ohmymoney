import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// What the credits and the allocation of income brought into the schema refuse exactly what
/// they promise to: every check takes a good value and refuses a bad one, the main card of an
/// account is always a card of that account, and the keys hold, cascade or let go as they say.
@Suite("The checks of the credits and the allocation refuse exactly what they promise")
struct Schema9ConstraintTests {
  private struct Fixture {
    var stack: DatabaseStack
    /// Two accounts, each with a card.
    var tbank = UUID().uuidString
    var sber = UUID().uuidString
    var black = UUID().uuidString
    var sberCard = UUID().uuidString
    /// A loan I owe, a purchase on credit I owe, a debt owed to me.
    var loan = UUID().uuidString
    var purchase = UUID().uuidString
    var lent = UUID().uuidString
    var payment = UUID().uuidString
    var borrowed = UUID().uuidString
    var goal = UUID().uuidString
    var income = UUID().uuidString
    var expense = UUID().uuidString
    var transfer = UUID().uuidString
  }

  private func fixture() throws -> Fixture {
    let ids = Fixture(stack: try TestSupport.makeStack())
    try ids.stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO payment_methods (id, name, kind) VALUES (?, 'Т-Банк', 'card'), (?, 'Сбер', 'card');
          INSERT INTO cards (id, payment_method_id, name) VALUES (?, ?, 'Black'), (?, ?, 'Сбер');
          INSERT INTO debts (id, direction, type, name, origin) VALUES
            (?, 'i_owe', 'loan', 'Кредит', 'existing'),
            (?, 'i_owe', 'installment', 'Телефон', 'purchase'),
            (?, 'owed_to_me', 'personal', 'Аня', 'existing');
          INSERT INTO debt_entries (id, debt_id, amount_e4, kind) VALUES
            (?, ?, -10000, 'payment'), (?, ?, 100000, 'borrowed');
          INSERT INTO goals (id, name, target_e4) VALUES (?, 'Отпуск', 1000000000);
          INSERT INTO categories (id, kind, name) VALUES (?, 'income', 'Заработок'),
            (?, 'expense', 'Еда');
          INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
            from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at,
            updated_at)
          VALUES (?, '2026-10-01 10:00:00.000', ?, 'RUB', 10000, ?, 'RUB', 10000,
            '2026-10-01 10:00:00.000', '2026-10-01 10:00:00.000');
          """,
        arguments: [
          ids.tbank, ids.sber, ids.black, ids.tbank, ids.sberCard, ids.sber, ids.loan,
          ids.purchase, ids.lent, ids.payment, ids.loan, ids.borrowed, ids.loan, ids.goal,
          ids.income, ids.expense, ids.transfer, ids.tbank, ids.sber,
        ])
    }
    return ids
  }

  /// Whether SQLite takes the statement; nothing of it stays either way.
  private func takes(
    _ stack: DatabaseStack, _ sql: String, _ arguments: StatementArguments = []
  ) throws -> Bool {
    var taken = true
    try stack.writer.writeWithoutTransaction { db in
      try db.inSavepoint {
        do {
          try db.execute(sql: sql, arguments: arguments)
        } catch let error as GRDB.DatabaseError
          where error.resultCode == .SQLITE_CONSTRAINT || error.resultCode == .SQLITE_ERROR
        {
          taken = false
        }
        return .rollback
      }
    }
    return taken
  }

  /// Each statement of `good` is taken, each of `bad` refused.
  private func expect(
    _ stack: DatabaseStack, good: [String], bad: [String], _ arguments: StatementArguments,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    for sql in good {
      #expect(try takes(stack, sql, arguments), "refused: \(sql)", sourceLocation: sourceLocation)
    }
    for sql in bad {
      #expect(!(try takes(stack, sql, arguments)), "taken: \(sql)", sourceLocation: sourceLocation)
    }
  }

  // MARK: Debts

  @Test func stepsGoWithTheirFirstDay() throws {
    let f = try fixture()
    try expect(
      f.stack,
      good: [
        "UPDATE debts SET step_days = 14, first_due_on = '2026-10-12' WHERE id = :loan",
        "UPDATE debts SET step_days = 1, first_due_on = '2026-10-12' WHERE id = :lent",
        "UPDATE debts SET step_days = 366, first_due_on = '2026-10-12' WHERE id = :loan",
      ],
      bad: [
        "UPDATE debts SET step_days = 14 WHERE id = :loan",
        "UPDATE debts SET first_due_on = '2026-10-12' WHERE id = :loan",
        "UPDATE debts SET step_days = 0, first_due_on = '2026-10-12' WHERE id = :loan",
        "UPDATE debts SET step_days = 367, first_due_on = '2026-10-12' WHERE id = :loan",
      ], ["loan": f.loan, "lent": f.lent])
  }

  @Test func partsAndAMarkupOnlyOnAPurchaseIOwe() throws {
    let f = try fixture()
    try expect(
      f.stack,
      good: [
        "UPDATE debts SET parts = 4 WHERE id = :purchase",
        "UPDATE debts SET parts = 120, markup_e4 = 6000000 WHERE id = :purchase",
        "UPDATE debts SET parts = 2 WHERE id = :purchase",
      ],
      bad: [
        "UPDATE debts SET parts = 1 WHERE id = :purchase",
        "UPDATE debts SET parts = 121 WHERE id = :purchase",
        "UPDATE debts SET parts = 4 WHERE id = :loan",
        "UPDATE debts SET parts = 4 WHERE id = :lent",
        "UPDATE debts SET markup_e4 = 6000000 WHERE id = :purchase",
        "UPDATE debts SET parts = 4, markup_e4 = 0 WHERE id = :purchase",
      ], ["purchase": f.purchase, "loan": f.loan, "lent": f.lent])
  }

  @Test func theTermsOfEarlyRepaymentAndTheLadderOnlyOnADebtIOwe() throws {
    let f = try fixture()
    try expect(
      f.stack,
      good: [
        "UPDATE debts SET psk = '21.473' WHERE id = :loan",
        "UPDATE debts SET prepay_any_day = 0 WHERE id = :loan",
        "UPDATE debts SET prepay_notice_days = 0 WHERE id = :loan",
        "UPDATE debts SET prepay_notice_days = 90 WHERE id = :loan",
        """
        UPDATE debts SET planned_prepay_on = '2026-12-01', planned_prepay_e4 = 10000
        WHERE id = :loan
        """,
        "UPDATE debts SET in_ladder = 0 WHERE id = :loan",
        "UPDATE debts SET in_ladder = 1 WHERE id = :purchase",
        "UPDATE debts SET terms_reviewed = 1 WHERE id = :lent",
      ],
      bad: [
        "UPDATE debts SET psk = ' ' WHERE id = :loan",
        "UPDATE debts SET psk = '12' WHERE id = :lent",
        "UPDATE debts SET prepay_any_day = 2 WHERE id = :loan",
        "UPDATE debts SET prepay_any_day = NULL WHERE id = :loan",
        "UPDATE debts SET prepay_notice_days = 91 WHERE id = :loan",
        "UPDATE debts SET prepay_notice_days = -1 WHERE id = :loan",
        "UPDATE debts SET planned_prepay_on = '2026-12-01' WHERE id = :loan",
        "UPDATE debts SET planned_prepay_e4 = 10000 WHERE id = :loan",
        """
        UPDATE debts SET planned_prepay_on = '2026-12-01', planned_prepay_e4 = 0
        WHERE id = :loan
        """,
        """
        UPDATE debts SET planned_prepay_on = '2026-12-01', planned_prepay_e4 = 10000
        WHERE id = :lent
        """,
        "UPDATE debts SET in_ladder = 2 WHERE id = :loan",
        "UPDATE debts SET in_ladder = 1 WHERE id = :lent",
        "UPDATE debts SET terms_reviewed = 2 WHERE id = :lent",
        "UPDATE debts SET terms_reviewed = NULL WHERE id = :lent",
      ], ["loan": f.loan, "purchase": f.purchase, "lent": f.lent])
  }

  @Test func aPledgeIsOwedToMe() throws {
    let f = try fixture()
    try expect(
      f.stack,
      good: [
        "UPDATE debts SET pledge = 1, return_by = '2027-01-31' WHERE id = :lent",
        "UPDATE debts SET return_by = '2027-01-31' WHERE id = :lent",
      ],
      bad: [
        "UPDATE debts SET pledge = 1 WHERE id = :loan",
        "UPDATE debts SET pledge = 2 WHERE id = :lent",
        "UPDATE debts SET pledge = NULL WHERE id = :lent",
        "UPDATE debts SET return_by = '2027-01-31' WHERE id = :loan",
      ], ["loan": f.loan, "lent": f.lent])
  }

  @Test func anEarlyRepaymentIsAPaymentThatSaysWhatItDoes() throws {
    let f = try fixture()
    try expect(
      f.stack,
      good: [
        "UPDATE debt_entries SET prepay = 'term' WHERE id = :payment",
        "UPDATE debt_entries SET prepay = 'payment' WHERE id = :payment",
      ],
      bad: [
        "UPDATE debt_entries SET prepay = 'term' WHERE id = :borrowed",
        "UPDATE debt_entries SET prepay = 'sooner' WHERE id = :payment",
      ], ["payment": f.payment, "borrowed": f.borrowed])
  }

  @Test func theSumsOfDuesAreOnePerIndexAndGoWithTheDebt() throws {
    let f = try fixture()
    let insert =
      "INSERT INTO debt_instalments (id, debt_id, from_index, amount_e4) VALUES (?, ?, ?, ?)"
    #expect(try takes(f.stack, insert, [UUID().uuidString, f.loan, 0, 0]))
    #expect(try takes(f.stack, insert, [UUID().uuidString, f.loan, 5, 2_650_000]))
    #expect(!(try takes(f.stack, insert, [UUID().uuidString, f.loan, -1, 100])))
    #expect(!(try takes(f.stack, insert, [UUID().uuidString, f.loan, 0, -1])))
    #expect(!(try takes(f.stack, insert, [UUID().uuidString, UUID().uuidString, 0, 100])))
    try f.stack.writer.write { db in
      try db.execute(sql: insert, arguments: [UUID().uuidString, f.loan, 0, 100])
      try db.execute(sql: insert, arguments: [UUID().uuidString, f.purchase, 0, 100])
    }
    #expect(!(try takes(f.stack, insert, [UUID().uuidString, f.loan, 0, 200])))
    try f.stack.writer.write { db in
      try db.execute(sql: "DELETE FROM debt_entries WHERE debt_id = ?", arguments: [f.loan])
      try db.execute(sql: "DELETE FROM debts WHERE id = ?", arguments: [f.loan])
    }
    try f.stack.writer.read { (db: Database) throws in
      #expect(try String.fetchAll(db, sql: "SELECT debt_id FROM debt_instalments") == [f.purchase])
    }
  }

  @Test func aCostOfALoan() throws {
    let f = try fixture()
    let insert = """
      INSERT INTO debt_costs (id, debt_id, kind, amount_e4, every, day, in_loan)
      VALUES (?, ?, ?, ?, ?, '2026-10-01', ?)
      """
    for (kind, amount, every, inLoan) in [
      ("fee", 10, "once", 1), ("insurance", 10, "monthly", 0), ("other", 10, "yearly", 0),
    ] {
      #expect(try takes(f.stack, insert, [UUID().uuidString, f.loan, kind, amount, every, inLoan]))
    }
    for (kind, amount, every, inLoan) in [
      ("tax", 10, "once", 0), ("fee", 0, "once", 0), ("fee", -5, "once", 0),
      ("fee", 10, "weekly", 0), ("fee", 10, "monthly", 1), ("fee", 10, "once", 2),
    ] {
      #expect(
        !(try takes(f.stack, insert, [UUID().uuidString, f.loan, kind, amount, every, inLoan])),
        "\(kind) \(amount) \(every) \(inLoan)")
    }
    #expect(
      !(try takes(
        f.stack, "INSERT INTO debt_costs (id, debt_id, kind, amount_e4) VALUES (?, ?, 'fee', 10)",
        [UUID().uuidString, f.loan])), "a cost has a day")
  }

  // MARK: Accounts

  @Test func theTermsOfACreditCardGoWithItsLimit() throws {
    let f = try fixture()
    let statement = """
      credit_limit_e4 = 1500000000, credit_grace = 'statement', credit_statement_day = 5,
      credit_pay_days = 25
      """
    let purchase =
      "credit_limit_e4 = 1500000000, credit_grace = 'purchase', credit_grace_days = 100"
    func update(_ set: String) -> String { "UPDATE payment_methods SET \(set) WHERE id = :tbank" }
    try expect(
      f.stack,
      good: [
        update(statement),
        update(purchase),
        update(statement.replacingOccurrences(of: "= 5,", with: "= 31,")),
        update(
          statement + """
            , credit_purchase_rate = '29.9', credit_cash_rate = '49.9',
            credit_min_percent = '8', credit_min_floor_e4 = 6000000,
            credit_cash_fee_percent = '2.9', credit_cash_fee_fixed_e4 = 2900000,
            credit_cash_no_grace = 1
            """),
        update(statement + ", credit_min_floor_e4 = 0, credit_cash_fee_fixed_e4 = 0"),
      ],
      bad: [
        update("credit_limit_e4 = 1500000000"),
        update("credit_grace = 'statement', credit_statement_day = 5, credit_pay_days = 25"),
        update(statement.replacingOccurrences(of: "1500000000", with: "0")),
        update("credit_limit_e4 = 1500000000, credit_grace = 'statement'"),
        update("credit_limit_e4 = 1500000000, credit_grace = 'statement', credit_pay_days = 25"),
        update(statement + ", credit_grace_days = 100"),
        update(purchase + ", credit_statement_day = 5"),
        update(purchase + ", credit_pay_days = 25"),
        update("credit_limit_e4 = 1500000000, credit_grace = 'purchase'"),
        update("credit_limit_e4 = 1500000000, credit_grace = 'monthly', credit_grace_days = 10"),
        update(statement.replacingOccurrences(of: "= 5,", with: "= 32,")),
        update(statement.replacingOccurrences(of: "= 25", with: "= 61")),
        update(purchase.replacingOccurrences(of: "100", with: "0")),
        update("credit_purchase_rate = '29.9'"),
        update(statement + ", credit_purchase_rate = ' '"),
        update("credit_cash_rate = '49.9'"),
        update("credit_min_percent = '8'"),
        update(statement + ", credit_min_floor_e4 = -1"),
        update("credit_min_floor_e4 = 100"),
        update("credit_cash_fee_percent = '2.9'"),
        update(statement + ", credit_cash_fee_fixed_e4 = -1"),
        update("credit_cash_fee_fixed_e4 = 100"),
        update("credit_cash_no_grace = 1"),
        update(statement + ", credit_cash_no_grace = 2"),
      ], ["tbank": f.tbank])
  }

  /// The main card of an account is one of its own cards: an account comes in without one, takes
  /// only its own, and loses it when the card moves to another account.
  @Test func theMainCardIsACardOfTheAccount() throws {
    let f = try fixture()
    #expect(
      !(try takes(
        f.stack, "INSERT INTO payment_methods (id, name, main_card_id) VALUES (?, 'New', ?)",
        [UUID().uuidString, f.black])))
    #expect(
      try takes(
        f.stack, "INSERT INTO payment_methods (id, name, main_card_id) VALUES (?, 'New', NULL)",
        [UUID().uuidString]))
    let set = "UPDATE payment_methods SET main_card_id = ? WHERE id = ?"
    #expect(try takes(f.stack, set, [f.black, f.tbank]))
    #expect(!(try takes(f.stack, set, [f.sberCard, f.tbank])))
    #expect(!(try takes(f.stack, set, [UUID().uuidString, f.tbank])))
    try f.stack.writer.write { db in
      try db.execute(sql: set, arguments: [f.black, f.tbank])
      try db.execute(sql: set, arguments: [f.sberCard, f.sber])
      // Writing the row again with the same main card is taken.
      try db.execute(
        sql: "UPDATE payment_methods SET main_card_id = main_card_id, name = 'T' WHERE id = ?",
        arguments: [f.tbank])
      // The card moves to the other account (a merge): the first account lets go of it.
      try db.execute(
        sql: "UPDATE cards SET payment_method_id = ? WHERE id = ?", arguments: [f.sber, f.black])
    }
    try f.stack.writer.read { (db: Database) throws in
      let tbank: String? = try String.fetchOne(
        db, sql: "SELECT main_card_id FROM payment_methods WHERE id = ?", arguments: [f.tbank])
      #expect(tbank == nil)
      let sber: String? = try String.fetchOne(
        db, sql: "SELECT main_card_id FROM payment_methods WHERE id = ?", arguments: [f.sber])
      #expect(sber == f.sberCard, "the account the card came to keeps its own main card")
    }
    // A deleted card lets go of the account.
    try f.stack.writer.write { db in
      try db.execute(sql: "DELETE FROM cards WHERE id = ?", arguments: [f.sberCard])
    }
    try f.stack.writer.read { (db: Database) throws in
      #expect(
        try String.fetchOne(
          db, sql: "SELECT main_card_id FROM payment_methods WHERE id = ?", arguments: [f.sber])
          == nil)
    }
  }

  // MARK: Goals, transfers, categories

  @Test func theAccountOfAGoal() throws {
    let f = try fixture()
    try expect(
      f.stack,
      good: [
        "UPDATE goals SET account_id = :sber WHERE id = :goal",
        "UPDATE goals SET account_id = :sber, transfer_on_contribution = 1 WHERE id = :goal",
      ],
      bad: [
        "UPDATE goals SET transfer_on_contribution = 1 WHERE id = :goal",
        "UPDATE goals SET account_id = :sber, transfer_on_contribution = 2 WHERE id = :goal",
        "UPDATE goals SET account_id = :missing WHERE id = :goal",
      ], ["sber": f.sber, "goal": f.goal, "missing": UUID().uuidString])
    try f.stack.writer.write { db in
      try db.execute(
        sql: "UPDATE goals SET account_id = ? WHERE id = ?", arguments: [f.sber, f.goal])
    }
    #expect(
      !(try takes(f.stack, "DELETE FROM payment_methods WHERE id = ?", [f.sber])),
      "an account a goal is kept on is not deleted")
  }

  @Test func aTransferWrittenByTheAppIsWrittenOnce() throws {
    let f = try fixture()
    let other = UUID().uuidString
    try f.stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
            from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at,
            updated_at)
          SELECT ?, occurred_at, from_payment_method_id, from_currency, from_amount_e4,
            to_payment_method_id, to_currency, to_amount_e4, created_at, updated_at
          FROM transfers WHERE id = ?
          """, arguments: [other, f.transfer])
      try db.execute(
        sql: "UPDATE transfers SET external_id = 'alloc:a:b' WHERE id = ?", arguments: [f.transfer])
    }
    #expect(
      !(try takes(
        f.stack, "UPDATE transfers SET external_id = 'alloc:a:b' WHERE id = ?", [other])))
    #expect(
      try takes(f.stack, "UPDATE transfers SET external_id = 'alloc:a:c' WHERE id = ?", [other]))
  }

  @Test func onlyAnIncomeOwesATax() throws {
    let f = try fixture()
    try expect(
      f.stack,
      good: [
        "UPDATE categories SET tax_rate = '4' WHERE id = :income",
        "UPDATE categories SET tax_rate = '4', tax_npd = 1 WHERE id = :income",
        "UPDATE categories SET tax_rate = '6.5', tax_npd = 0 WHERE id = :income",
      ],
      bad: [
        "UPDATE categories SET tax_rate = '13' WHERE id = :expense",
        "UPDATE categories SET tax_rate = ' ' WHERE id = :income",
        "UPDATE categories SET tax_npd = 1 WHERE id = :income",
        "UPDATE categories SET tax_rate = '4', tax_npd = 2 WHERE id = :income",
        "UPDATE categories SET tax_npd = NULL WHERE id = :income",
      ], ["income": f.income, "expense": f.expense])
  }

  // MARK: Allocation rules and currencies

  @Test func aRuleOfAllocationSaysWhereAndHowMuch() throws {
    let f = try fixture()
    func insert(_ values: String) -> String {
      """
      INSERT INTO allocation_rules (id, target, goal_id, payment_method_id, mode, percent,
        amount_e4, currency, active)
      VALUES (lower(hex(randomblob(16))), \(values))
      """
    }
    try expect(
      f.stack,
      good: [
        insert("'goal', :goal, NULL, 'percent', '10', NULL, NULL, 1"),
        insert("'account', NULL, :sber, 'fixed', NULL, 500000, 'USD', 1"),
        insert("'cushion', NULL, NULL, 'percent', '5.25', NULL, NULL, 0"),
        insert("'cushion', NULL, :sber, 'fixed', NULL, 500000, 'RUB', 1"),
      ],
      bad: [
        insert("'goal', NULL, NULL, 'percent', '10', NULL, NULL, 1"),
        insert("'goal', :goal, :sber, 'percent', '10', NULL, NULL, 1"),
        insert("'account', NULL, NULL, 'percent', '10', NULL, NULL, 1"),
        insert("'account', :goal, :sber, 'percent', '10', NULL, NULL, 1"),
        insert("'cushion', :goal, NULL, 'percent', '10', NULL, NULL, 1"),
        insert("'savings', NULL, :sber, 'percent', '10', NULL, NULL, 1"),
        insert("'goal', :goal, NULL, 'percent', NULL, NULL, NULL, 1"),
        insert("'goal', :goal, NULL, 'percent', '10', 500000, 'RUB', 1"),
        insert("'goal', :goal, NULL, 'fixed', NULL, 500000, NULL, 1"),
        insert("'goal', :goal, NULL, 'fixed', NULL, NULL, 'RUB', 1"),
        insert("'goal', :goal, NULL, 'fixed', '10', 500000, 'RUB', 1"),
        insert("'goal', :goal, NULL, 'fixed', NULL, 0, 'RUB', 1"),
        insert("'goal', :goal, NULL, 'fixed', NULL, 500000, 'rub', 1"),
        insert("'goal', :goal, NULL, 'fixed', NULL, 500000, 'RUBL', 1"),
        insert("'goal', :goal, NULL, 'share', '10', NULL, NULL, 1"),
        insert("'goal', :goal, NULL, 'percent', '10', NULL, NULL, 2"),
      ], ["goal": f.goal, "sber": f.sber])
    // One rule per goal, one for the cushion; a goal deleted takes its rule along.
    try f.stack.writer.write { db in
      try db.execute(
        sql: insert("'goal', :goal, NULL, 'percent', '10', NULL, NULL, 1"),
        arguments: ["goal": f.goal])
      try db.execute(
        sql: insert("'cushion', NULL, NULL, 'percent', '10', NULL, NULL, 1"),
        arguments: StatementArguments())
    }
    #expect(
      !(try takes(
        f.stack, insert("'goal', :goal, NULL, 'percent', '20', NULL, NULL, 1"), ["goal": f.goal])))
    #expect(
      !(try takes(
        f.stack, insert("'cushion', NULL, :sber, 'percent', '20', NULL, NULL, 1"),
        ["sber": f.sber])))
    try f.stack.writer.write { db in
      try db.execute(sql: "DELETE FROM goals WHERE id = ?", arguments: [f.goal])
    }
    try f.stack.writer.read { (db: Database) throws in
      #expect(try String.fetchAll(db, sql: "SELECT target FROM allocation_rules") == ["cushion"])
    }
  }

  @Test func aCustomCurrencyIsThreeCapitalLetters() throws {
    let f = try fixture()
    let insert = """
      INSERT INTO custom_currencies (code, name, symbol, fraction_digits, archived)
      VALUES (?, ?, ?, ?, ?)
      """
    #expect(try takes(f.stack, insert, ["TTH", "Tether", "₮", 2, 0]))
    #expect(try takes(f.stack, insert, ["BTC", "Bitcoin", nil, 0, 1]))
    #expect(try takes(f.stack, insert, ["XQZ", "Points", nil, 4, 0]))
    for (code, name, digits, archived) in [
      ("tth", "Tether", 2, 0), ("TTHH", "Tether", 2, 0), ("T1H", "Tether", 2, 0),
      ("TH", "Tether", 2, 0), ("TTH", " ", 2, 0), ("TTH", "Tether", 5, 0),
      ("TTH", "Tether", -1, 0), ("TTH", "Tether", 2, 2),
    ] {
      #expect(
        !(try takes(f.stack, insert, [code, name, nil, digits, archived])),
        "\(code) \(name) \(digits) \(archived)")
    }
    try f.stack.writer.write { db in
      try db.execute(sql: insert, arguments: ["TTH", "Tether", nil, 2, 0])
    }
    #expect(!(try takes(f.stack, insert, ["TTH", "Again", nil, 2, 0])))
    try f.stack.writer.read { (db: Database) throws in
      let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM custom_currencies"))
      #expect(row["fraction_digits"] as Int? == 2 && row["archived"] as Int? == 0)
      #expect(row["sort"] as Int? == 0)
    }
  }
}
