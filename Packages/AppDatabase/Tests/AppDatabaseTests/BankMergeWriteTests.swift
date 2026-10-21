import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Accounts merge only within one bank, whichever path writes the merge; banks merge as one
/// planning change — every account of the merged bank, archived ones too, is filed under the
/// kept bank and the merged bank is deleted — and ⌘Z leaves the database exactly as it was.
@Suite("Merges of accounts and banks: within one bank, and undone")
struct BankMergeWriteTests {
  let at = Date(timeIntervalSince1970: 1_789_900_000)

  struct Book {
    var stack: DatabaseStack
    var sber: Bank
    var tBank: Bank
    var sberCard: PaymentMethod
    var sberDeposit: PaymentMethod
    var sberOld: PaymentMethod
    var tBankCard: PaymentMethod
    var cash: PaymentMethod
  }

  func book() throws -> Book {
    let stack = try TestSupport.makeStack()
    let sber = Bank(name: "Sber")
    let tBank = Bank(name: "T-Bank")
    let sberCard = PaymentMethod(
      name: "Sber", kind: .card, currency: .rub, isDefault: true, bankId: sber.id)
    let sberDeposit = PaymentMethod(
      name: "Sber deposit", kind: .account, currency: .rub, bankId: sber.id)
    let sberOld = PaymentMethod(
      name: "Sber old", kind: .card, currency: .rub, archived: true, bankId: sber.id)
    let tBankCard = PaymentMethod(name: "T-Bank", kind: .card, currency: .rub, bankId: tBank.id)
    let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          paymentMethods: [sberCard, sberDeposit, sberOld, tBankCard, cash],
          banks: [sber, tBank])))
    let transactions = TransactionRepository(writer: stack.writer)
    for account in [sberDeposit, tBankCard] {
      let transaction = CoreKit.Transaction(
        kind: .expense, occurredAt: at, amountE4: AmountE4(whole: 300),
        paymentMethodId: account.id, createdAt: at, updatedAt: at)
      _ = try transactions.save(
        TransactionEntry(
          transaction: transaction,
          parts: [TransactionPart(transactionId: transaction.id, amountE4: AmountE4(whole: 300))]))
    }
    return Book(
      stack: stack, sber: sber, tBank: tBank, sberCard: sberCard, sberDeposit: sberDeposit,
      sberOld: sberOld, tBankCard: tBankCard, cash: cash)
  }

  // MARK: Accounts

  @Test func accountsOfTwoBanksAreNotMergedByAnyPath() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let accounts = AccountRepository(writer: book.stack.writer)
    #expect(throws: AccountWriteError.otherBank) {
      try accounts.merge(
        AccountMergePlan(sourceId: book.tBankCard.id, target: book.sberCard, at: at),
        calendar: .utc)
    }
    let references = ReferenceRepository(writer: book.stack.writer)
    #expect(throws: AccountWriteError.otherBank) {
      try references.mergePaymentMethod(book.tBankCard.id, into: book.sberCard.id)
    }
    // An account under no bank is a bank of its own.
    #expect(throws: AccountWriteError.otherBank) {
      try accounts.merge(
        AccountMergePlan(sourceId: book.cash.id, target: book.sberCard, at: at), calendar: .utc)
    }
    #expect(throws: AccountWriteError.otherBank) {
      try references.mergePaymentMethod(book.sberDeposit.id, into: book.cash.id)
    }
    #expect(try PlanningUndoPropertyTests.contents(book.stack) == before)
  }

  @Test func accountsOfOneBankMerge() throws {
    let book = try book()
    try AccountRepository(writer: book.stack.writer).merge(
      AccountMergePlan(sourceId: book.sberDeposit.id, target: book.sberCard, at: at),
      calendar: .utc)
    let deposit = try book.stack.writer.read { db in
      try PaymentMethod.fetchOne(db, key: book.sberDeposit.id.uuidString)
    }
    #expect(deposit?.archived == true)
  }

  // MARK: Banks

  func bankMerge(_ book: Book) throws -> PlanningChange {
    let (banks, accounts) = try book.stack.writer.read { db in
      (try Bank.fetchAll(db), try PaymentMethod.fetchAll(db))
    }
    let plan = try BankMerge.plan(
      merging: book.sber.id, into: book.tBank.id, banks: banks, accounts: accounts
    ).get()
    return PlanningChange(
      upsert: PlanningRows(paymentMethods: plan.movedAccounts),
      delete: PlanningRowIDs(banks: [plan.merged.id]), at: at.addingTimeInterval(3_600))
  }

  @Test func aBankMergeFilesEveryAccountUnderTheKeptBankAndItsUndoLeavesTheDatabaseAsItWas()
    throws
  {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let planning = PlanningRepository(writer: book.stack.writer)
    let undo = try planning.apply(bankMerge(book))

    let (banks, accounts) = try book.stack.writer.read { db in
      (try Bank.fetchAll(db), try PaymentMethod.fetchAll(db))
    }
    #expect(banks.map(\.id) == [book.tBank.id])
    #expect(banks.first?.name == "T-Bank")
    let byId = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    for id in [book.sberCard.id, book.sberDeposit.id, book.sberOld.id, book.tBankCard.id] {
      #expect(byId[id]?.bankId == book.tBank.id)
    }
    #expect(byId[book.sberOld.id]?.archived == true, "an archived account moves as it is")
    #expect(byId[book.sberCard.id]?.isDefault == true, "the main account stays main")
    #expect(byId[book.sberCard.id]?.name == "Sber", "an account keeps its own name")
    #expect(byId[book.cash.id]?.bankId == nil)

    try planning.revert(undo, at: at.addingTimeInterval(7_200))
    let after = try PlanningUndoPropertyTests.contents(book.stack)
    #expect(after == before, "\(PlanningUndoPropertyTests.difference(before, after))")
  }

  /// A bank with an account still under it is never deleted, so a change that forgets an
  /// account — an archived one too — writes nothing.
  @Test func aBankMergeThatLeavesAnAccountBehindIsRefused() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    var change = try bankMerge(book)
    change.upsert.paymentMethods.removeAll { $0.id == book.sberOld.id }
    #expect(throws: (any Error).self) {
      try PlanningRepository(writer: book.stack.writer).apply(change)
    }
    #expect(try PlanningUndoPropertyTests.contents(book.stack) == before)
  }
}

extension TestSupport {
  /// Files the accounts under one new bank, as written: only accounts of one bank merge.
  static func fileUnderOneBank(_ ids: [UUID], stack: DatabaseStack) throws {
    let bank = Bank(name: "Bank \(UUID().uuidString.prefix(8))")
    try stack.writer.write { db in
      try bank.insert(db)
      for id in ids {
        try db.execute(
          sql: "UPDATE payment_methods SET bank_id = ? WHERE id = ?",
          arguments: [bank.id.uuidString, id.uuidString])
      }
    }
  }
}
