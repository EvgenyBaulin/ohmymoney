import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Money back that covers only some of a part, what is left written off, and what deleting
/// money back opens again.
@Suite("Partial money back in the database")
struct ReopenRuleTests {
  let moment = Date(timeIntervalSince1970: 1_789_000_000)
  /// Whom the dinners were paid for and who gives the money back.
  let friend = UUID()

  struct Books {
    var stack: DatabaseStack
    var repository: TransactionRepository
    var card: PaymentMethod
    var groceries: CoreKit.Category
  }

  func books() throws -> Books {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true, otherCurrencies: [.usd])
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let references = ReferenceRepository(writer: stack.writer)
    try references.save(card)
    try references.save(groceries)
    return Books(
      stack: stack, repository: TransactionRepository(writer: stack.writer), card: card,
      groceries: groceries)
  }

  /// A dinner with a part paid for a friend of `rubles`, in `currency` for `amount`.
  func dinner(
    _ books: Books, rubles: Int64, currency: CurrencyCode = .rub, amount: Int64? = nil
  ) throws -> TransactionEntry {
    let own = amount ?? rubles
    var draft = TransactionDraft(
      occurredAt: moment, currency: currency, amount: AmountE4(whole: own),
      rate: currency == .rub ? nil : Decimal(rubles) / Decimal(own), note: "dinner",
      paymentMethodId: books.card.id)
    draft.parts = [
      PartDraft(
        categoryId: books.groceries.id, amount: AmountE4(whole: own), forWhom: .friends,
        reimbursable: true, debtorPersonId: nil)
    ]
    let entry = try draft.materialize(rublesConverter: {
      AmountE4(raw: $0.raw * rubles / own)
    })
    try books.repository.save(entry)
    return entry
  }

  /// Money back of `rubles` spread by the rules over what is owed, recorded as the sheet does.
  @discardableResult
  func moneyBack(_ books: Books, _ rubles: Int64) throws -> (id: UUID, plan: MoneyBackPlan) {
    let owed = try books.repository.owedParts()
    let plan = MoneyBack.plan(
      received: AmountE4(whole: rubles), currency: .rub, receivedRub: AmountE4(whole: rubles),
      rateProvisional: false, person: friend, owed: owed, openDebts: [])
    let id = UUID()
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: moment, amount: AmountE4(whole: rubles))
    draft.normalizeSinglePart()
    let reimbursement = try draft.materialize(id: id)
    try books.repository.apply(
      MoneyBack.outcome(plan, reimbursementTxId: id, accountId: books.card.id),
      reimbursement: reimbursement)
    return (id, plan)
  }

  func status(_ books: Books, _ partId: UUID) throws -> ReimbursementStatus? {
    try books.stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT reimbursement_status FROM transaction_parts WHERE id = ?",
        arguments: [partId.uuidString]
      ).flatMap(ReimbursementStatus.init(rawValue:))
    }
  }

  // MARK: What is owed

  @Test func aPartCoveredPartlyKeepsWaitingForTheRest() throws {
    let books = try books()
    let part = try dinner(books, rubles: 1500).parts[0].id
    try moneyBack(books, 700)
    let owed = try books.repository.owedParts()
    #expect(owed.map(\.partId) == [part])
    #expect(owed.map(\.returnedRubE4) == [AmountE4(whole: 700)])
    #expect(owed.map(\.remainingRubE4) == [AmountE4(whole: 800)])
    #expect(try status(books, part) == .expected)

    try moneyBack(books, 800)
    #expect(try books.repository.owedParts().isEmpty)
    #expect(try status(books, part) == .returned)
  }

  /// The sheet read what was owed before another money back came: a link above what is left of
  /// the part now is refused, and nothing is written.
  @Test func aLinkAboveWhatIsLeftIsRefused() throws {
    let books = try books()
    let part = try dinner(books, rubles: 1500).parts[0].id
    let stale = try books.repository.owedParts()
    try moneyBack(books, 1000)
    let plan = MoneyBack.plan(
      received: AmountE4(whole: 900), currency: .rub, receivedRub: AmountE4(whole: 900),
      rateProvisional: false, person: friend, owed: stale, openDebts: [])
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: moment, amount: AmountE4(whole: 900))
    draft.normalizeSinglePart()
    let reimbursement = try draft.materialize()
    #expect(throws: ReimbursementError.partNoLongerOwed(part)) {
      try books.repository.apply(
        MoneyBack.outcome(plan, reimbursementTxId: reimbursement.id, accountId: nil),
        reimbursement: reimbursement)
    }
    #expect(try books.repository.entry(id: reimbursement.id) == nil)
  }

  // MARK: «Списать остаток»

  @Test func whatIsLeftIsWrittenOffAndThePartSettled() throws {
    let books = try books()
    let part = try dinner(books, rubles: 1500).parts[0].id
    try moneyBack(books, 700)
    let owed = try #require(try books.repository.owedParts().first)
    let companion = MoneyBack.remainderWriteOff(
      part: owed, occurredAt: moment, operationId: UUID(), tree: CategoryTree([books.groceries]))
    let written = try books.repository.writeOffRemainder(
      partId: part, companion: companion, at: moment)
    #expect(written.transaction.amountE4 == AmountE4(whole: 800))
    #expect(written.transaction.paymentMethodId == books.card.id)
    #expect(
      OperationLink(externalId: written.transaction.externalId)
        == .remainderWriteOff(
          part: part.uuidString.lowercased(), operation: written.id.uuidString.lowercased()))
    #expect(try status(books, part) == .returned)
    #expect(try books.repository.owedParts().isEmpty)
  }

  @Test func aWholePartIsWrittenOffOnlyWhileNothingCameBack() throws {
    let books = try books()
    let part = try dinner(books, rubles: 1500).parts[0].id
    let owed = try #require(try books.repository.owedParts().first)
    let companion = MoneyBack.remainderWriteOff(
      part: owed, occurredAt: moment, operationId: UUID(), tree: CategoryTree())
    #expect(throws: ReimbursementError.nothingReturnedYet(part)) {
      try books.repository.writeOffRemainder(partId: part, companion: companion)
    }
    try moneyBack(books, 700)
    #expect(throws: ReimbursementError.partlyReturned(part)) {
      try books.repository.writeOffPart(id: part)
    }
  }

  // MARK: Deleting money back

  /// Money back that covered some of a part, and more that closed it: deleting the first leaves
  /// the part short, so it waits again.
  @Test func aPartLeftShortWaitsAgain() throws {
    let books = try books()
    let part = try dinner(books, rubles: 1500).parts[0].id
    let first = try moneyBack(books, 30)
    try moneyBack(books, 1470)
    #expect(try status(books, part) == .returned)

    let effects = try books.repository.softDelete(ids: [first.id], at: moment)
    #expect(effects.reopenedPartIds == [part])
    #expect(try status(books, part) == .expected)
    #expect(try books.repository.owedParts().map(\.remainingRubE4) == [AmountE4(whole: 30)])

    try books.repository.restore(ids: effects.deletedIds, at: moment, effects: effects)
    #expect(try status(books, part) == .returned)
  }

  /// A part in dollars closed by rubles: what the money back left short is within the drift of
  /// the rate, so deleting the money back that covered the crumb leaves it closed.
  @Test func aForeignPartShortByTheDriftStaysClosed() throws {
    let books = try books()
    let part = try dinner(books, rubles: 4750, currency: .usd, amount: 50).parts[0].id
    let first = try moneyBack(books, 30)
    try moneyBack(books, 4720)
    #expect(try status(books, part) == .returned)
    let effects = try books.repository.softDelete(ids: [first.id], at: moment)
    #expect(effects.reopenedPartIds.isEmpty)
    #expect(try status(books, part) == .returned)
  }

  /// What was written off of a part goes with the money back that made it a remainder, and
  /// comes back with its undo.
  @Test func theRemainderWrittenOffGoesWhenThePartWaitsAgain() throws {
    let books = try books()
    let part = try dinner(books, rubles: 1500).parts[0].id
    let back = try moneyBack(books, 700)
    let owed = try #require(try books.repository.owedParts().first)
    let written = try books.repository.writeOffRemainder(
      partId: part,
      companion: MoneyBack.remainderWriteOff(
        part: owed, occurredAt: moment, operationId: UUID(), tree: CategoryTree()),
      at: moment)

    let effects = try books.repository.softDelete(ids: [back.id], at: moment)
    #expect(effects.reopenedPartIds == [part])
    #expect(effects.companionIds == [written.id])
    #expect(try books.repository.entry(id: written.id)?.transaction.isDeleted == true)
    #expect(try books.repository.owedParts().map(\.remainingRubE4) == [AmountE4(whole: 1500)])

    try books.repository.restore(ids: effects.deletedIds, at: moment, effects: effects)
    #expect(try books.repository.entry(id: written.id)?.transaction.isDeleted == false)
    #expect(try status(books, part) == .returned)
    #expect(try books.repository.owedParts().isEmpty)
  }

  // MARK: Edits a partial money back leans on

  @Test func thePartSomeMoneyCameBackForKeepsItsMoney() throws {
    let books = try books()
    let entry = try dinner(books, rubles: 1500)
    try moneyBack(books, 700)
    #expect(throws: LinkedEditRefusal.partlyReturnedPartChanged) {
      try books.repository.edit(id: entry.id, at: moment, calendar: .utc) { fresh in
        var edited = fresh
        edited.transaction.amountE4 = AmountE4(whole: 1400)
        edited.parts[0].amountE4 = AmountE4(whole: 1400)
        return edited
      }
    }
    let renamed = try books.repository.edit(id: entry.id, at: moment, calendar: .utc) { fresh in
      var edited = fresh
      edited.transaction.note = "birthday dinner"
      return edited
    }
    guard case .edited = renamed else {
      Issue.record("a new note was not written: \(renamed)")
      return
    }
  }

  /// A part of 50 dollars at 90 (4 500 ₽), 1 800 ₽ of it back. A rate of 92 still leaves 2 800 ₽
  /// to wait for. A rate of 30 takes the part to 1 500 ₽ — below what came back: the money back
  /// is balanced again in the same write, the part closes and its link is its 1 500 ₽ (the
  /// 300 ₽ over are income in «Доплаты» where the book has that category; this one has none,
  /// so they stay drift). Nothing is left waiting for less than nothing.
  @Test func aNewRateBelowWhatCameBackClosesThePart() throws {
    let books = try books()
    let entry = try dinner(books, rubles: 4500, currency: .usd, amount: 50)
    try moneyBack(books, 1800)
    func rated(_ rate: Decimal, rubles: Int64) -> (TransactionEntry) -> TransactionEntry? {
      { fresh in
        var edited = fresh
        edited.transaction.rate = rate
        edited.transaction.rateSource = .manual
        edited.transaction.amountRubE4 = AmountE4(whole: rubles)
        edited.parts[0].amountRubE4 = AmountE4(whole: rubles)
        return edited
      }
    }
    let dearer = try books.repository.edit(
      id: entry.id, at: moment, calendar: .utc, transform: rated(92, rubles: 4600))
    guard case .edited = dearer else {
      Issue.record("a rate that leaves something owed was not written: \(dearer)")
      return
    }
    #expect(try books.repository.owedParts().map(\.remainingRubE4) == [AmountE4(whole: 2800)])
    let cheaper = try books.repository.edit(
      id: entry.id, at: moment, calendar: .utc, transform: rated(30, rubles: 1500))
    guard case .edited = cheaper else {
      Issue.record("a rate below what came back was not written: \(cheaper)")
      return
    }
    #expect(try books.repository.owedParts().isEmpty)
    #expect(try books.repository.entry(id: entry.id)?.parts[0].reimbursementStatus == .returned)
    #expect(
      try books.stack.writer.read { db in try ReimbursementLink.fetchAll(db) }.map(\.amountE4)
        == [AmountE4(whole: 1500)])
  }

  // MARK: Deleting what was written for a part

  /// «Списать остаток» deleted on its own: the 800 ₽ are no longer my spending, so the part
  /// waits for them again — and ⌘Z closes it again with the write-off back.
  @Test func deletingTheRemainderWrittenOffOpensThePartAgain() throws {
    let books = try books()
    let part = try dinner(books, rubles: 1500).parts[0].id
    try moneyBack(books, 700)
    let owed = try #require(try books.repository.owedParts().first)
    let written = try books.repository.writeOffRemainder(
      partId: part,
      companion: MoneyBack.remainderWriteOff(
        part: owed, occurredAt: moment, operationId: UUID(), tree: CategoryTree()),
      at: moment)
    #expect(try status(books, part) == .returned)

    let effects = try books.repository.softDelete(ids: [written.id], at: moment)
    #expect(effects.deletedIds == [written.id])
    #expect(effects.reopenedPartIds == [part])
    #expect(try status(books, part) == .expected)
    #expect(try books.repository.owedParts().map(\.remainingRubE4) == [AmountE4(whole: 800)])

    try books.repository.restore(ids: effects.deletedIds, at: moment, effects: effects)
    #expect(try status(books, part) == .returned)
    #expect(try books.repository.entry(id: written.id)?.transaction.isDeleted == false)
    #expect(try books.repository.owedParts().isEmpty)
  }

  /// The shortfall of money back settled by hand, deleted on its own: the part is short of the
  /// money again and waits for it.
  @Test func deletingAShortfallOnItsOwnOpensThePartAgain() throws {
    let books = try books()
    let part = try dinner(books, rubles: 1500).parts[0].id
    let owed = try books.repository.owedParts()
    let reimbursementId = UUID()
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: reimbursementId, amountE4: AmountE4(whole: 700),
      closing: owed.map(\.inRubles))
    let short = try #require(outcome.shortfalls.first)
    var shortfall = TransactionDraft(
      occurredAt: moment, amount: short.amountE4, paymentMethodId: books.card.id)
    shortfall.parts = [PartDraft(categoryId: books.groceries.id, amount: short.amountE4)]
    var shortfallEntry = try shortfall.materialize()
    shortfallEntry.transaction.externalId = ReimbursementCompanions.shortfallKey(
      of: reimbursementId, partId: part)
    var back = TransactionDraft(
      kind: .reimbursement, occurredAt: moment, amount: AmountE4(whole: 700))
    back.normalizeSinglePart()
    try books.repository.apply(
      outcome, reimbursement: try back.materialize(id: reimbursementId),
      extra: [shortfallEntry])
    #expect(try status(books, part) == .returned)

    let effects = try books.repository.softDelete(ids: [shortfallEntry.id], at: moment)
    #expect(effects.reopenedPartIds == [part])
    #expect(try status(books, part) == .expected)
    #expect(try books.repository.owedParts().map(\.remainingRubE4) == [AmountE4(whole: 800)])
    try books.repository.restore(ids: effects.deletedIds, at: moment, effects: effects)
    #expect(try status(books, part) == .returned)
  }
}
