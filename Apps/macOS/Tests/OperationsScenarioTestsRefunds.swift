import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Refunds of a purchase and money people give back, as «Операции» records them: what a refund
/// may take back and at which rubles (the purchase's rate, the rest of the part exactly), how it
/// follows the purchase repriced later, how money back spreads over the parts oldest first and
/// what it leaves — a surplus that is income, shortfalls that are my spending — and that a
/// refund saved from the list is one step of ⌘Z that keeps its purchase from going alone.
final class OperationsScenarioRefundsTests: OperationsScenarioStoreCase {

  private func purchase(
    whole: Int64 = 3_000, rubles: Int64? = nil, currency: CurrencyCode = .rub,
    note: String? = "kettle", partNote: String? = nil, placeId: UUID? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: at(), currency: currency, amount: AmountE4(whole: whole),
      rate: currency == .rub ? nil : 90, rateSource: currency == .rub ? nil : .cbr, note: note,
      placeId: placeId, paymentMethodId: main.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = food.id
    draft.parts[0].note = partNote
    let rub = AmountE4(whole: rubles ?? whole)
    return try draft.materialize(now: at()) { _ in rub }
  }

  private var tree: CategoryTree { CategoryTree([food, goals, salary]) }

  private func refund(
    _ amount: Int64?, of entry: TransactionEntry, index: RefundIndex = .empty,
    account: UUID? = nil
  ) throws -> TransactionDraft {
    try RefundRules.draft(
      refunding: entry.parts[0], of: entry, amount: amount.map { AmountE4(whole: $0) },
      occurredAt: at(minute: 30), accountId: account, index: index, tree: tree)
  }

  private func index(_ entries: [TransactionEntry]) -> RefundIndex {
    RefundIndex(entries: entries, debts: [:])
  }

  // MARK: What a refund takes back

  func testTheWholeRefundTakesBackWhatIsLeft() throws {
    let kettle = try purchase(placeId: shop.id)
    let draft = try refund(nil, of: kettle)
    XCTAssertEqual(draft.kind, .refund)
    XCTAssertEqual(draft.amount, AmountE4(whole: 3_000))
    XCTAssertEqual(draft.parts.map(\.refundOfPartId), [kettle.parts[0].id])
    XCTAssertEqual(draft.parts[0].categoryId, food.id)
    XCTAssertEqual(draft.placeId, shop.id)
    XCTAssertEqual(draft.paymentMethodId, main.id)
    XCTAssertEqual(draft.note, "kettle")
    XCTAssertTrue(RefundRules.takesBack(draft))
  }

  func testTheRefundIsNamedByThePartsNoteFirst() throws {
    let kettle = try purchase(note: "shop", partNote: "kettle")
    XCTAssertEqual(try refund(nil, of: kettle).note, "kettle")
  }

  func testARefundMayComeOntoAnotherAccount() throws {
    let kettle = try purchase()
    XCTAssertEqual(try refund(100, of: kettle, account: dollars.id).paymentMethodId, dollars.id)
  }

  func testARefundOfMoreThanIsLeftIsRefused() throws {
    let kettle = try purchase()
    XCTAssertThrowsError(try refund(3_001, of: kettle)) { error in
      XCTAssertEqual(error as? RefundError, .exceedsRemaining)
    }
  }

  func testARefundOfNothingIsRefused() throws {
    let kettle = try purchase()
    XCTAssertThrowsError(try refund(0, of: kettle)) { error in
      XCTAssertEqual(error as? RefundError, .notPositive)
    }
    XCTAssertThrowsError(try refund(-5, of: kettle)) { error in
      XCTAssertEqual(error as? RefundError, .notPositive)
    }
  }

  func testAPartRefundedWholeHasNothingLeft() throws {
    let kettle = try purchase()
    let first = try refund(nil, of: kettle).materialize(now: at(minute: 30))
    let book = index([kettle, first])
    XCTAssertEqual(RefundRules.remaining(part: kettle.parts[0], index: book), .zero)
    XCTAssertThrowsError(try refund(nil, of: kettle, index: book)) { error in
      XCTAssertEqual(error as? RefundError, .exceedsRemaining)
    }
  }

  func testTwoRefundsLeaveTheRestOfThePart() throws {
    let kettle = try purchase()
    let first = try refund(1_000, of: kettle).materialize(now: at(minute: 30))
    let second = try refund(500, of: kettle, index: index([kettle, first]))
      .materialize(now: at(minute: 40))
    let book = index([kettle, first, second])
    XCTAssertEqual(
      RefundRules.remaining(part: kettle.parts[0], index: book), AmountE4(whole: 1_500))
    XCTAssertEqual(book.refunds(ofPart: kettle.parts[0].id).count, 2)
    XCTAssertEqual(book.purchasePart(ofRefundPart: second.parts[0].id), kettle.parts[0].id)
  }

  func testAPurchaseInDollarsIsRefundedInDollarsAtItsRate() throws {
    let book = try purchase(whole: 100, rubles: 9_000, currency: .usd)
    let draft = try refund(40, of: book)
    XCTAssertEqual(draft.currency, .usd)
    XCTAssertEqual(draft.rate, book.transaction.rate)
    XCTAssertEqual(draft.rateSource, .cbr)
  }

  // MARK: What may be refunded

  func testOnlyALivePurchaseOfMyOwnIsRefundable() throws {
    let kettle = try purchase()
    XCTAssertTrue(RefundRules.isRefundable(part: kettle.parts[0], in: kettle, tree: tree))

    var owed = kettle
    owed.parts[0].reimbursable = true
    owed.parts[0].debtorPersonId = anna.id
    XCTAssertFalse(RefundRules.isRefundable(part: owed.parts[0], in: owed, tree: tree))

    var deleted = kettle
    deleted.transaction.deletedAt = at()
    XCTAssertFalse(RefundRules.isRefundable(part: deleted.parts[0], in: deleted, tree: tree))

    var payment = kettle
    payment.transaction.debtId = UUID()
    XCTAssertFalse(RefundRules.isRefundable(part: payment.parts[0], in: payment, tree: tree))

    var credit = kettle
    credit.transaction.creditDebtId = UUID()
    XCTAssertFalse(RefundRules.isRefundable(part: credit.parts[0], in: credit, tree: tree))
  }

  func testIncomeAndAGoalContributionAreNotRefundable() throws {
    let pay = try make("pay", kind: .income)
    XCTAssertFalse(RefundRules.isRefundable(part: pay.parts[0], in: pay, tree: tree))
    let saving = try make("saving", parts: [part(goals)])
    XCTAssertFalse(RefundRules.isRefundable(part: saving.parts[0], in: saving, tree: tree))
  }

  func testALineTheAppWroteForItsBooksIsNotRefundable() throws {
    var surplusLine = try purchase()
    surplusLine.transaction.externalId = ReimbursementCompanions.shortfallKey(
      of: UUID(), partId: UUID())
    XCTAssertFalse(
      RefundRules.isRefundable(part: surplusLine.parts[0], in: surplusLine, tree: tree))
  }

  func testAPartOfAnotherOperationIsNotRefundableHere() throws {
    let kettle = try purchase()
    let other = try purchase()
    XCTAssertFalse(RefundRules.isRefundable(part: other.parts[0], in: kettle, tree: tree))
  }

  // MARK: The rubles of a refund

  func testTheLastRefundCompletesThePartsRublesExactly() throws {
    let book = try purchase(whole: 100, rubles: 9_001, currency: .usd)
    let part = book.parts[0]
    var before = (amount: AmountE4.zero, rub: AmountE4.zero)
    var stored: [AmountE4] = []
    for share in [Int64(33), 33, 34] {
      let rubles = RefundRules.rubles(
        refundAmount: AmountE4(whole: share), part: part, refundedBefore: before)
      stored.append(rubles)
      before = (before.amount + AmountE4(whole: share), before.rub + rubles)
    }
    XCTAssertEqual(AmountE4.sum(stored), AmountE4(whole: 9_001))
  }

  func testAPartRefundStoresItsShareOfTheRubles() throws {
    let book = try purchase(whole: 100, rubles: 9_000, currency: .usd)
    XCTAssertEqual(
      RefundRules.rubles(
        refundAmount: AmountE4(whole: 25), part: book.parts[0], refundedBefore: (.zero, .zero)),
      AmountE4(whole: 2_250))
  }

  func testARefundOfAPartOfNothingStoresNoRubles() throws {
    var empty = try purchase().parts[0]
    empty.amountE4 = .zero
    XCTAssertEqual(
      RefundRules.rubles(
        refundAmount: AmountE4(whole: 1), part: empty, refundedBefore: (.zero, .zero)), .zero)
  }

  func testRefundsFollowAPurchaseRepricedLater() throws {
    var book = try purchase(whole: 100, rubles: 9_000, currency: .usd)
    let first = try refund(90, of: book).materialize(now: at(minute: 30)) { _ in
      AmountE4(whole: 8_100)
    }
    book.transaction.rate = 50
    book.transaction.amountRubE4 = AmountE4(whole: 5_000)
    book.parts[0].amountRubE4 = AmountE4(whole: 5_000)
    let followed = RefundRules.following(purchase: book, refunds: [first])
    XCTAssertEqual(followed.count, 1)
    XCTAssertEqual(followed[0].transaction.amountRubE4, AmountE4(whole: 4_500))
    XCTAssertEqual(followed[0].transaction.rate, 50)
  }

  func testADeletedRefundDoesNotFollow() throws {
    var book = try purchase(whole: 100, rubles: 9_000, currency: .usd)
    var gone = try refund(90, of: book).materialize(now: at(minute: 30))
    gone.transaction.deletedAt = at(minute: 31)
    book.parts[0].amountRubE4 = AmountE4(whole: 5_000)
    XCTAssertTrue(RefundRules.following(purchase: book, refunds: [gone]).isEmpty)
  }

  func testARefundAlreadyInLineDoesNotChange() throws {
    let book = try purchase(whole: 100, rubles: 9_000, currency: .usd)
    let first = try refund(nil, of: book).materialize(now: at(minute: 30)) { _ in
      AmountE4(whole: 9_000)
    }
    XCTAssertTrue(RefundRules.following(purchase: book, refunds: [first]).isEmpty)
  }

  // MARK: Money given back

  private func owed(
    _ whole: Int64, minutes: Int, account: UUID? = nil, provisional: Bool = false
  ) -> OwedPart {
    OwedPart(
      partId: UUID(), transactionId: UUID(), occurredAt: at(minute: minutes),
      debtorPersonId: anna.id, categoryId: food.id, amountE4: AmountE4(whole: whole),
      rateProvisional: provisional, accountId: account)
  }

  func testMoneyBackGoesToTheOldestPartFirst() {
    let newer = owed(300, minutes: 10)
    let older = owed(200, minutes: 1)
    let shares = ReimbursementResolver.allocate(
      amountE4: AmountE4(whole: 250), over: [newer, older])
    XCTAssertEqual(shares.map(\.partId), [older.partId, newer.partId])
    XCTAssertEqual(shares.map(\.amountE4), [AmountE4(whole: 200), AmountE4(whole: 50)])
  }

  func testMoneyBackThatCoversEveryPartLeavesNothingElse() throws {
    let parts = [owed(200, minutes: 1), owed(300, minutes: 2)]
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: UUID(), amountE4: AmountE4(whole: 500), closing: parts)
    XCTAssertNil(outcome.surplus)
    XCTAssertTrue(outcome.shortfalls.isEmpty)
    XCTAssertEqual(Set(outcome.closedPartIds), Set(parts.map(\.partId)))
    XCTAssertEqual(outcome.links.count, 2)
    XCTAssertEqual(outcome.receivedE4, AmountE4(whole: 500))
  }

  func testMoneyBackBeyondThePartsIsASurplusOnItsAccount() throws {
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: UUID(), amountE4: AmountE4(whole: 700),
      closing: [owed(500, minutes: 1)], accountId: dollars.id)
    XCTAssertEqual(outcome.surplusE4, AmountE4(whole: 200))
    XCTAssertEqual(outcome.surplus?.accountId, dollars.id)
    XCTAssertEqual(outcome.surplus?.systemRole, .surcharges)
    XCTAssertEqual(outcome.receivedE4, AmountE4(whole: 700))
  }

  func testMoneyBackShortOfThePartsLeavesMySpendingOnTheirAccount() throws {
    let first = owed(200, minutes: 1, account: main.id)
    let second = owed(300, minutes: 2, account: main.id)
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: UUID(), amountE4: AmountE4(whole: 250), closing: [second, first])
    XCTAssertEqual(outcome.shortfalls.map(\.partId), [second.partId])
    XCTAssertEqual(outcome.shortfallTotalE4, AmountE4(whole: 250))
    XCTAssertEqual(outcome.shortfalls.first?.categoryId, food.id)
    XCTAssertEqual(outcome.shortfalls.first?.accountId, main.id)
    XCTAssertEqual(outcome.closedPartIds, [first.partId, second.partId], "both are closed")
  }

  func testNothingBackStillClosesThePartAsMySpending() throws {
    let part = owed(400, minutes: 1)
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: UUID(), amountE4: .zero, closing: [part])
    XCTAssertEqual(outcome.links.map(\.amountE4), [.zero])
    XCTAssertEqual(outcome.shortfallTotalE4, AmountE4(whole: 400))
  }

  func testAHandMadeShareCanLeaveBothASurplusAndAShortfall() throws {
    let part = owed(400, minutes: 1)
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: UUID(), amountE4: AmountE4(whole: 500), closing: [part],
      allocation: [ReimbursementAllocation(partId: part.partId, amountE4: AmountE4(whole: 300))])
    XCTAssertEqual(outcome.surplusE4, AmountE4(whole: 200))
    XCTAssertEqual(outcome.shortfallTotalE4, AmountE4(whole: 100))
  }

  func testAPartLeftOutOfAHandMadeShareGetsNothing() throws {
    let a = owed(100, minutes: 1)
    let b = owed(100, minutes: 2)
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: UUID(), amountE4: AmountE4(whole: 100), closing: [a, b],
      allocation: [ReimbursementAllocation(partId: b.partId, amountE4: AmountE4(whole: 100))])
    XCTAssertEqual(outcome.allocations.map(\.amountE4), [.zero, AmountE4(whole: 100)])
    XCTAssertEqual(outcome.shortfalls.map(\.partId), [a.partId])
  }

  private func share(_ part: OwedPart, _ whole: Int64) -> ReimbursementAllocation {
    ReimbursementAllocation(partId: part.partId, amountE4: AmountE4(whole: whole))
  }

  func testMoneyBackIsRefusedForEveryWrongShape() {
    let part = owed(100, minutes: 1)
    let id = UUID()
    func refusal(
      _ amount: Int64, _ parts: [OwedPart], _ shares: [ReimbursementAllocation]? = nil
    ) -> ReimbursementError? {
      do {
        _ = try ReimbursementResolver.resolve(
          reimbursementTxId: id, amountE4: AmountE4(whole: amount), closing: parts,
          allocation: shares)
        return nil
      } catch { return error as? ReimbursementError }
    }
    XCTAssertEqual(refusal(100, []), .noPartsSelected)
    XCTAssertEqual(refusal(-1, [part]), .negativeAmount)
    XCTAssertEqual(refusal(100, [part, part]), .duplicatePart(part.partId))
    let provisional = owed(100, minutes: 2, provisional: true)
    XCTAssertEqual(refusal(100, [provisional]), .provisionalRate(provisional.partId))
    let stranger = UUID()
    XCTAssertEqual(
      refusal(100, [part], [ReimbursementAllocation(partId: stranger, amountE4: .zero)]),
      .unknownPart(stranger))
    XCTAssertEqual(
      refusal(100, [part], [share(part, -1)]),
      .negativeAllocation(part.partId))
    XCTAssertEqual(
      refusal(500, [part], [share(part, 101)]),
      .allocationExceedsPart(part.partId))
    XCTAssertEqual(
      refusal(50, [part], [share(part, 60)]),
      .allocationExceedsAmount)
  }

  func testEveryRefusalOfMoneyBackSaysWhy() {
    let errors: [ReimbursementError] = [
      .noPartsSelected, .negativeAmount, .duplicatePart(UUID()), .unknownPart(UUID()),
      .negativeAllocation(UUID()), .allocationExceedsPart(UUID()), .allocationExceedsAmount,
      .provisionalRate(UUID()), .partNoLongerOwed(UUID()), .nothingReturnedYet(UUID()),
      .partlyReturned(UUID()),
    ]
    XCTAssertEqual(Set(errors.map(\.description)).count, errors.count)
  }

  func testTheKeysOfWhatMoneyBackWroteStartWithItsOwn() {
    let id = UUID()
    let part = UUID()
    let prefix = ReimbursementCompanions.keyPrefix(of: id)
    XCTAssertEqual(prefix, "reimb:\(id.uuidString.lowercased()):")
    XCTAssertTrue(ReimbursementCompanions.surplusKey(of: id).hasPrefix(prefix))
    let shortfall = ReimbursementCompanions.shortfallKey(of: id, partId: part)
    XCTAssertTrue(shortfall.hasPrefix(prefix))
    XCTAssertTrue(shortfall.hasSuffix(part.uuidString.lowercased()))
    XCTAssertEqual(shortfall, shortfall.lowercased())
  }

  func testThePartsWaitingForMoneyAreTheExpectedOnes() throws {
    let dinner = try make(
      "dinner", whole: 300,
      parts: [
        part(food),
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), reimbursable: true,
          debtorPersonId: anna.id),
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), reimbursable: true,
          debtorPersonId: boris.id, reimbursementStatus: .writtenOff),
      ])
    let waiting = MyExpensesRule.owedToMe(entries: [dinner])
    XCTAssertEqual(waiting.map(\.partId), [dinner.parts[1].id])
    XCTAssertEqual(MyExpensesRule.totalOwedToMe(entries: [dinner]), AmountE4(whole: 100))
  }

  // MARK: Through the store

  func testARefundSavedFromTheListIsOneStepAndHoldsItsPurchase() throws {
    let kettle = try purchase()
    try repository.save(kettle)
    try showDatabase()
    let back = try refund(1_000, of: kettle).materialize(now: at(minute: 30))
    XCTAssertTrue(store.save(back))
    try showDatabase()
    XCTAssertEqual(store.planDeletion(ids: [kettle.id]).skipped.map(\.reason), [.hasRefunds])
    XCTAssertEqual(
      store.listing?.refundIndex.refunded(part: kettle.parts[0].id), AmountE4(whole: 1_000))
    store.undo()
    try showDatabase()
    XCTAssertNil(try repository.entry(id: back.id))
    XCTAssertEqual(store.planDeletion(ids: [kettle.id]).changedIds, [kettle.id])
  }

  func testDeletingARefundGivesThePurchaseItsMoneyBack() throws {
    let kettle = try purchase()
    try repository.save(kettle)
    let back = try refund(1_000, of: kettle).materialize(now: at(minute: 30))
    try repository.save(back)
    try showDatabase()
    XCTAssertTrue(store.delete(id: back.id))
    try showDatabase()
    XCTAssertEqual(store.listing?.refundIndex.refunded(part: kettle.parts[0].id), .zero)
    store.undo()
    try showDatabase()
    XCTAssertEqual(
      store.listing?.refundIndex.refunded(part: kettle.parts[0].id), AmountE4(whole: 1_000))
  }

  func testARefundIsListedOnTheSpendingSideWithItsPurchaseNamed() throws {
    let kettle = try purchase()
    try repository.save(kettle)
    let back = try refund(nil, of: kettle).materialize(now: at(minute: 30))
    try repository.save(back)
    try showDatabase()
    let ledger = try XCTUnwrap(store.listing)
    let shown = TransactionListing.build(matching: .none, in: ledger)
    let row = try XCTUnwrap(shown.sections.flatMap(\.rows).first { $0.transactionId == back.id })
    XCTAssertNotNil(row.refund)
    XCTAssertEqual(shown.sections.map(\.side), [.expenses])
  }
}
