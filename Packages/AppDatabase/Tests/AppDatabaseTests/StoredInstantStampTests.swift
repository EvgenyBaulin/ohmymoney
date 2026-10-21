import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// 2026-09-21 14:13:20.9995 UTC: a writer that rounds keeps it as 14:13:21.000.
private let event = Date(timeIntervalSince1970: 1_790_000_000.9995)
private let eventText = "2026-09-21 14:13:20.999"

/// Every way the app stamps an operation as updated — money back closing a part, deleting that
/// money back, writing a part off, refining a rate, a planning action — writes the stamp by the
/// rule of every moment: the millisecond it is in, never a later one; ⌘Z of a deletion gives
/// back the moment each operation had. And what the rule means for a day, a month and a range
/// asked for.
@Suite("Every stamp of a moment goes by one rule")
struct StoredInstantStampTests {
  /// A moment of the dinners: a whole second, far from `event`.
  private let moment = Date(timeIntervalSince1970: 1_789_000_000)
  private let friend = UUID()

  private struct Books {
    var stack: DatabaseStack
    var repository: TransactionRepository
    var card: PaymentMethod
    var groceries: CoreKit.Category
  }

  private func books() throws -> Books {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let references = ReferenceRepository(writer: stack.writer)
    try references.save(card)
    try references.save(groceries)
    return Books(
      stack: stack, repository: TransactionRepository(writer: stack.writer), card: card,
      groceries: groceries)
  }

  /// A dinner of `rubles` paid wholly for a friend, saved at `moment`.
  private func dinner(_ books: Books, rubles: Int64) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: moment, amount: AmountE4(whole: rubles), note: "dinner",
      paymentMethodId: books.card.id)
    draft.parts = [
      PartDraft(
        categoryId: books.groceries.id, amount: AmountE4(whole: rubles), forWhom: .friends,
        reimbursable: true, debtorPersonId: nil)
    ]
    let entry = try draft.materialize(now: moment)
    try books.repository.save(entry)
    return entry
  }

  /// Money back of `rubles` from the friend, recorded at `instant` as the sheet does.
  @discardableResult
  private func moneyBack(_ books: Books, _ rubles: Int64, at instant: Date) throws -> UUID {
    let plan = MoneyBack.plan(
      received: AmountE4(whole: rubles), currency: .rub, receivedRub: AmountE4(whole: rubles),
      rateProvisional: false, person: friend, owed: try books.repository.owedParts(),
      openDebts: [])
    let id = UUID()
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: moment, amount: AmountE4(whole: rubles))
    draft.normalizeSinglePart()
    try books.repository.apply(
      MoneyBack.outcome(plan, reimbursementTxId: id, accountId: books.card.id),
      reimbursement: try draft.materialize(id: id, now: moment), at: instant)
    return id
  }

  private func updatedAt(_ stack: DatabaseStack, _ id: UUID) throws -> String? {
    try stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT updated_at FROM transactions WHERE id = ?", arguments: [id.uuidString])
    }
  }

  // MARK: Stamps

  @Test func moneyBackStampsThePurchaseItCloses() throws {
    let books = try books()
    let purchase = try dinner(books, rubles: 1_500)
    try moneyBack(books, 1_500, at: event)
    #expect(try updatedAt(books.stack, purchase.id) == eventText)
  }

  /// Deleting the money back opens the part again and stamps the purchase; ⌘Z of the deletion
  /// closes it again and gives the purchase back the moment it had before.
  @Test func deletingMoneyBackAndTakingItBackStampThePurchase() throws {
    let books = try books()
    let purchase = try dinner(books, rubles: 1_500)
    let back = try moneyBack(books, 1_500, at: moment)
    let before = try updatedAt(books.stack, purchase.id)
    let effects = try books.repository.softDelete(id: back, at: event)
    #expect(try updatedAt(books.stack, purchase.id) == eventText)

    let later = Date(timeIntervalSince1970: 1_790_000_060.4999)
    try books.repository.restore(id: back, at: later, effects: effects)
    #expect(before != nil)
    #expect(try updatedAt(books.stack, purchase.id) == before)
  }

  @Test func writingAPartOffStampsItsPurchase() throws {
    let books = try books()
    let purchase = try dinner(books, rubles: 1_500)
    try books.repository.writeOffPart(id: purchase.parts[0].id, at: event)
    #expect(try updatedAt(books.stack, purchase.id) == eventText)
  }

  @Test func writingTheRestOffStampsItsPurchase() throws {
    let books = try books()
    let purchase = try dinner(books, rubles: 1_500)
    try moneyBack(books, 700, at: moment)
    let owed = try #require(try books.repository.owedParts().first)
    let companion = MoneyBack.remainderWriteOff(
      part: owed, occurredAt: moment, operationId: UUID(), tree: CategoryTree([books.groceries]))
    _ = try books.repository.writeOffRemainder(
      partId: purchase.parts[0].id, companion: companion, at: event)
    #expect(try updatedAt(books.stack, purchase.id) == eventText)
  }

  /// A provisional rate refined stamps the purchase, and the refund that follows it.
  @Test func aRefinedRateStampsThePurchaseAndItsRefund() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let calendar = CalendarContext.utc
    let day15 = DateOnly(year: 2026, month: 9, day: 15)
    let day17 = DateOnly(year: 2026, month: 9, day: 17)
    let provisional = Rate(
      date: day15, currency: .usd, rubPerUnit: Decimal(string: "80.1")!, source: .cbr)
    let final = Rate(date: day17, currency: .usd, rubPerUnit: Decimal(82), source: .cbr)
    var draft = TransactionDraft(
      occurredAt: calendar.noon(of: day17), currency: .usd, amount: AmountE4(whole: 10),
      rate: provisional.perUnit, rateDate: day15, rateSource: .cbr, rateProvisional: true)
    draft.normalizeSinglePart()
    let purchase = try draft.materialize(now: moment, rublesConverter: provisional.toRubles)
    try repository.save(purchase)
    let jacket = purchase.parts[0]
    var back = TransactionDraft(
      kind: .refund, occurredAt: calendar.noon(of: day17).addingTimeInterval(3_600),
      currency: .usd, amount: jacket.amountE4, rate: provisional.perUnit, rateDate: day15,
      rateSource: .cbr, rateProvisional: true)
    back.parts = [PartDraft(amount: jacket.amountE4, refundOfPartId: jacket.id)]
    let refund = try back.materialize(now: moment, rublesConverter: { _ in jacket.amountRubE4 })
    try repository.save(refund)

    let usages = try repository.provisionalUsages(calendar: calendar)
    let table = RateTable(rates: [provisional, final], unpublishedDays: [:])
    #expect(
      try repository.applyRefinements(
        RateTable.refinement(for: usages, with: table), of: usages, calendar: calendar,
        at: event) == 1)
    #expect(try updatedAt(stack, purchase.id) == eventText)
    #expect(try updatedAt(stack, refund.id) == eventText)
  }

  /// A planning action rewrites and deletes operations at its moment; its ⌘Z gives the deleted
  /// back the moment they had: bringing an operation back is not a new write of it.
  @Test func aPlanningActionAndItsUndoStampTheirMoments() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)
    var kept = try TestSupport.makeEntry(occurredAt: moment)
    kept.transaction.paymentMethodId = fixture.paymentMethod.id
    var gone = try TestSupport.makeEntry(occurredAt: moment)
    gone.transaction.paymentMethodId = fixture.paymentMethod.id
    try repository.save(kept)
    try repository.save(gone)

    var rewritten = kept
    rewritten.transaction.note = "paid"
    let planning = PlanningRepository(writer: stack.writer)
    let before = try updatedAt(stack, gone.id)
    let undo = try planning.apply(
      PlanningChange(rewritten: [rewritten], softDeleted: [gone.id], at: event))
    #expect(try updatedAt(stack, kept.id) == eventText)
    #expect(try updatedAt(stack, gone.id) == eventText)

    try planning.revert(undo, at: Date(timeIntervalSince1970: 1_790_000_060.4999))
    #expect(before != nil)
    #expect(try updatedAt(stack, gone.id) == before)
  }

  // MARK: Days, months and ranges

  /// An operation in the last moments of a month — 23:59:59.9996 in Moscow on 30 September,
  /// the last ten-millionth of a second before midnight, the very last `Date` of the day —
  /// stays on its day and in its month: a writer that rounds put the first of them into
  /// 1 October, one that takes the microsecond first the other two.
  @Test func theLastMomentsOfAMonthStayInIt() throws {
    let calendar = CalendarContext(timeZone: TimeZone(identifier: "Europe/Moscow")!)
    let last = DateOnly(year: 2026, month: 9, day: 30)
    let midnight = calendar.startOfDay(last.adding(days: 1)).timeIntervalSinceReferenceDate
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)
    var saved: [UUID] = []
    for interval in [midnight - 0.0004, midnight - 0.0000001, midnight.nextDown] {
      var entry = try TestSupport.makeEntry(
        occurredAt: Date(timeIntervalSinceReferenceDate: interval))
      entry.transaction.paymentMethodId = fixture.paymentMethod.id
      try repository.save(entry)
      saved.append(entry.id)

      let text = try stack.writer.read { db in
        try String.fetchOne(
          db, sql: "SELECT occurred_at FROM transactions WHERE id = ?",
          arguments: [entry.id.uuidString])
      }
      #expect(text == "2026-09-30 20:59:59.999", "\(interval)")
      let read = try #require(try repository.entry(id: entry.id))
      #expect(calendar.day(of: read.transaction.occurredAt) == last, "\(interval)")
      #expect(calendar.day(of: read.transaction.occurredAt).monthKey == last.monthKey)
    }
    let september = try repository.entries(
      from: calendar.startOfDay(DateOnly(year: 2026, month: 9, day: 1)),
      to: calendar.endOfDay(last))
    #expect(Set(september.map(\.id)) == Set(saved))
    let october = try repository.entries(
      from: calendar.startOfDay(last.adding(days: 1)),
      to: calendar.endOfDay(DateOnly(year: 2026, month: 10, day: 31)))
    #expect(october.isEmpty)
  }

  /// The database knows moments to the millisecond, so a range is asked for by the milliseconds
  /// its ends are in: an end inside a millisecond takes in the whole of it, what lies in it on
  /// the far side of the end too. Two moments in one millisecond are one moment, as they are
  /// for a count and a movement.
  @Test func aRangeIsAskedForToTheMillisecond() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)
    let second: TimeInterval = 811_692_800
    func at(_ fraction: Double) -> Date { Date(timeIntervalSinceReferenceDate: second + fraction) }
    var early = try TestSupport.makeEntry(occurredAt: at(0.5002))
    early.transaction.paymentMethodId = fixture.paymentMethod.id
    var late = try TestSupport.makeEntry(occurredAt: at(0.5008))
    late.transaction.paymentMethodId = fixture.paymentMethod.id
    try repository.save(early)
    try repository.save(late)

    func ids(_ from: Double, _ to: Double) throws -> Set<UUID> {
      Set(try repository.entries(from: at(from), to: at(to)).map(\.id))
    }
    #expect(try ids(0.5006, 0.6) == [early.id, late.id], "from inside the millisecond")
    #expect(try ids(0.4, 0.5004) == [early.id, late.id], "to inside the millisecond")
    #expect(try ids(0.501, 0.6).isEmpty, "from the next millisecond")
    #expect(try ids(0.4, 0.4999).isEmpty, "up to the millisecond before")
  }
}
