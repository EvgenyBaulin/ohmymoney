import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Money back recorded with the purchase's rate typed in the sheet: the purchase is written
/// again at that rate in the same write, and one undo takes every piece of it back.
@Suite("Money back that corrects the purchase's rate")
struct MoneyBackRepricingStorageTests {
  let bought = Date(timeIntervalSince1970: 1_789_000_000)
  let cameBack = Date(timeIntervalSince1970: 1_789_500_000)
  let instant = Date(timeIntervalSince1970: 1_790_000_000)

  struct Book {
    var stack: DatabaseStack
    var repository: TransactionRepository
    var card: PaymentMethod
    var raif: PaymentMethod
    var surcharges: UUID
    var purchase: TransactionEntry
  }

  /// «Подписка» 20 $ paid for a friend from the ruble card at 90: 1,800 ₽ charged.
  func book() throws -> Book {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let card = PaymentMethod(name: "Card", kind: .card, currency: .rub, isDefault: true)
    let raif = PaymentMethod(name: "Raif", kind: .card, currency: .rub)
    try references.save(card)
    try references.save(raif)
    let friend = Person(name: "Friend")
    try references.save(friend)
    let surcharges = CoreKit.Category(kind: .income, name: "Surcharges", systemRole: .surcharges)
    try references.seedCategoriesIfEmpty([surcharges])
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      occurredAt: bought, currency: .usd, amount: AmountE4(whole: 20), rate: 90,
      rateDate: CalendarContext.utc.day(of: bought), rateSource: .cbr, note: "Subscription",
      paymentMethodId: card.id, accountCurrency: .rub, accountAmount: AmountE4(whole: 1_800))
    draft.parts = [
      PartDraft(
        amount: AmountE4(whole: 20), forWhom: .friends, reimbursable: true,
        debtorPersonId: friend.id)
    ]
    var purchase = try draft.materialize(rublesConverter: { _ in AmountE4(whole: 1_800) })
    purchase.transaction.amountRubE4 = AmountE4(whole: 1_800)
    purchase.parts[0].amountRubE4 = AmountE4(whole: 1_800)
    try repository.save(purchase)
    return Book(
      stack: stack, repository: repository, card: card, raif: raif, surcharges: surcharges.id,
      purchase: try #require(try repository.entry(id: purchase.id)))
  }

  /// 2,000 ₽ came back to Raif with the purchase's rate typed as 88.
  func record(
    _ book: Book, rate: Decimal = 88
  ) throws -> (outcome: ReimbursementOutcome, back: TransactionEntry, extra: [TransactionEntry]) {
    let part = book.purchase.parts[0]
    let owed = PurchaseRate.repriced(
      [OwedPart(part: part, in: book.purchase.transaction)],
      of: try PurchaseRate.repriced(
        book.purchase, rate: rate, day: CalendarContext.utc.day(of: bought)))
    let plan = MoneyBack.plan(
      received: AmountE4(whole: 2_000), currency: .rub, receivedRub: AmountE4(whole: 2_000),
      rateProvisional: false, person: UUID(), owed: owed, openDebts: [])
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: cameBack, currency: .rub, amount: AmountE4(whole: 2_000),
      paymentMethodId: book.raif.id)
    draft.normalizeSinglePart()
    let back = try draft.materialize(now: cameBack)
    let outcome = MoneyBack.outcome(plan, reimbursementTxId: back.id, accountId: book.raif.id)
    let surplus = try #require(outcome.surplus)
    let extra = try MoneyBack.surplusEntry(
      surplus, of: back.id, on: cameBack, now: cameBack, categoryId: book.surcharges,
      note: "Surplus")
    return (outcome, back, [extra])
  }

  func count(_ sql: String, _ book: Book) throws -> Int {
    try book.stack.writer.read { db in try Int.fetchOne(db, sql: sql) ?? -1 }
  }

  /// Typed 88: the purchase is 1,760 ₽ and the card was charged 1,760 ₽ (40 ₽ less); the part
  /// closes with a link of 1,760 ₽ and 240 ₽ are income — all in the one write.
  @Test func aTypedPurchaseRateRepricesThePurchaseAndClosesInOneWrite() throws {
    let book = try book()
    let (outcome, back, extra) = try record(book)
    #expect(outcome.links.map(\.amountE4) == [AmountE4(whole: 1_760)])
    #expect(extra.first?.transaction.amountE4 == AmountE4(whole: 240))
    let write = try book.repository.apply(
      outcome, reimbursement: back, extra: extra, repricing: [book.purchase.id: 88],
      calendar: .utc, at: instant)
    #expect(write.created == [back.id] + extra.map(\.id))
    #expect(write.repricedBefore == [book.purchase])

    let purchase = try #require(try book.repository.entry(id: book.purchase.id))
    #expect(purchase.transaction.rate == 88)
    #expect(purchase.transaction.rateSource == .manual)
    #expect(purchase.transaction.amountRubE4 == AmountE4(whole: 1_760))
    #expect(purchase.transaction.accountAmountE4 == AmountE4(whole: 1_760))
    #expect(purchase.parts[0].amountRubE4 == AmountE4(whole: 1_760))
    #expect(purchase.parts[0].reimbursementStatus == .returned)
    #expect(try count("SELECT COUNT(*) FROM reimbursement_links", book) == 1)
    let surplus = try #require(try book.repository.entry(id: extra[0].id))
    #expect(surplus.transaction.paymentMethodId == book.raif.id)
    #expect(surplus.transaction.amountE4 == AmountE4(whole: 240))
  }

  /// The purchase deleted while the sheet was open: nothing of the money back is written.
  @Test func aRepricedPurchaseDeletedMeanwhileRefusesTheWholeMoneyBack() throws {
    let book = try book()
    let (outcome, back, extra) = try record(book)
    _ = try book.repository.softDelete(id: book.purchase.id, at: instant)
    #expect(throws: ReimbursementError.partNoLongerOwed(book.purchase.id)) {
      try book.repository.apply(
        outcome, reimbursement: back, extra: extra, repricing: [book.purchase.id: 88],
        calendar: .utc, at: instant)
    }
    #expect(try book.repository.entry(id: back.id) == nil)
    #expect(try count("SELECT COUNT(*) FROM reimbursement_links", book) == 0)
    let purchase = try #require(try book.repository.entry(id: book.purchase.id))
    #expect(purchase.transaction.rate == 90)
  }

  /// ⌘Z: the purchase is back at 90 / 1,800 ₽, and there is no money back, no surplus and no
  /// link; the part waits again.
  @Test func revertMoneyBackPutsEverythingBack() throws {
    let book = try book()
    let (outcome, back, extra) = try record(book)
    let write = try book.repository.apply(
      outcome, reimbursement: back, extra: extra, repricing: [book.purchase.id: 88],
      calendar: .utc, at: instant)
    try book.repository.revertMoneyBack(write, at: instant)

    let purchase = try #require(try book.repository.entry(id: book.purchase.id))
    #expect(purchase.transaction.rate == 90)
    #expect(purchase.transaction.rateSource == .cbr)
    #expect(purchase.transaction.amountRubE4 == AmountE4(whole: 1_800))
    #expect(purchase.transaction.accountAmountE4 == AmountE4(whole: 1_800))
    #expect(purchase.parts[0].amountRubE4 == AmountE4(whole: 1_800))
    #expect(purchase.parts[0].reimbursementStatus == .expected)
    #expect(try book.repository.entry(id: back.id) == nil)
    #expect(try book.repository.entry(id: extra[0].id) == nil)
    #expect(try count("SELECT COUNT(*) FROM reimbursement_links", book) == 0)
  }

  /// 1,000 ₽ came back for the part earlier, and now 100 ₽ more with the purchase's rate typed
  /// as 50.5: the part is 1,010 ₽, 10 ₽ of it left — within the drift of 10.10 ₽. The money
  /// back links those 10 ₽ and closes the part, and 90 ₽ are income; the part is not closed
  /// twice, and nothing is refused.
  @Test func aTypedRateLeavingTheRestWithinTheDriftStillRecords() throws {
    let book = try book()
    let part = book.purchase.parts[0]
    var earlier = TransactionDraft(
      kind: .reimbursement, occurredAt: bought, currency: .rub, amount: AmountE4(whole: 1_000),
      paymentMethodId: book.raif.id)
    earlier.normalizeSinglePart()
    let first = try earlier.materialize(now: bought)
    try book.repository.apply(
      ReimbursementOutcome(
        reimbursementTxId: first.id, allocations: [],
        links: [
          ReimbursementLink(
            reimbursementTxId: first.id, partId: part.id, amountE4: AmountE4(whole: 1_000))
        ],
        closedPartIds: []),
      reimbursement: first, at: bought)

    let rate = Decimal(string: "50.5")!
    let owed = try book.repository.owedParts()
    let repriced = PurchaseRate.repriced(
      owed,
      of: try PurchaseRate.repriced(
        book.purchase, rate: rate, day: CalendarContext.utc.day(of: bought)))
    #expect(repriced.map(\.remainingRubE4) == [AmountE4(whole: 10)])
    let plan = MoneyBack.plan(
      received: AmountE4(whole: 100), currency: .rub, receivedRub: AmountE4(whole: 100),
      rateProvisional: false, person: UUID(), owed: repriced, openDebts: [])
    #expect(plan.closes == [part.id])
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: cameBack, currency: .rub, amount: AmountE4(whole: 100),
      paymentMethodId: book.raif.id)
    draft.normalizeSinglePart()
    let back = try draft.materialize(now: cameBack)
    let outcome = MoneyBack.outcome(plan, reimbursementTxId: back.id, accountId: book.raif.id)
    let extra = try MoneyBack.surplusEntry(
      try #require(outcome.surplus), of: back.id, on: cameBack, now: cameBack,
      categoryId: book.surcharges, note: "Surplus")

    let write = try book.repository.apply(
      outcome, reimbursement: back, extra: [extra], repricing: [book.purchase.id: rate],
      calendar: .utc, at: instant)
    #expect(write.settlement.isEmpty)
    let purchase = try #require(try book.repository.entry(id: book.purchase.id))
    #expect(purchase.parts[0].amountRubE4 == AmountE4(whole: 1_010))
    #expect(purchase.parts[0].reimbursementStatus == .returned)
    let links = try book.stack.writer.read { db in try ReimbursementLink.fetchAll(db) }
    #expect(links.map(\.amountE4).sorted() == [AmountE4(whole: 10), AmountE4(whole: 1_000)])
    #expect(try book.repository.entry(id: extra.id)?.transaction.amountE4 == AmountE4(whole: 90))
  }

  /// Money back recorded without a typed rate is taken back just as whole.
  @Test func revertMoneyBackWithoutARateTakesTheMoneyBackAway() throws {
    let book = try book()
    let (outcome, back, extra) = try record(book, rate: 90)
    let write = try book.repository.apply(
      outcome, reimbursement: back, extra: extra, calendar: .utc, at: instant)
    #expect(write.repricedBefore.isEmpty)
    #expect(
      try book.repository.entry(id: book.purchase.id)?.parts[0].reimbursementStatus == .returned)
    try book.repository.revertMoneyBack(write, at: instant)
    #expect(try book.repository.entry(id: back.id) == nil)
    #expect(
      try book.repository.entry(id: book.purchase.id)?.parts[0].reimbursementStatus == .expected)
  }

  /// ⌘Z gives the purchase whose part waits again the moment it was last written before the
  /// money back, not the moment of the undo: taking a write back is no new write of the
  /// purchase, and the owner's latest hand rating of a description is the one written last.
  @Test func revertMoneyBackGivesThePurchaseItsMomentBack() throws {
    let book = try book()
    let before = book.purchase.transaction.updatedAt
    let (outcome, back, extra) = try record(book, rate: 90)
    let write = try book.repository.apply(
      outcome, reimbursement: back, extra: extra, calendar: .utc, at: instant)
    #expect(try book.repository.entry(id: book.purchase.id)?.transaction.updatedAt == instant)

    try book.repository.revertMoneyBack(write, at: instant.addingTimeInterval(60))
    let purchase = try #require(try book.repository.entry(id: book.purchase.id))
    #expect(purchase.parts[0].reimbursementStatus == .expected)
    #expect(purchase.transaction.updatedAt == before)
  }

  /// A purchase repriced in the sheet and closed by the same money back is back at its old
  /// rate and its old moment alike.
  @Test func revertMoneyBackGivesARepricedPurchaseItsMomentBack() throws {
    let book = try book()
    let before = book.purchase.transaction.updatedAt
    let (outcome, back, extra) = try record(book)
    let write = try book.repository.apply(
      outcome, reimbursement: back, extra: extra, repricing: [book.purchase.id: 88],
      calendar: .utc, at: instant)
    try book.repository.revertMoneyBack(write, at: instant.addingTimeInterval(60))
    let purchase = try #require(try book.repository.entry(id: book.purchase.id))
    #expect(purchase.transaction.rate == 90)
    #expect(purchase.transaction.updatedAt == before)
  }
}
