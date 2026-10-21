import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// «Рассрочка»: parts to the kopeck, dues every fourteen days, the markup part by part, a
/// returned thing, sums typed from the bank's app.
@Suite("Instalment plans: parts, steps of days, markup, return")
struct InstalmentPlanTests {
  static let purchaseDay = day("2026-10-12")

  static func plan(markup: String? = nil, parts: Int = 4) -> Debt {
    Debt(
      id: id(70), direction: .iOwe, type: .installment, name: "Vacuum", paymentsAreExpenses: false,
      origin: .purchase, steps: DebtSteps(everyDays: 14, firstDue: purchaseDay), parts: parts,
      markupE4: markup.map(money), termsReviewed: true)
  }

  static func borrowed(_ amount: String) -> DebtEntry {
    DebtEntry(
      id: id(7000), debtId: id(70), date: purchaseDay, amountE4: money(amount), kind: .borrowed)
  }

  static func paid(_ iso: String, _ amount: String, number: Int) -> DebtEntry {
    DebtEntry(
      id: id(number), debtId: id(70), date: day(iso), amountE4: money("-" + amount),
      kind: .payment)
  }

  static func state(_ debt: Debt, journal: [DebtEntry], today: String) -> DebtDueState {
    var sketch = Sketch()
    sketch.debts = [debt]
    return DebtDues.states(
      debts: [debt], ledger: sketch.ledger, journal: journal, today: day(today))[debt.id]
      ?? .none(of: debt.id)
  }

  @Test func partsAreEqualToTheKopeckWithTheRestInTheLast() {
    #expect(
      InstalmentPlan.parts(total: money("9999"), count: 4)
        == Array(repeating: money("2499.75"), count: 4))
    #expect(
      InstalmentPlan.parts(total: money("1000"), count: 3)
        == [money("333.33"), money("333.33"), money("333.34")])
    #expect(
      InstalmentPlan.parts(total: money("0.01"), count: 3) == [.zero, .zero, money("0.01")])
    #expect(
      InstalmentPlan.markupShares(markup: money("600"), count: 4)
        == Array(repeating: money("150"), count: 4))
    #expect(InstalmentPlan.parts(total: money("100"), count: 0).isEmpty)
  }

  /// Whatever the total and the count, the parts add up to the total exactly.
  @Test func partsAlwaysAddUpToTheTotal() {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<500 {
      let total = AmountE4(raw: Int64.random(in: 0...10_000_000_000, using: &generator))
      let count = Int.random(in: 1...120, using: &generator)
      let parts = InstalmentPlan.parts(total: total, count: count)
      #expect(AmountE4.sum(parts) == total)
      #expect(parts.dropLast().allSatisfy { $0.raw % 100 == 0 })
    }
  }

  @Test func dueDaysStepEveryFourteenDays() {
    let steps = DebtSteps(everyDays: 14, firstDue: Self.purchaseDay)
    #expect(
      InstalmentPlan.dueDays(steps: steps, count: 4)
        == [day("2026-10-12"), day("2026-10-26"), day("2026-11-09"), day("2026-11-23")])
  }

  /// 12,000 in four parts every two weeks from 12 October: one paid, on 27 October the second
  /// is overdue, the free sum through 9 November asks for the second and the third.
  @Test func aPlanPaidEveryTwoWeeks() {
    let debt = Self.plan()
    let journal = [Self.borrowed("12000"), Self.paid("2026-10-12", "3000", number: 7001)]
    let dues = Self.state(debt, journal: journal, today: "2026-10-27")
    #expect(dues.firstDue == Self.purchaseDay)
    #expect(dues.paidCount == 1)
    #expect(dues.due(3) == day("2026-11-23"))
    #expect(dues.overdue(today: day("2026-10-27")) == [day("2026-10-26")])
    #expect(dues.unpaid(through: day("2026-11-09")) == [day("2026-10-26"), day("2026-11-09")])
    #expect(dues.owed(through: day("2026-11-09")) == money("6000"))
    // No due after the fourth.
    #expect(dues.unpaid(through: day("2027-06-01")).count == 3)
    #expect(debt.hasDues)
  }

  @Test func makeWritesThePriceAndTheMarkupAsTheDebt() {
    let when = CalendarContext.utc.noon(of: Self.purchaseDay)
    let purchase = TransactionEntry(
      transaction: Transaction(
        id: id(71), kind: .expense, occurredAt: when, amountE4: money("10000")),
      parts: [])
    let (debt, line) = InstalmentPlan.make(
      purchase: purchase, price: money("10000"), count: 4, everyDays: 14, paymentDay: nil,
      markup: money("600"), name: "Phone", id: id(72), calendar: .utc)
    #expect(debt.isInstalmentPlan)
    #expect(debt.steps == DebtSteps(everyDays: 14, firstDue: Self.purchaseDay))
    #expect(!debt.paymentsAreExpenses)
    #expect(debt.termsReviewed)
    #expect(line.amountE4 == money("10600"))
    #expect(line.kind == .borrowed)
    #expect(line.transactionId == id(71))
    let monthly = InstalmentPlan.make(
      purchase: purchase, price: money("10000"), count: 4, everyDays: nil, paymentDay: 20,
      markup: nil, name: "Phone", id: id(73), calendar: .utc
    ).0
    #expect(monthly.steps == nil)
    #expect(monthly.paymentDay == 20)
    #expect(monthly.monthlyPaymentE4 == money("2500"))
  }

  /// 10,000 with a markup of 600 in four: each part 2,650, of it 150 markup.
  @Test func eachPaymentCarriesTheMarkupOfTheDueItCloses() {
    let debt = Self.plan(markup: "600")
    let journal = [Self.borrowed("10600")]
    let before = Self.state(debt, journal: journal, today: "2026-10-12")
    #expect(before.amount(ofDue: 0) == money("2650"))
    let split = DebtMarkup.split(
      payment: money("2650"), debt: debt, journal: journal, dues: before)
    #expect(split.interestE4 == money("150"))
    #expect(split.principalE4 == money("2500"))
    // Half a part closes no due: no markup yet.
    #expect(
      DebtMarkup.split(payment: money("1000"), debt: debt, journal: journal, dues: before)
        .interestE4 == .zero)
    // Two parts at once carry two shares.
    #expect(
      DebtMarkup.split(payment: money("5300"), debt: debt, journal: journal, dues: before)
        .interestE4 == money("300"))
    // A plan without markup is all principal.
    #expect(
      DebtMarkup.split(payment: money("2500"), debt: Self.plan(), journal: journal, dues: before)
        .interestE4 == .zero)
  }

  @Test func theMarkupKeyNamesItsPayment() {
    let key = DebtMarkup.key(ofPayment: id(5), markup: id(6))
    #expect(key.hasPrefix("debtmarkup:"))
    #expect(DebtMarkup.payment(ofKey: key) == id(5))
    #expect(DebtMarkup.payment(ofKey: "debtinterest:x:y") == nil)
  }

  /// 12,000 returned, 3,000 paid off the price: 3,000 back to the account, 9,000 off the debt;
  /// back to the card — all 12,000 to the account.
  @Test func aReturnedThingLowersTheDebtFirst() {
    let debt = Self.plan()
    let split = RefundRules.instalmentReturn(
      refund: money("12000"), debt: debt, balance: money("9000"), paidPrincipal: money("3000"),
      choice: .reducesDebt)
    #expect(split == InstalmentReturnSplit(toDebtE4: money("9000"), toAccountE4: money("3000")))
    let card = RefundRules.instalmentReturn(
      refund: money("12000"), debt: debt, balance: money("9000"), paidPrincipal: money("3000"),
      choice: .toCard)
    #expect(card == InstalmentReturnSplit(toDebtE4: .zero, toAccountE4: money("12000")))
    // A part of the thing returned: nothing paid yet — all of it off the debt.
    let half = RefundRules.instalmentReturn(
      refund: money("6000"), debt: debt, balance: money("12000"), paidPrincipal: .zero,
      choice: .reducesDebt)
    #expect(half == InstalmentReturnSplit(toDebtE4: money("6000"), toAccountE4: .zero))
    #expect(RefundRules.instalmentReturnKey(of: id(9)).hasSuffix(":debt"))
  }

  /// The sums typed from the bank's app hold over the parts worked out, until the next step.
  @Test func typedSumsHoldOverTheParts() {
    let debt = Self.plan()
    var sketch = Sketch()
    sketch.debts = [debt]
    let ledger = Ledger(
      dataset: Dataset(
        entries: sketch.entries, categories: sketch.categories, debts: [debt],
        debtInstalments: [
          DebtInstalmentStep(debtId: id(70), fromIndex: 1, amountE4: money("3100"))
        ]),
      calendar: .utc)
    let dues =
      DebtDues.states(
        debts: [debt], ledger: ledger, journal: [Self.borrowed("12000")],
        today: day("2026-10-12"))[debt.id]!
    #expect(dues.amount(ofDue: 0) == money("3000"))
    #expect(dues.amount(ofDue: 1) == money("3100"))
    // It holds until the next step: here the end of the plan.
    #expect(dues.amount(ofDue: 3) == money("3100"))
    #expect(dues.amount(ofDue: 4) == .zero)

    let merged = DebtInstalments.merged(
      computed: DebtInstalments(steps: [.init(fromIndex: 0, amountE4: money("100"))]),
      typed: [DebtInstalmentStep(debtId: id(1), fromIndex: 0, amountE4: money("90"))])
    #expect(merged.amount(at: 0) == money("90"))
    #expect(merged.amount(at: 7) == money("90"))
  }

  /// A thing bought on an instalment plan can be returned; the other operations on a debt and a
  /// purchase on credit without a plan cannot.
  @Test func aPurchaseOnAPlanCanBeRefunded() {
    let plan = Self.plan()
    let when = CalendarContext.utc.noon(of: Self.purchaseDay)
    let purchase = TransactionEntry(
      transaction: Transaction(
        id: id(71), kind: .expense, occurredAt: when, amountE4: money("12000"),
        creditDebtId: plan.id),
      parts: [TransactionPart(id: id(72), transactionId: id(71), amountE4: money("12000"))])
    let tree = CategoryTree([])
    #expect(
      RefundRules.isRefundable(part: purchase.parts[0], in: purchase, tree: tree, creditDebt: plan))
    #expect(!RefundRules.isRefundable(part: purchase.parts[0], in: purchase, tree: tree))
    var credit = plan
    credit.parts = nil
    #expect(
      !RefundRules.isRefundable(
        part: purchase.parts[0], in: purchase, tree: tree, creditDebt: credit))
    var markup = purchase
    markup.transaction.externalId = DebtMarkup.key(ofPayment: id(1), markup: id(71))
    #expect(
      !RefundRules.isRefundable(part: markup.parts[0], in: markup, tree: tree, creditDebt: plan))

    // The part of a return that lowers the debt moves no money.
    var offDebt = TransactionEntry(
      transaction: Transaction(
        id: id(73), kind: .refund, occurredAt: when, amountE4: money("9000"),
        externalId: RefundRules.instalmentReturnKey(of: id(73))),
      parts: [TransactionPart(id: id(74), transactionId: id(73), amountE4: money("9000"))])
    #expect(!AccountBalances.movesMoney(offDebt, tree: tree))
    offDebt.transaction.externalId = nil
    #expect(AccountBalances.movesMoney(offDebt, tree: tree))
  }
}
