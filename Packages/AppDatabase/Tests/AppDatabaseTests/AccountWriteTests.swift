import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Every write names an account, and an operation that moves money on an account that does
/// not hold its currency says what the account was charged.
@Suite("Every operation written has an account and its charge")
struct AccountWriteTests {
  let moment = Date(timeIntervalSince1970: 1_789_000_000)

  struct Books {
    var stack: DatabaseStack
    var transactions: TransactionRepository
    var planning: PlanningRepository
    var card: PaymentMethod
    var dollars: PaymentMethod
  }

  /// A ruble card that is main and an account in dollars.
  func books(main: Bool = true) throws -> Books {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: main)
    let dollars = PaymentMethod(name: "Dollars", currency: .usd)
    let references = ReferenceRepository(writer: stack.writer)
    try references.save(card)
    try references.save(dollars)
    return Books(
      stack: stack, transactions: TransactionRepository(writer: stack.writer),
      planning: PlanningRepository(writer: stack.writer), card: card, dollars: dollars)
  }

  func operation(
    _ amount: Int64, _ currency: CurrencyCode = .rub, account: UUID? = nil,
    charged: (CurrencyCode, Int64)? = nil, category: UUID? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: moment, currency: currency, amount: AmountE4(whole: amount),
      rate: currency == .rub ? nil : 90, paymentMethodId: account,
      accountCurrency: charged?.0, accountAmount: charged.map { AmountE4(whole: $0.1) })
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = category
    return try draft.materialize(rublesConverter: { AmountE4(raw: $0.raw * 90) })
  }

  // MARK: The account

  @Test func anOperationWithNoAccountGetsTheMainOne() throws {
    let books = try books()
    let written = try books.transactions.save(try operation(250))
    #expect(written.transaction.paymentMethodId == books.card.id)
    #expect(
      try books.transactions.entry(id: written.id)?.transaction.paymentMethodId
        == books.card.id)
  }

  /// Before the accounts are set up there is no main account: the operation stays without
  /// one, and the setup gives it one.
  @Test func withNoMainAccountYetItStaysWithout() throws {
    let books = try books(main: false)
    let written = try books.transactions.save(try operation(250))
    #expect(written.transaction.paymentMethodId == nil)
  }

  // MARK: The charge

  @Test func anOperationOnAnAccountThatDoesNotHoldItsCurrencyNeedsItsCharge() throws {
    let books = try books()
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.transactions.save(try operation(10, .usd, account: books.card.id))
    }
    // With no account named, the main account is asked the same.
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.transactions.save(try operation(10, .usd))
    }
    #expect(try books.transactions.count() == 0)
    try books.transactions.save(
      try operation(10, .usd, account: books.card.id, charged: (.rub, 920)))
    try books.transactions.save(try operation(10, .usd, account: books.dollars.id))
    // A charge in a currency the account does not hold is no charge.
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.transactions.save(
        try operation(10, CurrencyCode("KZT"), account: books.card.id, charged: (.usd, 1)))
    }
  }

  /// A line of the books, a purchase on credit and money put into a goal move no money: they
  /// need no charge.
  @Test func whatMovesNoMoneyNeedsNoCharge() throws {
    let books = try books()
    let goals = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    try ReferenceRepository(writer: books.stack.writer).save(goals)
    try books.transactions.save(try operation(10, .usd, account: books.card.id, category: goals.id))

    var credit = try operation(10, .usd, account: books.card.id)
    let debt = Debt(direction: .iOwe, type: .installment, name: "Phone", origin: .purchase)
    try ReferenceRepository(writer: books.stack.writer).save(debt)
    credit.transaction.creditDebtId = debt.id
    try books.transactions.save(credit)

    var surplus = try operation(10, .usd, account: books.card.id)
    surplus.transaction.kind = .income
    surplus.transaction.externalId = ReimbursementCompanions.surplusKey(of: UUID())
    try books.transactions.save(surplus)
    #expect(try books.transactions.count() == 3)
  }

  /// A row written before accounts — a dollar operation on a ruble card with no charge — is
  /// never refused while its account, currency and amount stay; a change of them is asked.
  @Test func anUntouchedOldRowPasses() throws {
    let books = try books()
    let old = try operation(10, .usd, account: books.card.id)
    try books.stack.writer.write { db in
      try old.transaction.insert(db)
      for part in old.parts { try part.insert(db) }
    }
    let result = try books.transactions.edit(id: old.id, at: moment, calendar: .utc) { fresh in
      var edited = fresh
      edited.transaction.note = "dinner"
      return edited
    }
    guard case .edited = result else {
      Issue.record("the note was not written: \(result)")
      return
    }
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.transactions.edit(id: old.id, at: moment, calendar: .utc) { fresh in
        var edited = fresh
        edited.transaction.amountE4 = AmountE4(whole: 12)
        edited.parts[0].amountE4 = AmountE4(whole: 12)
        return edited
      }
    }
    // Moved onto the dollar account in bulk, it needs nothing; back on the card it is asked.
    try books.transactions.modify(ids: [old.id], at: moment) { fresh in
      var moved = fresh
      moved.transaction.paymentMethodId = books.dollars.id
      return moved
    }
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.transactions.modify(ids: [old.id], at: moment) { fresh in
        var moved = fresh
        moved.transaction.paymentMethodId = books.card.id
        return moved
      }
    }
  }

  /// A row of the time before accounts moved in bulk onto the dollar account needs nothing;
  /// ⌘Z writes it back as it was — on the card, with no charge — and is not asked: it puts back
  /// a row that was there, it does not make a new one.
  @Test func undoingABulkMoveOfAnOldRowPutsItBack() async throws {
    let books = try books()
    let old = try operation(20, .usd, account: books.card.id)
    try await books.stack.writer.write { db in
      try old.transaction.insert(db)
      for part in old.parts { try part.insert(db) }
    }
    let move: (TransactionEntry) -> TransactionEntry? = { fresh in
      BulkEditRule.apply(
        .paymentMethod(books.dollars.id), to: fresh, tree: CategoryTree(),
        accounts: [books.card, books.dollars]
      ).changedEntry
    }
    let before = try books.transactions.modify(ids: [old.id], at: moment, transform: move)
    #expect(
      try books.transactions.entry(id: old.id)?.transaction.paymentMethodId
        == books.dollars.id)
    let snapshots = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.transactions.modify(ids: [old.id], at: moment) { fresh in
        snapshots[fresh.id].map { BulkEditRule.revert(fresh, to: $0) }
      }
    }
    try books.transactions.modify(ids: [old.id], at: moment, checkingCharges: false) { fresh in
      snapshots[fresh.id].map { BulkEditRule.revert(fresh, to: $0) }
    }
    let back = try #require(try books.transactions.entry(id: old.id))
    #expect(back.transaction.paymentMethodId == books.card.id)
    #expect(back.transaction.accountCurrency == nil)

    // The same off the calling thread.
    let again = try books.transactions.modify(ids: [old.id], at: moment, transform: move)
    let snapshot = try #require(again.first)
    _ = try await books.transactions.modifyInBackground(
      ids: [old.id], at: moment, checkingCharges: false
    ) { fresh in BulkEditRule.revert(fresh, to: snapshot) }
    #expect(try books.transactions.entry(id: old.id)?.transaction.paymentMethodId == books.card.id)
  }

  /// What the card was charged for a dollar operation cannot be taken away while it stays on
  /// the card: the row is no longer one of the time before accounts once it had a charge.
  @Test func aChargeOnceGivenCannotBeTakenAway() throws {
    let books = try books()
    let dinner = try operation(100, .usd, account: books.card.id, charged: (.rub, 9_150))
    try books.transactions.save(dinner)
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.transactions.edit(id: dinner.id, at: moment, calendar: .utc) { fresh in
        var edited = fresh
        edited.transaction.accountCurrency = nil
        edited.transaction.accountAmountE4 = nil
        return edited
      }
    }
    #expect(
      try books.transactions.entry(id: dinner.id)?.transaction.accountAmountE4
        == AmountE4(whole: 9_150))
  }

  /// A dollar contribution to a goal on the card moved no money and needed no charge. Filed
  /// under an ordinary category it becomes spending from the card, and has to say what the card
  /// was charged; filed under the goal it stays as it was.
  @Test func aContributionThatBecomesSpendingNeedsItsCharge() throws {
    let books = try books()
    let references = ReferenceRepository(writer: books.stack.writer)
    let goals = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    let food = CoreKit.Category(kind: .expense, name: "Food")
    try references.save(goals)
    try references.save(food)
    let saved = try operation(10, .usd, account: books.card.id, category: goals.id)
    try books.transactions.save(saved)
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.transactions.edit(id: saved.id, at: moment, calendar: .utc) { fresh in
        var edited = fresh
        edited.parts[0].categoryId = food.id
        return edited
      }
    }
    let renamed = try books.transactions.edit(id: saved.id, at: moment, calendar: .utc) { fresh in
      var edited = fresh
      edited.transaction.note = "for the trip"
      return edited
    }
    guard case .edited = renamed else {
      Issue.record("a new note was not written: \(renamed)")
      return
    }
  }

  /// An operation of the time before accounts with no account: its account is filled in with
  /// the main one, which is no change of account.
  @Test func anOldRowWithNoAccountIsGivenTheMainOneWhenEdited() throws {
    let books = try books()
    let old = try operation(10, .usd)
    try books.stack.writer.write { db in
      try old.transaction.insert(db)
      for part in old.parts { try part.insert(db) }
    }
    _ = try books.transactions.edit(id: old.id, at: moment, calendar: .utc) { fresh in
      var edited = fresh
      edited.transaction.note = "dinner"
      return edited
    }
    #expect(try books.transactions.entry(id: old.id)?.transaction.paymentMethodId == books.card.id)
  }

  // MARK: The planning

  @Test func anOperationThePlanningWritesGetsAnAccountAndIsAsked() throws {
    let books = try books()
    let paid = try operation(300)
    let undo = try books.planning.apply(PlanningChange(created: [paid]))
    #expect(try books.transactions.entry(id: paid.id)?.transaction.paymentMethodId == books.card.id)
    // The change says what it wrote, with the account the write gave it.
    #expect(undo.written.map(\.id) == [paid.id])
    #expect(undo.written.first?.transaction.paymentMethodId == books.card.id)
    var renamed = try #require(try books.transactions.entry(id: paid.id))
    renamed.transaction.note = "paid"
    renamed.transaction.paymentMethodId = nil
    let renaming = try books.planning.apply(PlanningChange(rewritten: [renamed]))
    #expect(renaming.written.first?.transaction.paymentMethodId == books.card.id)
    #expect(renaming.written.first?.transaction.note == "paid")

    #expect(throws: AccountWriteError.chargeMissing) {
      try books.planning.apply(PlanningChange(created: [try operation(10, .usd)]))
    }
    var rewritten = paid
    rewritten.transaction.currency = .usd
    rewritten.transaction.paymentMethodId = books.card.id
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.planning.apply(PlanningChange(rewritten: [rewritten]))
    }
    #expect(try books.transactions.entry(id: paid.id)?.transaction.currency == .rub)
  }

  /// Money borrowed through the journal alone moves money on an account too.
  @Test func moneyBorrowedThroughTheJournalSaysWhatTheAccountMoved() throws {
    let books = try books()
    let debt = Debt(direction: .iOwe, type: .personal, name: "From a friend", currency: .usd)
    try ReferenceRepository(writer: books.stack.writer).save(debt)
    let line = DebtEntry(
      debtId: debt.id, date: DateOnly(year: 2026, month: 9, day: 10),
      amountE4: AmountE4(whole: 100), kind: .borrowed, occurredAt: moment)
    #expect(throws: AccountWriteError.chargeMissing) {
      try books.planning.apply(PlanningChange(upsert: PlanningRows(debtEntries: [line])))
    }
    var charged = line
    charged.accountCurrency = .rub
    charged.accountAmountE4 = AmountE4(whole: 9_300)
    _ = try books.planning.apply(PlanningChange(upsert: PlanningRows(debtEntries: [charged])))
    var onDollars = line
    onDollars.paymentMethodId = books.dollars.id
    _ = try books.planning.apply(PlanningChange(upsert: PlanningRows(debtEntries: [onDollars])))
    // A line of the time before accounts has no moment and is never asked.
    var old = line
    old.id = UUID()
    old.occurredAt = nil
    _ = try books.planning.apply(PlanningChange(upsert: PlanningRows(debtEntries: [old])))
  }
}
