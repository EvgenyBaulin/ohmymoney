import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// «За кого»: Себе, За другого (вернёт или подарок), Пополам, Поровну на N — laid out as the
/// parts the ledger already understands, and read back from them.
@Suite("За кого: себе, за другого, пополам, поровну")
struct PayingForTests {
  private let masha = UUID()
  private let petya = UUID()
  private let cafe = UUID()

  private func dinner(_ whole: Int64 = 1_200) -> TransactionDraft {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: Date(), amount: AmountE4(whole: whole), note: "ужин")
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = cafe
    return draft
  }

  private func totals(_ draft: TransactionDraft) throws -> RowTotals {
    RowTotals(entries: [try draft.materialize()])
  }

  @Test func meIsOnePartOfMine() {
    let laid = PayingForRules.laying(.me, on: dinner())
    #expect(laid.parts.count == 1 && !laid.parts[0].reimbursable)
    #expect(PayingForRules.reading(of: laid) == .me)
  }

  @Test func forSomebodyWhoPaysBackIsOwedToMe() {
    let laid = PayingForRules.laying(.somebody(masha, paysBack: true), on: dinner())
    #expect(laid.parts.count == 1)
    #expect(laid.parts[0].reimbursable && laid.parts[0].debtorPersonId == masha)
    #expect(PayingForRules.reading(of: laid) == .somebody(masha, paysBack: true))
    let outcome = PayingForRules.outcome(
      of: .somebody(masha, paysBack: true), total: AmountE4(whole: 1_200))
    #expect(outcome.mine == .zero && outcome.owed.first?.amount == AmountE4(whole: 1_200))
  }

  @Test func aGiftIsForThePersonAndOwesNothing() {
    let laid = PayingForRules.laying(.somebody(masha, paysBack: false), on: dinner())
    #expect(!laid.parts[0].reimbursable && laid.parts[0].forPersonId == masha)
    #expect(laid.parts[0].forWhom == .other)
    #expect(PayingForRules.reading(of: laid) == .somebody(masha, paysBack: false))
    #expect(
      PayingForRules.outcome(of: .somebody(masha, paysBack: false), total: AmountE4(whole: 1))
        .giftFor == masha)
  }

  @Test func halfIsMyHalfAndTheOtherOwed() {
    let laid = PayingForRules.laying(.half(masha), on: dinner())
    #expect(laid.parts.map(\.amount) == [AmountE4(whole: 600), AmountE4(whole: 600)])
    #expect(!laid.parts[0].reimbursable && laid.parts[1].reimbursable)
    #expect(laid.parts[1].debtorPersonId == masha && laid.parts[1].categoryId == cafe)
    #expect(PayingForRules.reading(of: laid) == .half(masha))
  }

  /// A total that does not divide: the shares still add up to it, the extra going to mine.
  @Test func evenlyAddsUpToTheLastUnit() {
    let laid = PayingForRules.laying(.evenly([masha, petya]), on: dinner(1_000))
    #expect(laid.parts.count == 3)
    #expect(laid.parts.map(\.amount).reduce(.zero, +) == AmountE4(whole: 1_000))
    #expect(laid.parts[0].amount >= laid.parts[1].amount)
    #expect(PayingForRules.reading(of: laid) == .evenly([masha, petya]))
    #expect(PayingFor.evenly([masha, petya]).shareCount == 3)
  }

  /// What each choice puts into «my spending»: only my share; the parts owed stay out until they
  /// are written off; a gift is spending «на кого» the person, mine all the same.
  @Test func mySpendingIsMyShare() throws {
    let half = try totals(PayingForRules.laying(.half(masha), on: dinner()))
    #expect(half.myExpenses == AmountE4(whole: 600) && half.forOthers == AmountE4(whole: 600))
    let owed = try totals(PayingForRules.laying(.somebody(masha, paysBack: true), on: dinner()))
    #expect(owed.myExpenses == .zero && owed.forOthers == AmountE4(whole: 1_200))
    let gift = try totals(PayingForRules.laying(.somebody(masha, paysBack: false), on: dinner()))
    #expect(gift.myExpenses == AmountE4(whole: 1_200) && gift.forOthers == .zero)
    let me = try totals(PayingForRules.laying(.me, on: dinner()))
    #expect(me.myExpenses == AmountE4(whole: 1_200))
  }

  /// Back to «Себе» from a half: one part of the whole amount again.
  @Test func choosingAgainLaysTheWholeAnew() {
    let half = PayingForRules.laying(.half(masha), on: dinner())
    let back = PayingForRules.laying(.me, on: half)
    #expect(back.parts.count == 1 && back.parts[0].amount == AmountE4(whole: 1_200))
    #expect(!back.parts[0].reimbursable && back.parts[0].debtorPersonId == nil)
  }

  @Test func onlyAnExpenseIsPaidForSomebody() {
    var income = dinner()
    income.kind = .income
    #expect(PayingForRules.laying(.half(masha), on: income) == income)
  }

  /// Parts split by hand in another way are not one of the four.
  @Test func unequalPartsAreNotReadAsAChoice() {
    var laid = PayingForRules.laying(.half(masha), on: dinner())
    laid.parts[0].amount = AmountE4(whole: 700)
    laid.parts[1].amount = AmountE4(whole: 500)
    #expect(PayingForRules.reading(of: laid) == nil)
  }
}
