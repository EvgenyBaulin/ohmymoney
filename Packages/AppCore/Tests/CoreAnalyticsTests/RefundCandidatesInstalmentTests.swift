import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A thing bought in instalments can be returned: its purchase is offered for a refund once the
/// list knows the plan it was bought on; a purchase on a plain credit never is.
@Suite("Возврат покупки: вещь из рассрочки")
struct RefundCandidatesInstalmentTests {
  private let calendar = CalendarContext.utc
  private let today = DateOnly(year: 2026, month: 9, day: 26)

  private func purchase(_ whole: Int64, credit: UUID?) -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: calendar.startOfDay(today.adding(days: -3)),
      amount: AmountE4(whole: whole), note: "наушники", creditDebtId: credit)
    draft.normalizeSinglePart()
    return try! draft.materialize()
  }

  private func list(_ entries: [TransactionEntry], plans: [UUID: Debt]) -> [UUID] {
    RefundCandidates.list(
      entries: entries, index: RefundIndex(entries: entries, debts: [:]), tree: CategoryTree(),
      since: nil, calendar: calendar, plans: plans
    ).candidates.map(\.purchase.id)
  }

  @Test("Покупка в рассрочку предлагается, покупка в кредит — нет")
  func instalmentPurchaseIsOffered() {
    let plan = Debt(
      direction: .iOwe, type: .installment, name: "Наушники", paymentsAreExpenses: false,
      origin: .purchase, parts: 4)
    let credit = Debt(
      direction: .iOwe, type: .installment, name: "Телефон", paymentsAreExpenses: false,
      origin: .purchase)
    let inParts = purchase(8000, credit: plan.id)
    let onCredit = purchase(30000, credit: credit.id)
    let plain = purchase(500, credit: nil)
    let entries = [inParts, onCredit, plain]
    #expect(Set(list(entries, plans: [plan.id: plan])) == [inParts.id, plain.id])
    #expect(list(entries, plans: [:]) == [plain.id], "without the plans, as before")
  }
}
