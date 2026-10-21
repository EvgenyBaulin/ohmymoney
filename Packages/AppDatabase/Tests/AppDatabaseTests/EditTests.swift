import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// One operation edited on its own (the inspector, the edit sheet): one write with what hangs
/// on it, and one revert that puts every piece back.
@Suite("One operation edited: what hangs on it follows, and undo puts it all back")
struct EditTests {
  private let instant = Date(timeIntervalSince1970: 1_790_000_000)
  private let day = DateOnly(year: 2026, month: 9, day: 18)

  /// A debt with three lines of one day — the opening, a payment written with an operation,
  /// and an adjustment after it — and that operation.
  private func payment() throws -> (
    stack: DatabaseStack, repository: TransactionRepository, debt: Debt,
    operation: TransactionEntry
  ) {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600),
      amount: AmountE4(whole: 8_500), note: "loan", debtId: fixture.debt.id)
    draft.normalizeSinglePart()
    let operation = try draft.materialize()
    try repository.save(operation)
    try stack.writer.write { db in
      try DebtRules.opening(of: fixture.debt, balance: AmountE4(whole: 100_000), date: day)
        .insert(db)
      try DebtRules.payment(
        on: fixture.debt, amountE4: AmountE4(whole: 8_500), date: day,
        transactionId: operation.id
      ).entry.insert(db)
      try DebtRules.adjustment(
        on: fixture.debt, from: .zero, to: AmountE4(whole: 100), date: day
      ).insert(db)
    }
    return (stack, repository, fixture.debt, try #require(try repository.entry(id: operation.id)))
  }

  /// The lines of the debt in the order its journal shows them: by day, then as written.
  private func journal(_ stack: DatabaseStack, _ debt: Debt) throws -> [DebtEntry] {
    try stack.writer.read { db in
      try DebtEntry.filter(Column("debt_id") == debt.id.uuidString)
        .order(Column("date"), Column.rowID)
        .fetchAll(db)
    }
  }

  @Test func theLineOfAPaymentFollowsItsAmountAndComesBackOnRevert() throws {
    let (stack, repository, debt, operation) = try payment()
    let before = try journal(stack, debt)

    let result = try repository.edit(id: operation.id, at: instant, calendar: .utc) { fresh in
      var changed = fresh
      changed.transaction.amountE4 = AmountE4(whole: 8_000)
      changed.transaction.amountRubE4 = AmountE4(whole: 8_000)
      changed.parts[0].amountE4 = AmountE4(whole: 8_000)
      changed.parts[0].amountRubE4 = AmountE4(whole: 8_000)
      return changed
    }
    guard case .edited(let edited) = result else {
      Issue.record("the edit was not written: \(result)")
      return
    }
    #expect(edited.movedDebts)
    #expect(edited.after.transaction.updatedAt == instant)
    #expect(
      try journal(stack, debt).map(\.amountE4).map(\.raw)
        == [1_000_000_000, -80_000_000, 1_000_000])

    try repository.revert(edited)
    #expect(try journal(stack, debt) == before)
    #expect(try repository.entry(id: operation.id)?.transaction.amountE4 == AmountE4(whole: 8_500))
  }

  /// The debt taken off the operation takes the line away; undo gives it back in its place
  /// among the lines of its day, not after the adjustment written later.
  @Test func aLineTakenAwayComesBackInItsPlace() throws {
    let (stack, repository, debt, operation) = try payment()
    let before = try journal(stack, debt)

    let result = try repository.edit(id: operation.id, at: instant, calendar: .utc) { fresh in
      var changed = fresh
      changed.transaction.debtId = nil
      return changed
    }
    guard case .edited(let edited) = result else {
      Issue.record("the edit was not written: \(result)")
      return
    }
    #expect(try journal(stack, debt).count == 2)

    try repository.revert(edited)
    #expect(try journal(stack, debt) == before)
  }

  @Test func anEditThatMovesNoMoneyLeavesTheJournalAlone() throws {
    let (stack, repository, debt, operation) = try payment()
    let before = try journal(stack, debt)

    let result = try repository.edit(id: operation.id, at: instant, calendar: .utc) { fresh in
      var changed = fresh
      changed.transaction.note = "another note"
      return changed
    }
    guard case .edited(let edited) = result else {
      Issue.record("the edit was not written: \(result)")
      return
    }
    #expect(!edited.movedDebts)
    #expect(try journal(stack, debt) == before)
  }

  /// Cash in the archive, with a purchase of 5 000 on it, and a live main card.
  private func archivedCash() throws -> (
    stack: DatabaseStack, repository: TransactionRepository, cash: PaymentMethod,
    card: PaymentMethod, purchase: TransactionEntry
  ) {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let card = PaymentMethod(name: "Sber", kind: .card, currency: .rub, isDefault: true)
    var cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try references.save(card)
    try references.save(cash)
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(7 * 3600),
      amount: AmountE4(whole: 5_000), note: "groceries", paymentMethodId: cash.id)
    draft.normalizeSinglePart()
    let purchase = try draft.materialize()
    try repository.save(purchase)
    cash.archived = true
    try references.save(cash)
    return (stack, repository, cash, card, try #require(try repository.entry(id: purchase.id)))
  }

  private func transfers(_ stack: DatabaseStack) throws -> [Transfer] {
    try stack.writer.read { db in try Transfer.order(Column.rowID).fetchAll(db) }
  }

  /// The purchase on the archived cash made 1 000 cheaper: the 1 000 left on the cash move to
  /// the card in the same write, and ⌘Z of the edit takes the transfer away with it.
  @Test func settlingTransfersLandWithTheEditAndGoWithItsRevert() throws {
    let (stack, repository, cash, card, purchase) = try archivedCash()
    let settling = Transfer(
      occurredAt: instant, fromAccountId: cash.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1_000), toAccountId: card.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 1_000), note: "leftover", createdAt: instant,
      updatedAt: instant)
    let cheaper: (TransactionEntry) -> TransactionEntry = { fresh in
      var changed = fresh
      changed.transaction.amountE4 = AmountE4(whole: 4_000)
      changed.transaction.amountRubE4 = AmountE4(whole: 4_000)
      changed.parts[0].amountE4 = AmountE4(whole: 4_000)
      changed.parts[0].amountRubE4 = AmountE4(whole: 4_000)
      return changed
    }

    // A transfer that may not be written — to another account in the archive — refuses the
    // whole edit.
    var otherArchived = PaymentMethod(name: "Old card", kind: .card, currency: .rub)
    otherArchived.archived = true
    try ReferenceRepository(writer: stack.writer).save(otherArchived)
    var wrong = settling
    wrong.toAccountId = otherArchived.id
    #expect(
      throws: SettlingTransferRefusal(transferId: wrong.id, issue: .archivedAccount)
    ) {
      try repository.edit(
        id: purchase.id, at: instant, calendar: .utc, settlingTransfers: [wrong], transform: cheaper
      )
    }
    #expect(try repository.entry(id: purchase.id) == purchase)
    #expect(try transfers(stack).isEmpty)

    let result = try repository.edit(
      id: purchase.id, at: instant, calendar: .utc, settlingTransfers: [settling],
      transform: cheaper)
    guard case .edited(let edited) = result else {
      Issue.record("the edit was not written: \(result)")
      return
    }
    #expect(edited.settlingTransfers == [settling.id])
    #expect(edited.reachesBeyondTheOperation)
    #expect(try transfers(stack) == [settling])
    #expect(try repository.entry(id: purchase.id)?.transaction.amountE4 == AmountE4(whole: 4_000))

    try repository.revert(edited)
    #expect(try transfers(stack).isEmpty)
    #expect(try repository.entry(id: purchase.id) == purchase)

    // An edit that changes nothing writes no transfer either.
    #expect(
      try repository.edit(
        id: purchase.id, at: instant, calendar: .utc, settlingTransfers: [settling]
      ) { $0 } == .unchanged)
    #expect(try transfers(stack).isEmpty)
  }

  // MARK: Money back when the purchase's rubles change

  /// A ruble card, a friend who owes, the system «Доплаты», and 20 $ paid for the friend at
  /// the bank's 92: 1,840 ₽ charged.
  private func subscription(
    rubles: Int64 = 1_840, dollars: Int64 = 20
  ) throws -> (
    stack: DatabaseStack, repository: TransactionRepository, card: PaymentMethod,
    surcharges: UUID, purchase: TransactionEntry
  ) {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let card = PaymentMethod(name: "Card", kind: .card, currency: .rub, isDefault: true)
    try references.save(card)
    let friend = Person(name: "Friend")
    try references.save(friend)
    let surcharges = CoreKit.Category(kind: .income, name: "Surcharges", systemRole: .surcharges)
    try references.seedCategoriesIfEmpty([surcharges])
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(9 * 3600),
      currency: .usd, amount: AmountE4(whole: dollars), rate: 92, rateDate: day,
      rateSource: .cbr, note: "Subscription", paymentMethodId: card.id, accountCurrency: .rub,
      accountAmount: AmountE4(whole: rubles))
    draft.parts = [
      PartDraft(
        amount: AmountE4(whole: dollars), forWhom: .friends, reimbursable: true,
        debtorPersonId: friend.id)
    ]
    let purchase = try draft.materialize(rublesConverter: { _ in AmountE4(whole: rubles) })
    try repository.save(purchase)
    return (
      stack, repository, card, surcharges.id, try #require(try repository.entry(id: purchase.id))
    )
  }

  /// Money back of `rubles` for the whole part, onto the card: a link of what the part cost,
  /// the part closed, and the rest income in «Доплаты» (none when it matched).
  @discardableResult
  private func moneyBack(
    _ rubles: Int64, for purchase: TransactionEntry, surcharges: UUID,
    repository: TransactionRepository, shortfall: Int64 = 0
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: instant, amount: AmountE4(whole: rubles))
    draft.normalizeSinglePart()
    let back = try draft.materialize(now: instant)
    let part = purchase.parts[0]
    let linked = min(AmountE4(whole: rubles), part.amountRubE4)
    var extra: [TransactionEntry] = []
    let over = AmountE4(whole: rubles) - part.amountRubE4
    if over.raw > 0 {
      extra.append(
        try MoneyBack.surplusEntry(
          SurchargeIncome(amountE4: over), of: back.id, on: instant, now: instant,
          categoryId: surcharges, note: "Surplus"))
    }
    if shortfall > 0 {
      var short = TransactionDraft(
        kind: .expense, occurredAt: instant, amount: AmountE4(whole: shortfall))
      short.normalizeSinglePart()
      var entry = try short.materialize(now: instant)
      entry.transaction.externalId = ReimbursementCompanions.shortfallKey(
        of: back.id, partId: part.id)
      extra.append(entry)
    }
    try repository.apply(
      ReimbursementOutcome(
        reimbursementTxId: back.id, allocations: [],
        links: [ReimbursementLink(reimbursementTxId: back.id, partId: part.id, amountE4: linked)],
        closedPartIds: [part.id]),
      reimbursement: back, extra: extra, at: instant)
    return back
  }

  /// The purchase with what the card was charged typed from the statement.
  private func charged(_ rubles: Int64) -> (TransactionEntry) -> TransactionEntry {
    { fresh in
      var edited = fresh
      let amount = AmountE4(whole: rubles)
      edited.transaction.accountAmountE4 = amount
      edited.transaction.amountRubE4 = amount
      edited.transaction.rate = amount.decimal / fresh.transaction.amountE4.decimal
      edited.transaction.rateSource = .manual
      edited.transaction.rateProvisional = false
      edited.parts[0].amountRubE4 = amount
      return edited
    }
  }

  private func links(_ stack: DatabaseStack) throws -> [AmountE4] {
    try stack.writer.read { db in try ReimbursementLink.fetchAll(db) }.map(\.amountE4)
  }

  private func surplus(
    of back: TransactionEntry, _ repository: TransactionRepository, _ stack: DatabaseStack
  ) throws -> TransactionEntry? {
    let id = try stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT id FROM transactions WHERE external_id = ?",
        arguments: [ReimbursementCompanions.surplusKey(of: back.id)])
    }.flatMap(UUID.init(uuidString:))
    return try id.flatMap { try repository.entry(id: $0) }
  }

  /// 2,000 ₽ came back for 1,840 ₽: link 1,840, surplus 160. The card was really charged
  /// 1,800 ₽: the link is 1,800 and the surplus 200, in the edit's own write; undo gives back
  /// 1,840 and 160.
  @Test func editingThePurchaseRateAfterMoneyBackMovesTheSurplus() throws {
    let (stack, repository, _, surcharges, purchase) = try subscription()
    let back = try moneyBack(2_000, for: purchase, surcharges: surcharges, repository: repository)
    #expect(try surplus(of: back, repository, stack)?.transaction.amountE4 == AmountE4(whole: 160))

    let result = try repository.edit(
      id: purchase.id, at: instant, calendar: .utc,
      settlement: SettlementSetting(surplusNote: "Surplus"), transform: charged(1_800))
    guard case .edited(let edit) = result else {
      Issue.record("the purchase was not edited")
      return
    }
    #expect(!edit.settlement.isEmpty)
    #expect(edit.reachesBeyondTheOperation)
    #expect(try links(stack) == [AmountE4(whole: 1_800)])
    #expect(try surplus(of: back, repository, stack)?.transaction.amountE4 == AmountE4(whole: 200))
    #expect(try repository.entry(id: purchase.id)?.parts[0].reimbursementStatus == .returned)

    try repository.revert(edit)
    #expect(try links(stack) == [AmountE4(whole: 1_840)])
    #expect(try surplus(of: back, repository, stack)?.transaction.amountE4 == AmountE4(whole: 160))
  }

  /// Exactly 1,840 ₽ came back. Charged 1,900 ₽ after all: 60 ₽ is more than the drift of
  /// 19 ₽ and nothing came back over the part — it waits for the rest again, nothing falls
  /// short. Charged 1,850 ₽: 10 ₽ is drift, and it stays closed.
  @Test func editingUpReopensAPartWithoutSurplus() throws {
    let (stack, repository, _, surcharges, purchase) = try subscription()
    let back = try moneyBack(1_840, for: purchase, surcharges: surcharges, repository: repository)
    _ = try repository.edit(id: purchase.id, at: instant, calendar: .utc, transform: charged(1_850))
    #expect(try repository.entry(id: purchase.id)?.parts[0].reimbursementStatus == .returned)
    _ = try repository.edit(id: purchase.id, at: instant, calendar: .utc, transform: charged(1_900))
    #expect(try repository.entry(id: purchase.id)?.parts[0].reimbursementStatus == .expected)
    #expect(try links(stack) == [AmountE4(whole: 1_840)])
    #expect(try surplus(of: back, repository, stack) == nil)
    #expect(
      try repository.owedParts().map(\.remainingRubE4) == [AmountE4(whole: 60)])
  }

  /// 20 $ at 92 (1,840 ₽) and exactly 20 $ given back onto a dollar card at 93: the dollars
  /// closed the dollars. Charged 1,900 ₽ after all, the part stays closed and nothing is owed;
  /// charged 1,800 ₽, it stays closed and nothing is income — the link follows the rubles.
  @Test func editingAPurchaseClosedInDollarsKeepsItClosed() throws {
    let (stack, repository, _, _, purchase) = try subscription()
    let dollars = PaymentMethod(name: "Dollars", kind: .card, currency: .usd)
    try ReferenceRepository(writer: stack.writer).save(dollars)
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: instant, currency: .usd, amount: AmountE4(whole: 20),
      rate: 93, rateDate: day, rateSource: .cbr, paymentMethodId: dollars.id)
    draft.normalizeSinglePart()
    let back = try draft.materialize(now: instant, rublesConverter: { _ in AmountE4(whole: 1_860) })
    let part = purchase.parts[0]
    try repository.apply(
      ReimbursementOutcome(
        reimbursementTxId: back.id, allocations: [],
        links: [
          ReimbursementLink(
            reimbursementTxId: back.id, partId: part.id, amountE4: AmountE4(whole: 1_840))
        ],
        closedPartIds: [part.id]),
      reimbursement: back, at: instant)

    _ = try repository.edit(
      id: purchase.id, at: instant, calendar: .utc,
      settlement: SettlementSetting(surplusNote: "Surplus"), transform: charged(1_900))
    #expect(try repository.entry(id: purchase.id)?.parts[0].reimbursementStatus == .returned)
    #expect(try repository.owedParts().isEmpty)
    #expect(try links(stack) == [AmountE4(whole: 1_900)])
    #expect(try surplus(of: back, repository, stack) == nil)

    _ = try repository.edit(
      id: purchase.id, at: instant, calendar: .utc,
      settlement: SettlementSetting(surplusNote: "Surplus"), transform: charged(1_800))
    #expect(try repository.entry(id: purchase.id)?.parts[0].reimbursementStatus == .returned)
    #expect(try links(stack) == [AmountE4(whole: 1_800)])
    #expect(try surplus(of: back, repository, stack) == nil)
  }

  /// 10 $ at 100 (1,000 ₽), settled by hand with 900 ₽ back and 100 ₽ short. At 102 the part is
  /// 1,020 ₽: the owner's own spending on it grows to 120 ₽; at 95, 950 ₽: it shrinks to 50 ₽.
  @Test func editingAHandSettledPartGrowsItsShortfall() throws {
    let (stack, repository, _, surcharges, purchase) = try subscription(rubles: 1_000, dollars: 10)
    let back = try moneyBack(
      900, for: purchase, surcharges: surcharges, repository: repository, shortfall: 100)
    let key = ReimbursementCompanions.shortfallKey(of: back.id, partId: purchase.parts[0].id)
    func short() throws -> AmountE4? {
      let id = try stack.writer.read { db in
        try String.fetchOne(
          db, sql: "SELECT id FROM transactions WHERE external_id = ? AND deleted_at IS NULL",
          arguments: [key])
      }.flatMap(UUID.init(uuidString:))
      return try id.flatMap { try repository.entry(id: $0)?.transaction.amountE4 }
    }
    #expect(try short() == AmountE4(whole: 100))
    _ = try repository.edit(id: purchase.id, at: instant, calendar: .utc, transform: charged(1_020))
    #expect(try short() == AmountE4(whole: 120))
    #expect(try repository.entry(id: purchase.id)?.parts[0].reimbursementStatus == .returned)
    _ = try repository.edit(id: purchase.id, at: instant, calendar: .utc, transform: charged(950))
    #expect(try short() == AmountE4(whole: 50))
    #expect(try links(stack) == [AmountE4(whole: 900)])
  }

  // MARK: The rules of an edit on an account in the archive

  /// 50 $ at 90 on the dollar cash, 20 $ of it refunded (1,800 ₽), the cash then archived. The
  /// purchase edited to 45 $ at 92: the refund follows to 1,840 ₽ as every edit makes it, and
  /// the 5 $ the edit leaves on the archived cash move to the dollar card in the same write.
  private func archivedDollars() throws -> (
    stack: DatabaseStack, repository: TransactionRepository, cash: PaymentMethod,
    dollars: PaymentMethod, purchase: TransactionEntry, refund: TransactionEntry
  ) {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let main = PaymentMethod(name: "Card", kind: .card, currency: .rub, isDefault: true)
    let dollars = PaymentMethod(name: "Dollars", kind: .card, currency: .usd)
    var cash = PaymentMethod(name: "Cash", kind: .cash, currency: .usd)
    for account in [main, dollars, cash] { try references.save(account) }
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(9 * 3600),
      currency: .usd, amount: AmountE4(whole: 50), rate: 90, rateDate: day, rateSource: .cbr,
      note: "coat", paymentMethodId: cash.id)
    draft.normalizeSinglePart()
    let purchase = try draft.materialize(rublesConverter: { _ in AmountE4(whole: 4_500) })
    try repository.save(purchase)
    let refund = try RefundRules.draft(
      refunding: purchase.parts[0], of: purchase, amount: AmountE4(whole: 20),
      occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(10 * 3600),
      accountId: cash.id, index: RefundIndex(entries: [purchase], debts: [:]),
      tree: CategoryTree()
    ).materialize(rublesConverter: { _ in AmountE4(whole: 1_800) })
    try repository.save(refund)
    cash.archived = true
    try references.save(cash)
    return (
      stack, repository, cash, dollars, try #require(try repository.entry(id: purchase.id)),
      try #require(try repository.entry(id: refund.id))
    )
  }

  private func cheaperAndDearer(_ fresh: TransactionEntry) -> TransactionEntry {
    var edited = fresh
    edited.transaction.amountE4 = AmountE4(whole: 45)
    edited.transaction.rate = 92
    edited.transaction.amountRubE4 = AmountE4(whole: 4_140)
    edited.parts[0].amountE4 = AmountE4(whole: 45)
    edited.parts[0].amountRubE4 = AmountE4(whole: 4_140)
    return edited
  }

  @Test func anEditOnAnArchivedAccountWritesItsTransferAndKeepsTheRules() throws {
    let (stack, repository, cash, dollars, purchase, refund) = try archivedDollars()
    let settling = Transfer(
      occurredAt: instant, fromAccountId: cash.id, fromCurrency: .usd,
      fromAmountE4: AmountE4(whole: 5), toAccountId: dollars.id, toCurrency: .usd,
      toAmountE4: AmountE4(whole: 5), createdAt: instant, updatedAt: instant)
    let result = try repository.edit(
      id: purchase.id, at: instant, calendar: .utc, settlingTransfers: [settling],
      transform: cheaperAndDearer)
    guard case .edited(let edit) = result else {
      Issue.record("the purchase was not edited")
      return
    }
    #expect(edit.settlingTransfers == [settling.id])
    #expect(try transfers(stack) == [settling])
    #expect(try repository.entry(id: refund.id)?.transaction.amountRubE4 == AmountE4(whole: 1_840))
    #expect(edit.refundsBefore == [refund])

    // The rules of an edit hold on the archived account too: a refunded part is not cut below
    // its refunds, whatever transfer comes with it.
    #expect(throws: LinkedEditRefusal.refundedPartReduced) {
      try repository.edit(
        id: purchase.id, at: instant, calendar: .utc, settlingTransfers: [settling]
      ) { fresh in
        var edited = fresh
        edited.transaction.amountE4 = AmountE4(whole: 10)
        edited.transaction.amountRubE4 = AmountE4(whole: 920)
        edited.parts[0].amountE4 = AmountE4(whole: 10)
        edited.parts[0].amountRubE4 = AmountE4(whole: 920)
        return edited
      }
    }
  }

  @Test func anEditOnAnArchivedAccountUndoTakesTheTransferBack() throws {
    let (stack, repository, cash, dollars, purchase, refund) = try archivedDollars()
    let settling = Transfer(
      occurredAt: instant, fromAccountId: cash.id, fromCurrency: .usd,
      fromAmountE4: AmountE4(whole: 5), toAccountId: dollars.id, toCurrency: .usd,
      toAmountE4: AmountE4(whole: 5), createdAt: instant, updatedAt: instant)
    let result = try repository.edit(
      id: purchase.id, at: instant, calendar: .utc, settlingTransfers: [settling],
      transform: cheaperAndDearer)
    guard case .edited(let edit) = result else {
      Issue.record("the purchase was not edited")
      return
    }
    try repository.revert(edit)
    #expect(try transfers(stack).isEmpty)
    #expect(try repository.entry(id: purchase.id) == purchase)
    #expect(try repository.entry(id: refund.id) == refund)
  }

  @Test func aDeletedOperationIsGoneAndAnUnchangedOneIsNotWritten() throws {
    let (_, repository, _, operation) = try payment()
    #expect(try repository.edit(id: operation.id, at: instant, calendar: .utc) { $0 } == .unchanged)
    #expect(try repository.entry(id: operation.id)?.transaction.updatedAt != instant)

    try repository.softDelete(id: operation.id)
    #expect(try repository.edit(id: operation.id, at: instant, calendar: .utc) { $0 } == .gone)
  }
}
