import AppCore
import CoreKit
import Foundation
import GRDB

/// Files every account that has no bank under one (`BanksMigration`): the step of the update to
/// 1.3 and the repair the app runs at every open (`AccountRepository.ensureBanks`) are this one
/// piece of work.
///
/// Every read and write is raw SQL against the columns of `payment_methods` and `banks` as
/// `0006_banks.sql` made them, never through the record types: the step of a migration must do
/// tomorrow exactly what it does today.
///
/// A key is compared as the text it is stored as, so the ids are written back as they were read:
/// an id a hand edit left in lower case is matched in lower case. One UUID stored in two cases
/// is two rows; the plan gives its bank to the first, and the other stays unfiled — no bank is
/// made on a guess.
enum BankFiling {
  /// What filing did, counts only.
  struct Outcome: Hashable {
    /// Banks made.
    var banksCreated = 0
    /// Accounts whose name is blank, which a bank cannot be named after.
    var skipped = 0
    /// Accounts put under a bank, an existing one included.
    var filed = 0
  }

  static func file(db: Database) throws -> Outcome {
    var accountTexts: [UUID: String] = [:]
    var accounts: [MigratingBankAccount] = []
    for row in try Row.fetchAll(
      db, sql: "SELECT rowid, id, name, archived, bank_id FROM payment_methods ORDER BY rowid")
    {
      guard let text: String = row["id"], let id = UUID(uuidString: text) else { continue }
      // An account whose archive flag does not read is taken for archived: filed last.
      let archived = (try? RowMapping.flag(row, "archived", fallback: false)) ?? true
      let hasBank = !(row["bank_id"] as DatabaseValue).isNull
      // Only the row the filing writes to is planned: a bank planned for the other spelling
      // could never be given to it, and at the next open its id is taken already.
      guard accountTexts[id] == nil else { continue }
      accountTexts[id] = text
      accounts.append(
        MigratingBankAccount(id: id, name: row["name"] ?? "", archived: archived, hasBank: hasBank))
    }

    var bankTexts: [UUID: String] = [:]
    var banks: [Bank] = []
    for row in try Row.fetchAll(
      db, sql: "SELECT rowid, id, name, archived FROM banks ORDER BY rowid")
    {
      guard let text: String = row["id"], let id = UUID(uuidString: text) else { continue }
      bankTexts[id] = bankTexts[id] ?? text
      let archived = (try? RowMapping.flag(row, "archived", fallback: false)) ?? true
      banks.append(Bank(id: id, name: row["name"] ?? "", archived: archived))
    }

    let plan = BanksMigration.plan(accounts: accounts, among: banks)
    for bank in plan.banks {
      try db.execute(
        sql: "INSERT INTO banks (id, name, sort, archived) VALUES (?, ?, 0, 0)",
        arguments: [bank.id.uuidString, bank.name])
      bankTexts[bank.id] = bank.id.uuidString
    }
    var filed = 0
    for assignment in plan.assignments {
      guard let account = accountTexts[assignment.account], let bank = bankTexts[assignment.bank]
      else { continue }
      try db.execute(
        sql: "UPDATE payment_methods SET bank_id = ? WHERE id = ? AND bank_id IS NULL",
        arguments: [bank, account])
      filed += db.changesCount
    }
    return Outcome(banksCreated: plan.banks.count, skipped: plan.skipped, filed: filed)
  }
}
