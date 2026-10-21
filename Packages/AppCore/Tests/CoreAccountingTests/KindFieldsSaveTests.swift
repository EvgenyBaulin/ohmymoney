import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// What the save writes is the draft without the fields its kind lacks (`KindFields.stripped`),
/// while the ↓ panel decides whether «Сохранить» is allowed on the draft as it is. Taking fields
/// away must never turn a draft the panel let through into one the rules refuse.
@Suite("A stripped draft is still one the rules accept")
struct KindFieldsSaveTests {
  let categories = StartingCategories()

  /// The problems that stop a save, as the ↓ panel reads them: a missing category is none — an
  /// operation may stay uncategorised.
  func blocking(_ draft: TransactionDraft) -> [SplitProblem] {
    SplitValidator.validate(draft, categories: categories.tree).problems.filter {
      if case .categoryMissing = $0 { return false }
      return true
    }
  }

  /// A draft of `kind` the owner could put together in the panel: categories of its own kind, a
  /// goal part filed under the goal's subcategory, a part «за другого» naming who pays it back,
  /// and every other field at random.
  func plausible(_ kind: TransactionKind, _ dice: inout MoneyDice) -> TransactionDraft {
    let parts = (0..<(kind == .reimbursement ? dice.int(1...2) : dice.int(1...3))).map {
      index in
      var part = PartDraft(id: id(10 + index), amount: dice.amount(upTo: 900))
      switch kind {
      case .income:
        part.categoryId = dice.pick([categories.salary, categories.bonus])
      case .expense, .refund:
        if dice.chance(25) {
          part.categoryId = categories.goalsTrip
          part.goalId = id(600)
        } else {
          part.categoryId = dice.pick([categories.groceries, categories.fuel, categories.education])
        }
      case .reimbursement:
        part.forPersonId = id(300)
      }
      if dice.chance(40) { part.eventId = id(400) }
      if dice.chance(40) { part.forWhom = dice.pick([.partner, .friends, .family, .other]) }
      if kind != .reimbursement, dice.chance(30) { part.forPersonId = id(302) }
      if dice.chance(35) {
        part.reimbursable = true
        part.debtorPersonId = id(301)
        part.reimbursementStatus = .expected
      }
      if kind == .refund, dice.chance(50) { part.refundOfPartId = id(700 + index) }
      return part
    }
    return TransactionDraft(
      kind: kind, occurredAt: moment("2026-03-02"), currency: dice.pick([.rub, .usd]),
      amount: AmountE4.sum(parts.map(\.amount)), rate: 90,
      placeId: dice.chance(50) ? id(500) : nil, paymentMethodId: id(1),
      accountCurrency: dice.chance(50) ? .rub : nil,
      accountAmount: nil,
      periodMonth: kind == .income && dice.chance(30) ? MonthKey(year: 2026, month: 2) : nil,
      debtId: dice.chance(10) ? id(200) : nil,
      creditDebtId: kind == .expense && dice.chance(10) ? id(201) : nil,
      parts: parts)
  }

  /// A draft of any kind that the panel lets through is still accepted after the fields its kind
  /// lacks are taken away: stripping never leaves a part «за другого» without the person who pays
  /// it back, nor a goal part without its goal.
  @Test(arguments: Array(1...60) as [UInt64])
  func aStrippedDraftOfAnyKindSavesWhenTheDraftDid(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    for kind in TransactionKind.allCases {
      var draft = plausible(kind, &dice)
      if draft.accountCurrency != nil { draft.accountAmount = dice.amount(upTo: 90_000) }
      guard blocking(draft).isEmpty else { continue }
      let stripped = KindFields.stripped(draft, tree: categories.tree).draft
      #expect(blocking(stripped).isEmpty, "seed \(seed), \(kind): \(blocking(stripped))")
    }
  }

  /// A refund of something bought for Аня — «за другого» with Аня as the one who pays it back:
  /// the refund has everything a purchase has except credit, so it keeps Аня. Without her the
  /// refund would be written as a part «за другого» that names nobody, which every later edit
  /// refuses with «нужен тот, кто вернёт».
  @Test func aRefundForSomebodyElseKeepsWhoPaysItBack() {
    let draft = TransactionDraft(
      kind: .refund, occurredAt: moment("2026-03-02"), amount: money(500),
      paymentMethodId: id(1),
      parts: [
        PartDraft(
          categoryId: categories.groceries, amount: money(500), forWhom: .friends,
          reimbursable: true, debtorPersonId: id(301), reimbursementStatus: .expected)
      ])
    #expect(blocking(draft).isEmpty)
    let (stripped, toNote) = KindFields.stripped(draft, words: [.debtor: ["Аня"]])
    #expect(stripped.parts.map(\.debtorPersonId) == [id(301)])
    #expect(stripped.parts.map(\.reimbursable) == [true])
    #expect(stripped.parts.map(\.reimbursementStatus) == [.expected])
    #expect(toNote.isEmpty)
    #expect(blocking(stripped).isEmpty)
    #expect(KindFields.fields(of: .refund).contains(.debtor))
  }

  /// The table of fields: a refund has what a purchase has, less credit, a payment on a debt and
  /// a cashback of its own, plus the purchase part it takes back from.
  @Test func aRefundHasWhatAPurchaseHasButCreditAndDebt() {
    let purchase = KindFields.fields(of: .expense)
    let refund = KindFields.fields(of: .refund)
    #expect(purchase.subtracting([.credit, .debt, .cashback]).union([.refundOf]) == refund)
  }

  /// Money back is one part. Two parts naming two people — the line and the panel never make
  /// such a draft — become one part of the first person: the kind has one person it came from.
  /// The second person's words stay where they were typed, since the field is one the kind has.
  @Test func aMoneyBackOfTwoPeopleKeepsTheFirst() {
    let draft = TransactionDraft(
      kind: .reimbursement, occurredAt: moment("2026-03-02"), amount: money(700),
      paymentMethodId: id(1),
      parts: [
        PartDraft(id: id(10), amount: money(300), forPersonId: id(300)),
        PartDraft(id: id(11), amount: money(400), forPersonId: id(301)),
      ])
    let (stripped, toNote) = KindFields.stripped(draft)
    #expect(stripped.parts.map(\.id) == [id(10)])
    #expect(stripped.parts.map(\.forPersonId) == [id(300)])
    #expect(stripped.parts.map(\.amount) == [money(700)])
    #expect(toNote.isEmpty)
  }
}
