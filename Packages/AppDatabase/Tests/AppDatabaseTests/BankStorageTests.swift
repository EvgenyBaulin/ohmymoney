import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// «Bank → account → card» in the database: the rows read and write, an account deleted leaves
/// its bank, a card deleted leaves its account, a bank with an account under it is not deleted,
/// a new bank with its account and card is one step of ⌘Z, and an account found without a bank
/// is filed the next time the book is opened.
@Suite("Banks in the database")
struct BankStorageTests {
  private func stack() throws -> DatabaseStack { try TestSupport.makeStack() }

  // MARK: Rows

  @Test func aBankAndTheBankOfAnAccountRoundTrip() throws {
    let stack = try stack()
    let bank = Bank(name: "Т-Банк", sort: 3, archived: true)
    let account = PaymentMethod(name: "Black", bankId: bank.id)
    try stack.writer.write { db in
      try bank.insert(db)
      try account.insert(db)
    }
    let (storedBank, storedAccount) = try stack.writer.read { db in
      (
        try Bank.fetchOne(db, key: bank.id.uuidString),
        try PaymentMethod.fetchOne(db, key: account.id.uuidString)
      )
    }
    #expect(storedBank == bank)
    #expect(storedAccount?.bankId == bank.id)
    let repository = AccountRepository(writer: stack.writer)
    #expect(try repository.banks().isEmpty, "the archive is left out")
    #expect(try repository.banks(includeArchived: true) == [bank])
  }

  @Test func banksComeInTheOwnersOrderThenByName() throws {
    let stack = try stack()
    let a = Bank(name: "Альфа")
    let b = Bank(name: "ВТБ", sort: 2)
    let c = Bank(name: "Сбер", sort: 1)
    try stack.writer.write { db in
      for bank in [c, b, a] { try bank.insert(db) }
    }
    #expect(
      try AccountRepository(writer: stack.writer).banks().map(\.name) == ["Альфа", "Сбер", "ВТБ"])
  }

  /// RESTRICT: whatever the app does, the file never holds an account whose bank is gone.
  @Test func aBankWithAnAccountCannotBeDeletedUnderneath() throws {
    let stack = try stack()
    let bank = Bank(name: "Сбер")
    try stack.writer.write { db in
      try bank.insert(db)
      try PaymentMethod(name: "Сбер", bankId: bank.id).insert(db)
    }
    #expect(throws: (any Error).self) {
      try stack.writer.write { db in _ = try Bank.deleteOne(db, key: bank.id.uuidString) }
    }
  }

  // MARK: Deleting

  @Test func anAccountDeletedLeavesItsBank() throws {
    let stack = try stack()
    let repository = AccountRepository(writer: stack.writer)
    let bank = Bank(name: "Т-Банк")
    let main = PaymentMethod(name: "Main", isDefault: true, bankId: Bank(name: "Main").id)
    let account = PaymentMethod(name: "Black", bankId: bank.id)
    try stack.writer.write { db in
      try Bank(id: main.bankId!, name: "Main").insert(db)
      try bank.insert(db)
      try main.insert(db)
      try account.insert(db)
    }
    try repository.delete(account.id)
    #expect(try repository.banks().contains(bank))
    #expect(try repository.accounts().map(\.name) == ["Main"])
  }

  @Test func theLastAccountOfABankMayGoAndTheBankStaysEmpty() throws {
    let stack = try stack()
    let repository = AccountRepository(writer: stack.writer)
    let spare = Bank(name: "Запасной")
    let account = PaymentMethod(name: "Запасной", bankId: spare.id)
    let main = PaymentMethod(name: "Main", isDefault: true)
    try stack.writer.write { db in
      try spare.insert(db)
      try account.insert(db)
      try main.insert(db)
    }
    try repository.delete(account.id)
    #expect(try repository.banks() == [spare])
    // And now the empty bank can be deleted.
    try repository.deleteBank(spare.id)
    #expect(try repository.banks().isEmpty)
  }

  @Test func aCardDeletedLeavesItsAccount() throws {
    let stack = try stack()
    let account = PaymentMethod(name: "Т-Банк", isDefault: true)
    let card = PaymentCard(accountId: account.id, name: "Black")
    try stack.writer.write { db in
      try account.insert(db)
      try card.insert(db)
    }
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(delete: PlanningRowIDs(cards: [card.id])))
    let (kept, cards) = try stack.writer.read { db in
      (try PaymentMethod.exists(db, key: account.id.uuidString), try PaymentCard.fetchCount(db))
    }
    #expect(kept)
    #expect(cards == 0)
  }

  @Test func aBankWithAnAccountIsNotDeletedByTheRepository() throws {
    let stack = try stack()
    let repository = AccountRepository(writer: stack.writer)
    let bank = Bank(name: "Сбер")
    try stack.writer.write { db in
      try bank.insert(db)
      try PaymentMethod(name: "Сбер", archived: true, bankId: bank.id).insert(db)
    }
    #expect(throws: AccountWriteError.bankInUse) { try repository.deleteBank(bank.id) }
    #expect(throws: AccountWriteError.notFound) { try repository.deleteBank(UUID()) }
    #expect(try repository.banks() == [bank])
  }

  // MARK: One step of ⌘Z

  /// A bank with its first account and the card of that account: one change, one step of ⌘Z.
  @Test func aNewBankAccountAndCardAreOneStep() throws {
    let stack = try stack()
    let planning = PlanningRepository(writer: stack.writer)
    let kit = BankRules.startingKit(
      named: "Т-Банк", currency: .rub, accounts: [], banks: [])
    let undo = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(
          paymentMethods: [kit.account], cards: kit.card.map { [$0] } ?? [], banks: [kit.bank])))
    let written = try stack.writer.read { db in
      (
        try Bank.fetchAll(db), try PaymentMethod.fetchOne(db, key: kit.account.id.uuidString),
        try PaymentCard.fetchAll(db)
      )
    }
    #expect(written.0 == [kit.bank])
    #expect(written.1?.bankId == kit.bank.id)
    #expect(written.2.map(\.name) == ["Т-Банк"])
    try planning.revert(undo)
    let left = try stack.writer.read { db in
      (try Bank.fetchCount(db), try PaymentMethod.fetchCount(db), try PaymentCard.fetchCount(db))
    }
    #expect(left.0 == 0)
    #expect(left.1 == 0)
    #expect(left.2 == 0)
  }

  @Test func deletingAnEmptyBankIsUndoneAtItsPlace() throws {
    let stack = try stack()
    let planning = PlanningRepository(writer: stack.writer)
    let first = Bank(name: "Альфа")
    let second = Bank(name: "Сбер")
    let third = Bank(name: "ВТБ")
    try stack.writer.write { db in
      for bank in [first, second, third] { try bank.insert(db) }
    }
    let undo = try planning.apply(PlanningChange(delete: PlanningRowIDs(banks: [second.id])))
    #expect(try AccountRepository(writer: stack.writer).banks().map(\.name) == ["Альфа", "ВТБ"])
    try planning.revert(undo)
    let rows = try stack.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT name FROM banks ORDER BY rowid").map {
        $0["name"] as String
      }
    }
    #expect(rows == ["Альфа", "Сбер", "ВТБ"], "it comes back where it was in the table")
  }

  @Test func aBankWithAnAccountCannotBeDeletedByAChange() throws {
    let stack = try stack()
    let planning = PlanningRepository(writer: stack.writer)
    let bank = Bank(name: "Сбер")
    try stack.writer.write { db in
      try bank.insert(db)
      try PaymentMethod(name: "Сбер", archived: true, bankId: bank.id).insert(db)
    }
    #expect(throws: PlanningWriteError.referencedByOperations(bank.id)) {
      try planning.apply(PlanningChange(delete: PlanningRowIDs(banks: [bank.id])))
    }
    #expect(try AccountRepository(writer: stack.writer).banks() == [bank])
  }

  @Test func renamingAndArchivingABankAreUndone() throws {
    let stack = try stack()
    let planning = PlanningRepository(writer: stack.writer)
    let bank = Bank(name: "Сбер")
    try stack.writer.write { db in try bank.insert(db) }
    var renamed = bank
    renamed.name = "СберБанк"
    renamed.archived = true
    let undo = try planning.apply(PlanningChange(upsert: PlanningRows(banks: [renamed])))
    #expect(try AccountRepository(writer: stack.writer).banks(includeArchived: true) == [renamed])
    try planning.revert(undo)
    #expect(try AccountRepository(writer: stack.writer).banks(includeArchived: true) == [bank])
  }

  // MARK: The next open

  private func loose(
    _ names: [String], archived: [String] = [], into stack: DatabaseStack
  ) throws
    -> [PaymentMethod]
  {
    let live = names.enumerated().map {
      PaymentMethod(name: $0.element, isDefault: $0.offset == 0)
    }
    let old = archived.map { PaymentMethod(name: $0, archived: true) }
    try stack.writer.write { db in
      for account in live + old { try account.insert(db) }
    }
    return live + old
  }

  /// One UUID a hand edit stored in two cases is two rows: the first is filed, and the other
  /// stays as it is at this open and every open after — the repair never fails on it, never makes
  /// a bank for it.
  @Test func aUUIDStoredInTwoCasesIsFiledOnceAndTheNextOpenDoesNotFail() throws {
    let stack = try stack()
    let sber = PaymentMethod(name: "Сбер", isDefault: true)
    try stack.writer.write { db in
      try sber.insert(db)
      try db.execute(
        sql: "INSERT INTO payment_methods (id, name, kind) VALUES (?, 'Альфа', 'card')",
        arguments: [sber.id.uuidString.lowercased()])
    }
    let repository = AccountRepository(writer: stack.writer)
    #expect(try repository.ensureBanks() == BankRepair(created: 1, filed: 1, skipped: 0))
    #expect(try repository.ensureBanks() == nil)
    #expect(try repository.banks(includeArchived: true).map(\.name) == ["Сбер"])
  }

  /// An account a hand edit left without a bank, whose own bank of the update is still there
  /// under another name — the owner renamed it —, is filed under a bank of its own name: the id
  /// the update would give that bank is taken, and the repair does not fail on it.
  @Test func anAccountWhoseUpdateBankIdIsTakenIsFiledAllTheSame() throws {
    let stack = try stack()
    let accounts = try loose(["Сбер"], into: stack)
    let repository = AccountRepository(writer: stack.writer)
    _ = try repository.ensureBanks()
    let made = BanksMigration.bankId(forAccount: accounts[0].id)
    try stack.writer.write { db in
      try db.execute(
        sql: "UPDATE banks SET name = 'Сбербанк' WHERE id = ?", arguments: [made.uuidString])
      try db.execute(sql: "UPDATE payment_methods SET bank_id = NULL")
    }
    #expect(try repository.ensureBanks() == BankRepair(created: 1, filed: 1, skipped: 0))
    let filed = try #require(try repository.accounts().first?.bankId)
    #expect(filed != made)
    #expect(try repository.banks().first { $0.id == filed }?.name == "Сбер")
    #expect(try repository.ensureBanks() == nil)
  }

  @Test func anAccountWithoutABankIsFiledAtTheNextOpen() throws {
    let stack = try stack()
    let accounts = try loose(["Сбер", "Наличные"], archived: ["сбер"], into: stack)
    let repository = AccountRepository(writer: stack.writer)
    let repair = try #require(try repository.ensureBanks())
    #expect(repair == BankRepair(created: 2, filed: 3, skipped: 0))
    let banks = try repository.banks(includeArchived: true)
    #expect(banks.map(\.name).sorted() == ["Наличные", "Сбер"])
    let filed = try repository.accounts(includeArchived: true)
    #expect(filed.allSatisfy { $0.bankId != nil })
    // The live account named the bank; the archived one of the same name joined it.
    let sber = try #require(accounts.first { $0.name == "Сбер" })
    let old = try #require(filed.first { $0.name == "сбер" })
    #expect(old.bankId == BanksMigration.bankId(forAccount: sber.id))
    // Nothing is left to do: the next open changes nothing.
    #expect(try repository.ensureBanks() == nil)
  }

  @Test func anAccountJoinsALiveBankOfItsNameThatIsThereAlready() throws {
    let stack = try stack()
    let bank = Bank(name: "Т-Банк")
    try stack.writer.write { db in try bank.insert(db) }
    let account = PaymentMethod(name: "т-банк", isDefault: true)
    try stack.writer.write { db in try account.insert(db) }
    let repository = AccountRepository(writer: stack.writer)
    #expect(try repository.ensureBanks() == BankRepair(created: 0, filed: 1, skipped: 0))
    #expect(try repository.accounts().first?.bankId == bank.id)
    #expect(try repository.banks().count == 1)
  }

  @Test func anAccountWithABlankNameIsLeftWithoutABank() throws {
    let stack = try stack()
    try stack.writer.write { db in
      try PaymentMethod(name: "  ", isDefault: true).insert(db)
    }
    let repository = AccountRepository(writer: stack.writer)
    #expect(try repository.ensureBanks() == nil, "nothing to put right for a name that is blank")
    #expect(try repository.accounts().first?.bankId == nil)
    #expect(try repository.banks(includeArchived: true).isEmpty)
  }

  @Test func filingAtTheNextOpenIsNotAStepOfUndo() throws {
    let stack = try stack()
    _ = try loose(["Сбер"], into: stack)
    let before = try stack.writer.read { db in try Bank.fetchCount(db) }
    #expect(before == 0)
    _ = try AccountRepository(writer: stack.writer).ensureBanks()
    let after = try stack.writer.read { db in try Bank.fetchCount(db) }
    #expect(after == 1)
  }

  // MARK: Setup, snapshot, export

  @Test func theSetupFilesItsAccountsUnderItsBanks() throws {
    let stack = try stack()
    let repository = AccountRepository(writer: stack.writer)
    let bank = Bank(name: "Сбер")
    let account = PaymentMethod(name: "Сбер", isDefault: true, bankId: bank.id)
    let plan = AccountSetupPlan(
      accounts: [account], mainAccountId: account.id,
      at: Date(timeIntervalSince1970: 1_790_000_000),
      cards: [PaymentCard(accountId: account.id, name: "Сбер")], banks: [bank])
    try repository.finishSetup(plan, calendar: .utc)
    #expect(try repository.banks() == [bank])
    #expect(try repository.accounts().first?.bankId == bank.id)
  }

  @Test func theSnapshotCarriesTheBanks() async throws {
    let stack = try stack()
    let bank = Bank(name: "Сбер")
    try await stack.writer.write { db in
      try bank.insert(db)
      try PaymentMethod(name: "Сбер", isDefault: true, bankId: bank.id).insert(db)
    }
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    #expect(dataset.banks == [bank])
    #expect(dataset.paymentMethods.first?.bankId == bank.id)
  }

  @Test func theExportWritesTheBanks() throws {
    let stack = try stack()
    let bank = Bank(name: "Банк, «Мой»", sort: 2)
    try stack.writer.write { db in
      try bank.insert(db)
      try PaymentMethod(name: "Счёт", isDefault: true, bankId: bank.id).insert(db)
    }
    let tables = try ExportRepository(writer: stack.writer).tables()
    let banks = try #require(tables.first { $0.fileName == "banks.csv" })
    let rows = try CSVReader.dictionaries(from: banks.data)
    #expect(rows.count == 1)
    #expect(rows.first?["id"] == bank.id.uuidString)
    #expect(rows.first?["name"] == "Банк, «Мой»")
    let accounts = try #require(tables.first { $0.fileName == "payment_methods.csv" })
    #expect(try CSVReader.dictionaries(from: accounts.data).first?["bank_id"] == bank.id.uuidString)
    #expect(try ExportRepository(writer: stack.writer).rowCounts()["banks"] == 1)
  }

  /// «кофе 300 сбер»: the entry line reads the name of a bank as another name of its first account.
  @Test func theEntryLineReadsTheNameOfABank() throws {
    let stack = try stack()
    let sber = Bank(name: "Сбер")
    let main = PaymentMethod(name: "Основной", isDefault: true, bankId: sber.id)
    try stack.writer.write { db in
      try sber.insert(db)
      try main.insert(db)
    }
    let vocabulary = try ReferenceRepository(writer: stack.writer)
      .vocabulary(enabledCurrencies: [.rub])
    let account = try #require(vocabulary.paymentMethods.first)
    #expect(account.id == main.id)
    #expect(account.name == "Основной")
    #expect(account.aliases == ["Сбер"])
  }

  @Test func aGeneratedSampleLandsUnderItsBanks() throws {
    let stack = try stack()
    let set = TestSupport.sample().withAccounts(
      seed: 20_260_918, calendar: TestSupport.sampleCalendar, language: "en")
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))
    let (accounts, banks, broken) = try stack.writer.read { db in
      (
        try PaymentMethod.fetchAll(db), try Bank.fetchCount(db),
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
      )
    }
    #expect(!accounts.isEmpty)
    #expect(accounts.allSatisfy { $0.bankId != nil })
    #expect(banks == accounts.count)
    #expect(broken == 0)
  }
}
