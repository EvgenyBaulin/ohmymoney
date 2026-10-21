import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Which fields each kind of operation has, and what becomes of the others.
@Suite("Fields of each kind of operation")
struct KindFieldsTests {
  let categories = StartingCategories()

  @Test func incomeHasNoneOfTheCutsOfSpending() {
    let income = KindFields.fields(of: .income)
    for field in [OperationField.place, .event, .forWhom, .forPerson, .reimbursable, .credit] {
      #expect(!income.contains(field), "\(field)")
    }
    #expect(income.isSuperset(of: [.account, .accountCharge, .category, .periodMonth, .split]))
  }

  @Test func aRefundHasWhatAPurchaseHasButCreditAndDebts() {
    let expense = KindFields.fields(of: .expense)
    let refund = KindFields.fields(of: .refund)
    #expect(!refund.contains(.credit))
    #expect(!refund.contains(.debt))
    #expect(refund.contains(.refundOf))
    #expect(expense.subtracting([.credit, .debt, .debtor, .cashback]).isSubset(of: refund))
  }

  /// Only a purchase has a cashback of its own: income, a refund and money back have none.
  @Test func cashbackOnlyOnExpense() {
    for kind in TransactionKind.allCases {
      #expect(KindFields.fields(of: kind).contains(.cashback) == (kind == .expense), "\(kind)")
    }
  }

  /// A contribution to a goal moves no card money: it earns nothing.
  @Test func goalOnlyHasNoCashback() {
    #expect(!KindFields.fields(of: .expense, goalOnly: true).contains(.cashback))
    #expect(KindFields.fields(of: .expense, goalOnly: true).contains(.card))
  }

  /// A purchase, income and a refund name the card that paid or took the money; money back is
  /// money from a person onto an account and names none.
  @Test func cardWhereverTheAccountIs() {
    #expect(KindFields.fields(of: .expense).contains(.card))
    #expect(KindFields.fields(of: .income).contains(.card))
    #expect(KindFields.fields(of: .refund).contains(.card))
    #expect(!KindFields.fields(of: .reimbursement).contains(.card))
  }

  /// A draft that turns into income loses its cashback; its card stays. A draft that turns into
  /// money back loses its card too.
  @Test func strippedDropsCashbackOfIncome() {
    let cashback = Money(amount: money(35), currency: .rub)
    var draft = TransactionDraft(
      kind: .income, amount: money(5000), paymentMethodId: id(1),
      parts: [PartDraft(categoryId: categories.salary, amount: money(5000))], cardId: id(2),
      cashback: cashback)
    var stripped = KindFields.stripped(draft, tree: categories.tree).draft
    #expect(stripped.cashback == nil)
    #expect(stripped.cardId == id(2))
    draft.kind = .reimbursement
    stripped = KindFields.stripped(draft, tree: categories.tree).draft
    #expect(stripped.cardId == nil)
    draft.kind = .expense
    draft.parts = [PartDraft(categoryId: categories.groceries, amount: money(5000))]
    stripped = KindFields.stripped(draft, tree: categories.tree).draft
    #expect(stripped.cashback == cashback)
    draft.parts = [PartDraft(categoryId: categories.goalsTrip, amount: money(5000))]
    stripped = KindFields.stripped(draft, tree: categories.tree).draft
    #expect(stripped.cashback == nil)
  }

  @Test func moneyBackIsMoneyFromAPersonOntoAnAccount() {
    #expect(
      KindFields.fields(of: .reimbursement) == [
        .account, .accountCharge, .fromPerson, .debt, .note,
      ])
  }

  @Test func anOperationOnlyForGoalsIsChargedNothing() {
    #expect(!KindFields.fields(of: .expense, goalOnly: true).contains(.accountCharge))
    #expect(KindFields.fields(of: .expense, goalOnly: true).contains(.account))
    #expect(KindFields.fields(of: .expense, goalOnly: false).contains(.accountCharge))
  }

  /// «+5000 для мамы»: income of 5 000, and «для мамы» goes to the note.
  @Test func whatIncomeCannotHaveGoesToTheNote() {
    var draft = TransactionDraft(
      kind: .income, currency: .rub, amount: money(5000), placeId: id(51),
      creditDebtId: id(200),
      parts: [
        PartDraft(
          categoryId: categories.salary, amount: money(5000), forWhom: .family,
          forPersonId: id(60), eventId: id(70))
      ])
    draft.periodMonth = MonthKey(year: 2026, month: 3)
    let result = KindFields.stripped(
      draft, words: [.forPerson: ["для", "мамы"], .category: ["зарплата"]],
      tree: categories.tree)
    #expect(result.toNote == ["для", "мамы"])
    #expect(result.draft.placeId == nil)
    #expect(result.draft.creditDebtId == nil)
    #expect(result.draft.periodMonth == MonthKey(year: 2026, month: 3))
    #expect(result.draft.parts[0].forWhom == .me)
    #expect(result.draft.parts[0].forPersonId == nil)
    #expect(result.draft.parts[0].eventId == nil)
    #expect(result.draft.parts[0].categoryId == categories.salary)
  }

  /// The person money came back from is the person of its part: it stays.
  @Test func moneyBackKeepsItsPerson() {
    let draft = TransactionDraft(
      kind: .reimbursement, amount: money(700), placeId: id(51),
      parts: [
        PartDraft(
          categoryId: categories.groceries, quality: .good, amount: money(700),
          forPersonId: id(40), reimbursable: true, debtorPersonId: id(41), eventId: id(70),
          goalId: id(80))
      ])
    let stripped = KindFields.stripped(draft, tree: categories.tree).draft
    #expect(stripped.parts[0].forPersonId == id(40))
    #expect(stripped.placeId == nil)
    #expect(stripped.parts[0].eventId == nil)
    #expect(stripped.parts[0].goalId == nil)
    #expect(stripped.parts[0].debtorPersonId == nil)
    #expect(!stripped.parts[0].reimbursable)
    #expect(stripped.parts[0].categoryId == nil)
    #expect(stripped.parts[0].quality == nil)
  }

  @Test func moneyBackIsNeverSplit() {
    let draft = TransactionDraft(
      kind: .reimbursement, amount: money(700),
      parts: [
        PartDraft(amount: money(500), forPersonId: id(40)), PartDraft(amount: money(200)),
      ])
    let stripped = KindFields.stripped(draft).draft
    #expect(stripped.parts.count == 1)
    #expect(stripped.parts[0].amount == money(700))
    #expect(stripped.parts[0].forPersonId == id(40))
  }

  @Test func aContributionToAGoalHasNoCharge() {
    let draft = TransactionDraft(
      kind: .expense, currency: .usd, amount: money(100), paymentMethodId: id(1),
      accountCurrency: .rub, accountAmount: money(9500),
      parts: [PartDraft(categoryId: categories.goalsTrip, amount: money(100))])
    let stripped = KindFields.stripped(draft, tree: categories.tree).draft
    #expect(stripped.accountCurrency == nil)
    #expect(stripped.accountAmount == nil)
    #expect(stripped.paymentMethodId == id(1))
  }

  @Test func aPurchaseKeepsEverything() {
    let draft = TransactionDraft(
      kind: .expense, amount: money(700), placeId: id(51), creditDebtId: id(200),
      parts: [
        PartDraft(
          categoryId: categories.groceries, amount: money(700), forWhom: .friends,
          forPersonId: id(40), reimbursable: true, debtorPersonId: id(41), eventId: id(70))
      ])
    let result = KindFields.stripped(draft, words: [.place: ["в", "кафе"]], tree: categories.tree)
    #expect(result.draft == draft)
    #expect(result.toNote.isEmpty)
  }

  /// Income stored with a place, an event and a person keeps them in the database; the rules
  /// read it without them.
  @Test func incomeIsReadWithoutWhatItCannotHave() {
    let stored = entry(
      id(1), kind: .income, creditDebtId: id(200),
      parts: [
        TransactionPart(
          id: id(11), transactionId: id(1), categoryId: categories.salary,
          amountE4: money(5000), forWhom: .family, forPersonId: id(60), reimbursable: true,
          debtorPersonId: id(61), reimbursementStatus: .expected, eventId: id(70))
      ])
    var withPlace = stored
    withPlace.transaction.placeId = id(51)
    let masked = KindFields.masked(withPlace)
    #expect(masked.transaction.placeId == nil)
    #expect(masked.transaction.creditDebtId == nil)
    #expect(masked.parts[0].forWhom == .me)
    #expect(masked.parts[0].forPersonId == nil)
    #expect(masked.parts[0].debtorPersonId == nil)
    #expect(masked.parts[0].eventId == nil)
    #expect(!masked.parts[0].reimbursable)
    #expect(masked.parts[0].reimbursementStatus == nil)
    #expect(masked.parts[0].categoryId == categories.salary)
    #expect(masked.parts[0].amountE4 == money(5000))
  }

  @Test func everyOtherKindIsReadAsStored() {
    let refund = entry(
      id(1), kind: .refund,
      parts: [part(id(11), amount: money(100), forWhom: .friends, reimbursable: true)])
    let back = entry(id(2), kind: .reimbursement, parts: [part(id(21), amount: money(100))])
    #expect(KindFields.masked(refund) == refund)
    #expect(KindFields.masked(back) == back)
  }
}
