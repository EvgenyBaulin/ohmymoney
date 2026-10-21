import AppCore
import CoreKit
import Foundation
import GRDB

/// What a migration needs from the app beyond its SQL, run right after that SQL inside the same
/// transaction: all of it lands, or the file stays exactly as it was.
///
/// Every read and write here is raw SQL against the columns as the migration left them, never
/// through the record types: a record grows with every later schema, and the step of an older
/// migration must do tomorrow exactly what it does today.
enum MigrationDataSteps {
  /// Thrown after the SQL of a migration with a step ran, when the context asks for it: the
  /// proof that a migration stopped halfway leaves nothing behind.
  struct StoppedOnPurpose: Error {}

  /// Runs the step of the migration `name`, if it has one, and says what it did — counts only.
  static func after(
    _ name: String, db: Database, context: MigrationContext
  ) throws -> [String: Int] {
    switch name {
    case "0004_accounts": try accounts(db: db, context: context)
    case "0005_cards": try cardsAndCounts(db: db, context: context)
    case "0006_banks": try banksAndCashback(db: db, context: context)
    default: [:]
    }
  }

  /// Whether the context asks the step of `name` to stop once its SQL has run.
  private static func stops(_ name: String, context: MigrationContext) -> Bool {
    context.failAfterSQL || context.failAfterSQLOf == name
  }

  /// One live main account, and an account for every operation (`AccountsMigration`). These
  /// are the only values of the older build the update changes:
  /// - `is_default` of the chosen main account becomes 1, and of every other row 0;
  /// - `transactions.payment_method_id` that was NULL becomes the main account, in the bin too.
  ///
  /// `updated_at` of the operations stays as it was: the owner's last rating of a description
  /// is found by it. A currency left empty by the older build is not filled either — it is read
  /// as rubles.
  ///
  /// The counts: `mainKept` — an account already flagged main stays main; `mainChosen` — an
  /// account not flagged was made main; `mainCreated` — an account was made for it. One of the
  /// three is 1 exactly when the database has a main account afterwards, so the journal tells
  /// «kept» from «none at all». `defaultsCleared` — rows that lost the flag; `assigned` —
  /// operations that got the main account.
  private static func accounts(db: Database, context: MigrationContext) throws -> [String: Int] {
    var ids: [UUID: String] = [:]
    var accounts: [MigratingAccount] = []
    let rows = try Row.fetchAll(
      db, sql: "SELECT rowid, id, name, archived, is_default FROM payment_methods ORDER BY rowid")
    for row in rows {
      // An id that is NULL or not a UUID cannot be chosen; the flag still goes by the SQL below.
      guard let text: String = row["id"], let id = UUID(uuidString: text) else { continue }
      ids[id] = text
      accounts.append(
        MigratingAccount(
          id: id, name: row["name"] ?? "",
          archived: try RowMapping.flag(row, "archived", fallback: false),
          isDefault: try RowMapping.flag(row, "is_default", fallback: false), rowid: row["rowid"]))
    }
    var live: [UUID: Int] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT payment_method_id, COUNT(*) FROM transactions
        WHERE deleted_at IS NULL AND payment_method_id IS NOT NULL
        GROUP BY payment_method_id
        """)
    {
      guard let text: String = row[0], let id = UUID(uuidString: text) else { continue }
      live[id, default: 0] += row[1]
    }
    let unassigned =
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL") ?? 0
    let operations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0

    let plan = AccountsMigration.plan(
      accounts: accounts, liveOperations: live, unassigned: unassigned, operations: operations,
      mainAccountName: context.mainAccountName, makeId: context.makeId)

    var counts = [
      "mainKept": 0, "mainChosen": 0, "mainCreated": 0, "defaultsCleared": 0, "assigned": 0,
    ]
    if let created = plan.created {
      try db.execute(
        sql: """
          INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived)
          VALUES (?, ?, ?, ?, '', 1, 0)
          """,
        arguments: [
          created.id.uuidString, created.name, created.kind.rawValue, created.currency?.code,
        ])
      ids[created.id] = created.id.uuidString
      counts["mainCreated"] = 1
    }
    if let mainId = plan.mainId, let main = ids[mainId] {
      try db.execute(
        sql: "UPDATE payment_methods SET is_default = 0 WHERE is_default = 1 AND id <> ?",
        arguments: [main])
      counts["defaultsCleared"] = db.changesCount
      try db.execute(
        sql: "UPDATE payment_methods SET is_default = 1 WHERE id = ? AND is_default = 0",
        arguments: [main])
      if plan.created == nil {
        let chosen = db.changesCount
        counts["mainChosen"] = chosen
        counts["mainKept"] = 1 - chosen
      }
      if plan.assignUnassignedTo == mainId {
        try db.execute(
          sql: "UPDATE transactions SET payment_method_id = ? WHERE payment_method_id IS NULL",
          arguments: [main])
        counts["assigned"] = db.changesCount
      }
    }
    if stops("0004_accounts", context: context) { throw StoppedOnPurpose() }
    return counts
  }

  /// A bank for every account (`BanksMigration`): one bank for the accounts called alike, the
  /// live account naming it. And the cashback rules on the account (`CashbackRulesMigration`):
  /// the rules every card of an account would repeat go up to the account, and the rules on
  /// «Кредиты» go. The only values the update fills are new — the rows of the table `banks`,
  /// `bank_id` of the accounts and the settings of their cashback —; of the old ones only the
  /// rules move, as the same rows, or go.
  ///
  /// The counts: `banksCreated`; `banksSkipped` — accounts whose name is blank, which a bank
  /// refuses; `accountsFiled` — accounts put under a bank; `cashbackRulesMoved` — rules that
  /// went up to their account; `cashbackRulesDropped` — rules that went, `cashbackRulesVoided`
  /// of them on «Кредиты».
  private static func banksAndCashback(
    db: Database, context: MigrationContext
  ) throws -> [String: Int] {
    let outcome = try BankFiling.file(db: db)
    let rules = try CashbackRulesFiling.file(db: db)
    if stops("0006_banks", context: context) { throw StoppedOnPurpose() }
    return [
      "banksCreated": outcome.banksCreated, "banksSkipped": outcome.skipped,
      "accountsFiled": outcome.filed, "cashbackRulesMoved": rules.moved,
      "cashbackRulesDropped": rules.dropped, "cashbackRulesVoided": rules.onLoans,
    ]
  }

  /// A card for every live account of the kind «card» (`CardsMigration`), the mode of every
  /// compared count of a sheet (`CountsMigration`), and the month the plan of every goal with a
  /// plan counts from. The only values the update fills: rows of the new table `cards`,
  /// `records_difference` of those counts and `plan_start_month` of those goals — all new.
  /// Nothing an older build wrote changes, and no difference is computed again: a count keeps
  /// its expected balance, its difference and its operation.
  ///
  /// A key is compared as the text it is stored as, so the ids are written back as they were
  /// read: an id a hand edit left in lower case is matched in lower case. For the same reason
  /// one UUID a hand edit stored in two cases is two rows — two accounts, two counts, two
  /// sheets — and the step keeps them apart: the card points at the row the plan chose, and
  /// every compared count gets the mode of its own row and its own sheet.
  ///
  /// The counts: `cardsCreated`; `cardsSkipped` — live card accounts whose name is blank, which
  /// the table refuses; `countsRecorded`, `countsKept` — compared counts given 1 and 0;
  /// `goalPlansStarted` — goals whose plan now counts from the month of the update.
  private static func cardsAndCounts(
    db: Database, context: MigrationContext
  ) throws -> [String: Int] {
    // 1. The accounts, in the order they were written. An id that is not a UUID gets no card,
    // and neither does an account whose archive flag does not read: no card is made on a guess.
    // A UUID read twice gets one card, for its first live card account (`CardsMigration.plan`),
    // so the text kept for it is that account's — never a row of another kind or in the archive.
    var accountIds: [UUID: String] = [:]
    var accounts: [MigratingCardAccount] = []
    for row in try Row.fetchAll(
      db, sql: "SELECT rowid, id, name, kind, archived FROM payment_methods ORDER BY rowid")
    {
      guard let text: String = row["id"], let id = UUID(uuidString: text) else { continue }
      let storedKind: String? = row["kind"]
      let kind = storedKind.flatMap(PaymentMethodKind.init(rawValue:))
      let archived = (try? RowMapping.flag(row, "archived", fallback: false)) ?? true
      if kind == .card && !archived && accountIds[id] == nil { accountIds[id] = text }
      accounts.append(
        MigratingCardAccount(id: id, name: row["name"] ?? "", kind: kind, archived: archived))
    }

    // 2. Their cards.
    let plan = CardsMigration.plan(accounts: accounts)
    for card in plan.cards {
      guard let account = accountIds[card.accountId] else { continue }
      try db.execute(
        sql: """
          INSERT INTO cards (id, payment_method_id, name, aliases, sort, archived)
          VALUES (?, ?, ?, '', 0, 0)
          """,
        arguments: [card.id.uuidString, account, card.name])
    }

    // 3. The mode of every compared count of a sheet. Openings, totals and starting points are
    // not read, and keep no mode. A count or a sheet whose id is not a UUID is not read either.
    // The rule is given a key of its own for every stored text, never stored itself: one UUID
    // in two cases is two counts, or two sheets, and each keeps its own mode.
    var countTexts: [UUID: String] = [:]
    var sheetKeys: [String: UUID] = [:]
    var counts: [MigratingCount] = []
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT b.id, b.reconciliation_id, b.difference_e4, t.id AS operation, t.deleted_at
        FROM reconciliation_balances b
        JOIN reconciliations r ON r.id = b.reconciliation_id
        LEFT JOIN transactions t ON t.id = b.transaction_id
        WHERE r.kind = 'accounts' AND b.expected_e4 IS NOT NULL
        ORDER BY b.rowid
        """)
    {
      guard let text: String = row["id"], UUID(uuidString: text) != nil,
        let sheetText: String = row["reconciliation_id"], UUID(uuidString: sheetText) != nil
      else { continue }
      let key = UUID()
      countTexts[key] = text
      let sheet = sheetKeys[sheetText] ?? UUID()
      sheetKeys[sheetText] = sheet
      let difference: DatabaseValue = row["difference_e4"]
      let operation: DatabaseValue = row["operation"]
      let binned: DatabaseValue = row["deleted_at"]
      counts.append(
        MigratingCount(
          id: key, reconciliationId: sheet,
          differenceE4: Int64.fromDatabaseValue(difference).map(AmountE4.init(raw:)),
          operation: operation.isNull ? .none : binned.isNull ? .live : .binned))
    }
    var recorded = 0
    var kept = 0
    for (key, records) in CountsMigration.recordsDifference(counts) {
      guard let text = countTexts[key] else { continue }
      try db.execute(
        sql: "UPDATE reconciliation_balances SET records_difference = ? WHERE id = ?",
        arguments: [records ? 1 : 0, text])
      if records { recorded += 1 } else { kept += 1 }
    }

    // 4. The plan of a goal that has one counts from the month of the update: money put in
    // before the plan was known is not paid ahead of it. Archived goals too — one brought back
    // keeps the rule.
    try db.execute(
      sql: """
        UPDATE goals SET plan_start_month = ?
        WHERE plan_start_month IS NULL AND monthly_plan_e4 > 0
        """,
      arguments: [context.updateMonth])
    let plansStarted = db.changesCount

    if stops("0005_cards", context: context) { throw StoppedOnPurpose() }
    return [
      "cardsCreated": plan.cards.count, "cardsSkipped": plan.skipped,
      "countsRecorded": recorded, "countsKept": kept, "goalPlansStarted": plansStarted,
    ]
  }
}
