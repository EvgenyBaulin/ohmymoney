import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Money back whose surplus repays the debt of the same person: the money back for the parts,
/// the money back that repays the debt, the line of the debt and the closing of the debt are
/// one write, and one undo takes every piece of it back — the debt open again, with its balance.
@Suite("A money back whose surplus repays a debt")
struct MoneyBackDebtStorageTests {
  let bought = Date(timeIntervalSince1970: 1_789_000_000)
  let cameBack = Date(timeIntervalSince1970: 1_789_500_000)
  let instant = Date(timeIntervalSince1970: 1_790_000_000)

  struct Book {
    var stack: DatabaseStack
    var repository: TransactionRepository
    var references: ReferenceRepository
    var card: PaymentMethod
    var anna: Person
    var surcharges: UUID
    var purchase: TransactionEntry
    var debt: Debt
  }

  /// Anna owes a dinner of 1,000 ₽ and 5,000 ₽ I lent her.
  func book(debt owed: Int64 = 5_000) throws -> Book {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let card = PaymentMethod(name: "Card", kind: .card, currency: .rub, isDefault: true)
    try references.save(card)
    let anna = Person(name: "Anna")
    try references.save(anna)
    let surcharges = CoreKit.Category(kind: .income, name: "Surcharges", systemRole: .surcharges)
    try references.seedCategoriesIfEmpty([surcharges])
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      occurredAt: bought, amount: AmountE4(whole: 1_000), note: "Dinner",
      paymentMethodId: card.id)
    draft.parts = [
      PartDraft(
        amount: AmountE4(whole: 1_000), forWhom: .friends, reimbursable: true,
        debtorPersonId: anna.id)
    ]
    let purchase = try draft.materialize()
    try repository.save(purchase)
    let debt = Debt(
      direction: .owedToMe, type: .personal, name: "Anna", personId: anna.id,
      paymentsAreExpenses: false)
    try references.save(debt)
    try references.save(
      DebtRules.makeEntry(
        debtId: debt.id, kind: .borrowed, amountE4: AmountE4(whole: owed),
        date: DateOnly(year: 2026, month: 9, day: 1)))
    return Book(
      stack: stack, repository: repository, references: references, card: card, anna: anna,
      surcharges: surcharges.id, purchase: try #require(try repository.entry(id: purchase.id)),
      debt: debt)
  }

  struct Recording {
    var outcome: ReimbursementOutcome
    var back: TransactionEntry
    var extra: [TransactionEntry]
    var settling: DebtSettling
  }

  /// 3,000 ₽ came back from Anna: 1,000 close her dinner and 2,000 repay her debt by the rule
  /// of repayments — what the debt takes closes it, and what is over it is income.
  func recording(_ book: Book, received: Int64 = 3_000) throws -> Recording {
    let dinner = AmountE4(whole: 1_000)
    let rest = AmountE4(whole: received) - dinner
    let part = book.purchase.parts[0]
    let plan = MoneyBack.plan(
      received: dinner, currency: .rub, receivedRub: dinner, rateProvisional: false,
      person: book.anna.id, owed: [OwedPart(part: part, in: book.purchase.transaction)],
      openDebts: [])
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: cameBack, currency: .rub, amount: dinner,
      paymentMethodId: book.card.id)
    draft.normalizeSinglePart()
    draft.parts[0].forPersonId = book.anna.id
    let back = try draft.materialize(now: cameBack)
    let outcome = MoneyBack.outcome(plan, reimbursementTxId: back.id, accountId: book.card.id)

    var second = TransactionDraft(
      kind: .reimbursement, occurredAt: cameBack, currency: .rub, amount: rest,
      paymentMethodId: book.card.id, debtId: book.debt.id)
    second.normalizeSinglePart()
    second.parts[0].forPersonId = book.anna.id
    let repaying = try second.materialize(now: cameBack)
    let repayment = try DebtRules.repayment(
      on: book.debt, by: repaying.transaction,
      balance: DebtRules.balance(
        entries: try book.references.debtEntries(debtId: book.debt.id)),
      date: DateOnly(year: 2026, month: 9, day: 19))
    var extra = [repaying]
    if let surplus = repayment.surplus {
      extra.append(
        try MoneyBack.surplusEntry(
          surplus, of: repaying.id, on: cameBack, now: cameBack, categoryId: book.surcharges,
          note: "Surplus"))
    }
    var debts: [Debt] = []
    if repayment.closes {
      var closed = book.debt
      closed.closed = true
      debts = [closed]
    }
    return Recording(
      outcome: outcome, back: back, extra: extra,
      settling: DebtSettling(lines: repayment.line.map { [$0] } ?? [], debts: debts))
  }

  func balance(_ book: Book) throws -> AmountE4 {
    DebtRules.balance(entries: try book.references.debtEntries(debtId: book.debt.id))
  }

  func count(_ sql: String, _ book: Book) throws -> Int {
    try book.stack.writer.read { db in try Int.fetchOne(db, sql: sql) ?? -1 }
  }

  /// The dinner closes, the debt falls by 2,000 and stays open: all in the one write.
  @Test func theSurplusRepaysTheDebtInTheSameWrite() throws {
    let book = try book()
    let recorded = try recording(book)
    let write = try book.repository.apply(
      recorded.outcome, reimbursement: recorded.back, extra: recorded.extra,
      debt: recorded.settling, calendar: .utc, at: instant)
    #expect(write.created == [recorded.back.id] + recorded.extra.map(\.id))
    #expect(write.debtLines == recorded.settling.lines.map(\.id))
    #expect(
      try book.repository.entry(id: book.purchase.id)?.parts[0].reimbursementStatus == .returned)
    #expect(try balance(book) == AmountE4(whole: 3_000))
    #expect(try book.references.debts().map(\.id) == [book.debt.id], "still open")
    let paying = try #require(try book.references.debtEntries(debtId: book.debt.id).last)
    #expect(paying.kind == .payment)
    #expect(paying.amountE4 == -AmountE4(whole: 2_000))
    #expect(paying.transactionId == recorded.extra[0].id, "the line points at its own money back")
    #expect(try count("SELECT COUNT(*) FROM transactions WHERE deleted_at IS NULL", book) == 3)
  }

  /// 7,000 ₽ back with a debt of 5,000: 1,000 close the dinner, the debt takes 5,000 and
  /// closes, 1,000 are income — and one undo reopens the debt as it was.
  @Test func aSurplusOverTheDebtClosesItAndTheRestIsIncome() throws {
    let book = try book()
    let recorded = try recording(book, received: 7_000)
    #expect(recorded.settling.debts.map(\.closed) == [true])
    let write = try book.repository.apply(
      recorded.outcome, reimbursement: recorded.back, extra: recorded.extra,
      debt: recorded.settling, calendar: .utc, at: instant)
    #expect(try balance(book) == .zero)
    #expect(try book.references.debts().isEmpty, "closed with the same write")
    #expect(
      try book.references.debts(includeClosed: true).first { $0.id == book.debt.id }?.closed
        == true)
    let income = try #require(
      try book.repository.entries(from: .distantPast, to: .distantFuture)
        .first { $0.transaction.kind == .income })
    #expect(income.transaction.amountE4 == AmountE4(whole: 1_000))

    try book.repository.revertMoneyBack(write, at: instant)
    #expect(try balance(book) == AmountE4(whole: 5_000))
    #expect(try book.references.debts().map(\.id) == [book.debt.id], "open again")
    #expect(
      try book.references.debts(includeClosed: true).first { $0.id == book.debt.id }?.closed
        == false)
  }

  @Test func revertMoneyBackTakesTheLineOfTheDebtAwayToo() throws {
    let book = try book()
    let recorded = try recording(book)
    let write = try book.repository.apply(
      recorded.outcome, reimbursement: recorded.back, extra: recorded.extra,
      debt: recorded.settling, calendar: .utc, at: instant)
    try book.repository.revertMoneyBack(write, at: instant)
    #expect(try balance(book) == AmountE4(whole: 5_000))
    #expect(try book.references.debtEntries(debtId: book.debt.id).count == 1)
    #expect(try count("SELECT COUNT(*) FROM transactions WHERE deleted_at IS NULL", book) == 1)
    #expect(try count("SELECT COUNT(*) FROM reimbursement_links", book) == 0)
    #expect(
      try book.repository.entry(id: book.purchase.id)?.parts[0].reimbursementStatus == .expected)
  }

  /// The undo of a money back that repaid a debt, closed it and wrote a surplus is the exact
  /// inverse of the write: every table is what it was, rowid for rowid.
  @Test func theUndoLeavesTheDatabaseAsItWas() throws {
    for received: Int64 in [3_000, 6_000, 7_000] {
      let book = try book()
      let before = try PlanningUndoPropertyTests.contents(book.stack)
      let recorded = try recording(book, received: received)
      let write = try book.repository.apply(
        recorded.outcome, reimbursement: recorded.back, extra: recorded.extra,
        debt: recorded.settling, calendar: .utc, at: instant)
      try book.repository.revertMoneyBack(write, at: instant)
      let after = try PlanningUndoPropertyTests.contents(book.stack)
      #expect(
        after == before,
        "\(received): \(PlanningUndoPropertyTests.difference(before, after))")
    }
  }

  /// A money back that repays nothing writes what it always wrote.
  @Test func withoutADebtNothingChanges() throws {
    let book = try book()
    let recorded = try recording(book)
    let write = try book.repository.apply(
      recorded.outcome, reimbursement: recorded.back, extra: [], calendar: .utc, at: instant)
    #expect(write.debtLines.isEmpty)
    #expect(try balance(book) == AmountE4(whole: 5_000))
  }
}
