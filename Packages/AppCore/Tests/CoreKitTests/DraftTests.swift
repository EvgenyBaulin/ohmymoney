import Foundation
import Testing

@testable import CoreKit

@Suite("Drafts keep parts and totals in step")
struct DraftTests {
  @Test func singlePartDraftIsBalanced() {
    var draft = TransactionDraft(amount: AmountE4(whole: 250))
    draft.normalizeSinglePart()
    #expect(draft.isBalanced)
    #expect(draft.unallocated.isZero)
  }

  @Test func splitMustAddUpToTheTotal() {
    var draft = TransactionDraft(amount: try! AmountE4(decimal: Decimal(string: "1234.50")!))
    draft.parts = [
      PartDraft(amount: try! AmountE4(decimal: Decimal(string: "1000.00")!)),
      PartDraft(amount: try! AmountE4(decimal: Decimal(string: "200.00")!)),
    ]
    #expect(draft.isBalanced == false)
    #expect(draft.unallocated.decimal == Decimal(string: "34.50")!)

    draft.parts.append(PartDraft(amount: try! AmountE4(decimal: Decimal(string: "34.50")!)))
    #expect(draft.isBalanced)
  }

  @Test func rubleSharesOfAForeignSplitAddUpToTheConvertedTotal() throws {
    var draft = TransactionDraft(currency: .usd, amount: AmountE4(whole: 100))
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 33)),
      PartDraft(amount: AmountE4(whole: 33)),
      PartDraft(amount: AmountE4(whole: 34)),
    ]
    let rate = Rate(
      date: DateOnly(year: 2026, month: 9, day: 16), currency: .usd,
      rubPerUnit: Decimal(string: "81.4321")!)
    let entry = try draft.materialize(rublesConverter: { try rate.toRubles($0) })

    #expect(entry.isBalanced)
    let rubles = AmountE4.sum(entry.parts.map(\.amountRubE4))
    #expect(rubles == entry.transaction.amountRubE4)
  }

  /// The exact shares, pinned before the rule moved into `AmountE4.allocated`:
  /// every part but the last is rounded half away from zero, the last takes the rest.
  @Test func rubleSharesAreRoundedAndTheLastPartTakesTheRest() throws {
    var draft = TransactionDraft(currency: .usd, amount: AmountE4(whole: 10))
    draft.parts = [
      PartDraft(amount: AmountE4(raw: 33_300)),
      PartDraft(amount: AmountE4(raw: 33_300)),
      PartDraft(amount: AmountE4(raw: 33_400)),
    ]
    let rate = Rate(
      date: DateOnly(year: 2026, month: 9, day: 16), currency: .usd,
      rubPerUnit: Decimal(string: "81.4321")!)
    let entry = try draft.materialize(rublesConverter: { try rate.toRubles($0) })
    // 8 143.2100 ₽ × 0.333 = 2 711.688 93 → 2 711.6889 for each of the first two parts.
    #expect(entry.transaction.amountRubE4 == AmountE4(raw: 8_143_210))
    #expect(entry.parts.map(\.amountRubE4.raw) == [2_711_689, 2_711_689, 2_719_832])

    // Exactly half a unit goes away from zero, on both sides of it.
    var halves = TransactionDraft(amount: AmountE4(raw: 2))
    halves.parts = [PartDraft(amount: AmountE4(raw: 1)), PartDraft(amount: AmountE4(raw: 1))]
    let up = try halves.materialize(rublesConverter: { _ in AmountE4(raw: 5) })
    #expect(up.parts.map(\.amountRubE4.raw) == [3, 2])
    let down = try halves.materialize(rublesConverter: { _ in AmountE4(raw: -5) })
    #expect(down.parts.map(\.amountRubE4.raw) == [-3, -2])

    // A zero total leaves every part at zero rubles.
    var empty = TransactionDraft(amount: .zero)
    empty.parts = [PartDraft(amount: .zero), PartDraft(amount: .zero)]
    let zero = try empty.materialize(rublesConverter: { _ in AmountE4(raw: 7) })
    #expect(zero.parts.map(\.amountRubE4) == [.zero, .zero])
  }

  @Test func partPaidForSomeoneElseGetsAnExpectedStatus() throws {
    var draft = TransactionDraft(amount: AmountE4(whole: 1_000))
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 500)),
      PartDraft(amount: AmountE4(whole: 500), reimbursable: true, debtorPersonId: UUID()),
    ]
    let entry = try draft.materialize()
    #expect(entry.parts[0].reimbursementStatus == nil)
    #expect(entry.parts[1].reimbursementStatus == .expected)
  }

  /// Editing an operation changes what the panel edits and nothing else: when it was
  /// created and which import it came from are facts about the operation, and a lost
  /// `external_id` would let the same bank row be imported twice.
  @Test func editingASavedOperationKeepsWhenAndWhereItCameFrom() throws {
    let created = Date(timeIntervalSince1970: 1_780_000_000)
    let batch = UUID()
    var original = try TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
      .withSinglePart().materialize(now: created)
    original.transaction.importBatchId = batch
    original.transaction.externalId = "bank:0042"

    var draft = TransactionDraft(entry: original)
    draft.amount = AmountE4(whole: 400)
    draft.normalizeSinglePart()
    let later = created.addingTimeInterval(3600)
    let edited = try draft.materialize(updating: original, now: later)

    #expect(edited.transaction.id == original.transaction.id)
    #expect(edited.transaction.amountE4 == AmountE4(whole: 400))
    #expect(edited.transaction.createdAt == created)
    #expect(edited.transaction.updatedAt == later)
    #expect(edited.transaction.importBatchId == batch)
    #expect(edited.transaction.externalId == "bank:0042")
    #expect(edited.parts.map(\.id) == original.parts.map(\.id))
    #expect(edited.parts.allSatisfy { $0.transactionId == original.transaction.id })
  }

  /// An editor holds the copy it was opened with. Laid over the operation as it is when
  /// saved, the edit keeps what happened elsewhere meanwhile and the panel does not edit:
  /// a part that came back stays returned — writing the old «expected» back would list it
  /// as owed again while its link says the money came — a part written off stays so, and
  /// a deleted operation stays deleted. What the panel edits comes from the edit.
  @Test func anEditLaidOverTheOperationAsItIsNowKeepsWhatHappenedElsewhere() throws {
    let created = Date(timeIntervalSince1970: 1_780_000_000)
    let debtor = UUID()
    var dinner = TransactionDraft(amount: AmountE4(whole: 4_800), note: "Dinner")
    dinner.parts = [
      PartDraft(amount: AmountE4(whole: 1_600)),
      PartDraft(amount: AmountE4(whole: 1_600), reimbursable: true, debtorPersonId: debtor),
      PartDraft(amount: AmountE4(whole: 1_600), reimbursable: true, debtorPersonId: debtor),
    ]
    let opened = try dinner.materialize(now: created)
    #expect(opened.parts.map(\.reimbursementStatus) == [nil, .expected, .expected])

    // Elsewhere: one part came back, one was written off, then the operation was deleted.
    var current = opened
    current.parts[1].reimbursementStatus = .returned
    current.parts[2].reimbursementStatus = .writtenOff
    current.transaction.deletedAt = created.addingTimeInterval(60)

    // Here, on the copy opened before that: a new note, and a fourth part for the friend.
    var edit = TransactionDraft(entry: opened)
    edit.note = "Dinner with Alex"
    edit.amount = AmountE4(whole: 5_000)
    edit.parts.append(
      PartDraft(amount: AmountE4(whole: 200), reimbursable: true, debtorPersonId: debtor))
    let edited = try edit.materialize(updating: opened, now: created.addingTimeInterval(120))

    let saved = edited.rebased(onto: current)
    #expect(saved.transaction.note == "Dinner with Alex")
    #expect(saved.transaction.amountE4 == AmountE4(whole: 5_000))
    #expect(saved.parts.map(\.reimbursementStatus) == [nil, .returned, .writtenOff, .expected])
    #expect(saved.transaction.deletedAt == current.transaction.deletedAt)
    #expect(saved.transaction.updatedAt == edited.transaction.updatedAt)
    #expect(saved.isBalanced)

    // A part the edit no longer pays for somebody else waits for nobody.
    var mine = TransactionDraft(entry: opened)
    mine.parts[1].reimbursable = false
    let unowed = try mine.materialize(updating: opened).rebased(onto: current)
    #expect(unowed.parts[1].reimbursementStatus == nil)
  }

  @Test func anOperationIsFiledUnderACategoryOfItsOwnKind() {
    #expect(TransactionKind.expense.categoryKind == .expense)
    #expect(TransactionKind.refund.categoryKind == .expense)
    #expect(TransactionKind.reimbursement.categoryKind == .expense)
    #expect(TransactionKind.income.categoryKind == .income)
  }
}

@Suite("A leg in rubles is the operation's rubles")
struct RubleLegTests {
  private static let rate = Decimal(string: "81.4321")!

  /// A USD purchase on a card that holds rubles only, with what the card was charged.
  private func purchase(leg: AmountE4?, split: [Int64] = [30, 20]) -> TransactionDraft {
    var draft = TransactionDraft(
      kind: .expense, currency: .usd, amount: AmountE4(whole: 50), rate: Self.rate,
      rateDate: DateOnly(year: 2026, month: 9, day: 16), rateSource: .cbr,
      rateProvisional: true, paymentMethodId: UUID(), accountCurrency: leg == nil ? nil : .rub,
      accountAmount: leg)
    draft.parts = split.map { PartDraft(amount: AmountE4(whole: $0)) }
    return draft
  }

  private func converter(_ amount: AmountE4) throws -> AmountE4 {
    try AmountE4(decimal: amount.decimal * Self.rate)
  }

  /// Left as the prefill gave it — exactly what the rate gives — the leg keeps the bank's
  /// rate, its source and whether it is provisional, so the rubles are refined with the rate.
  @Test func anUntouchedLegKeepsTheBanksRate() throws {
    let prefill = try converter(AmountE4(whole: 50))
    let entry = try purchase(leg: prefill).materialize(rublesConverter: converter)

    #expect(entry.transaction.amountRubE4 == prefill)
    #expect(entry.transaction.rate == Self.rate)
    #expect(entry.transaction.rateSource == .cbr)
    #expect(entry.transaction.rateProvisional)
    #expect(entry.transaction.accountCurrency == .rub)
    #expect(entry.transaction.accountAmountE4 == prefill)
    #expect(entry.transaction.movedMoney == Money(amount: prefill, currency: .rub))
    #expect(AmountE4.sum(entry.parts.map(\.amountRubE4)) == prefill)
  }

  /// Typed from the statement, the leg is what the purchase cost: the rubles are the leg to
  /// the unit, split over the parts as always, and the rate becomes the one it implies — a
  /// manual rate, final, which no refinement touches.
  @Test func aTypedLegIsTheRublesWithTheRateItImplies() throws {
    let charged = AmountE4(raw: 41_937_600)  // 4 193.76 ₽: 3 % above the bank's rate
    let entry = try purchase(leg: charged).materialize(rublesConverter: converter)

    #expect(entry.transaction.amountRubE4 == charged)
    #expect(entry.transaction.rate == Decimal(string: "83.8752"))
    #expect(entry.transaction.rateSource == .manual)
    #expect(entry.transaction.rateProvisional == false)
    #expect(entry.transaction.rateDate == DateOnly(year: 2026, month: 9, day: 16))
    #expect(entry.parts.map(\.amountRubE4.raw) == [25_162_560, 16_775_040])
    #expect(AmountE4.sum(entry.parts.map(\.amountRubE4)) == charged)
  }

  /// The implied rate is kept to six places.
  @Test func theImpliedRateIsRoundedToSixPlaces() throws {
    var draft = purchase(leg: AmountE4(whole: 1_000), split: [3])
    draft.amount = AmountE4(whole: 3)
    let entry = try draft.materialize(rublesConverter: converter)
    #expect(entry.transaction.amountRubE4 == AmountE4(whole: 1_000))
    #expect(entry.transaction.rate == Decimal(string: "333.333333"))
  }

  /// With no rate for the day at all, a leg in rubles still gives the operation its rubles:
  /// nothing has to be converted.
  @Test func aLegNeedsNoRate() throws {
    var draft = purchase(leg: AmountE4(whole: 4_100))
    draft.rate = nil
    draft.rateSource = nil
    let entry = try draft.materialize(rublesConverter: { _ in throw CoreError.amountOutOfRange })
    #expect(entry.transaction.amountRubE4 == AmountE4(whole: 4_100))
    #expect(entry.transaction.rate == Decimal(82))
    #expect(entry.transaction.rateSource == .manual)
  }

  /// A leg in another currency is only the money that moved: the rubles are the bank's.
  @Test func aLegInAnotherCurrencyLeavesTheRublesToTheRate() throws {
    var draft = purchase(leg: AmountE4(whole: 23_000))
    draft.accountCurrency = CurrencyCode("KZT")
    let entry = try draft.materialize(rublesConverter: converter)
    #expect(entry.transaction.amountRubE4 == (try converter(AmountE4(whole: 50))))
    #expect(entry.transaction.rateSource == .cbr)
    #expect(entry.transaction.accountAmountE4 == AmountE4(whole: 23_000))
  }

  /// A refund taken back from a purchase keeps the purchase's rate, whatever its leg: a full
  /// refund then gives back exactly the rubles the purchase cost.
  @Test func aRefundOfAPurchaseKeepsItsRate() throws {
    var draft = purchase(leg: AmountE4(whole: 4_300), split: [50])
    draft.kind = .refund
    draft.parts[0].refundOfPartId = UUID()
    let entry = try draft.materialize(rublesConverter: converter)
    #expect(entry.transaction.amountRubE4 == (try converter(AmountE4(whole: 50))))
    #expect(entry.transaction.rate == Self.rate)
    #expect(entry.transaction.rateSource == .cbr)
    #expect(entry.transaction.accountAmountE4 == AmountE4(whole: 4_300))
    #expect(entry.parts[0].refundOfPartId == draft.parts[0].refundOfPartId)
  }

  /// Reopened for editing, the draft carries the leg and the refund link, and so does the
  /// operation it is saved as.
  @Test func theLegAndTheRefundLinkSurviveAnEdit() throws {
    var draft = purchase(leg: AmountE4(whole: 4_300), split: [50])
    draft.parts[0].refundOfPartId = UUID()
    let saved = try draft.materialize(rublesConverter: converter)
    let reopened = TransactionDraft(entry: saved)
    #expect(reopened.accountCurrency == .rub)
    #expect(reopened.accountAmount == AmountE4(whole: 4_300))
    #expect(reopened.parts[0].refundOfPartId == draft.parts[0].refundOfPartId)

    var edited = reopened
    edited.accountAmount = AmountE4(whole: 4_250)
    let again = try edited.materialize(updating: saved, rublesConverter: converter)
    #expect(again.transaction.accountAmountE4 == AmountE4(whole: 4_250))
    #expect(again.parts[0].refundOfPartId == draft.parts[0].refundOfPartId)
  }
}

extension TransactionDraft {
  fileprivate func withSinglePart() -> TransactionDraft {
    var copy = self
    copy.normalizeSinglePart()
    return copy
  }
}
