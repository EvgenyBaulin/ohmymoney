import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// An operation recorded in another zone stays on the day of that zone wherever the Mac is: a
/// purchase at 02:00 on 1 October in Bali is October's, though a UTC calendar says 30 September.
/// Every place that reads the day of an operation takes it the way the ledger does.
@Suite("Operation days read in the zone they were recorded in")
struct RecordedZoneDayTests {
  /// 2026-09-30T18:00Z — 02:00 on 1 October in UTC+8.
  static let late = Date(timeIntervalSince1970: 1_790_791_200)
  static let october1 = DateOnly(year: 2026, month: 10, day: 1)
  static let september30 = DateOnly(year: 2026, month: 9, day: 30)

  static func purchase(credit: UUID? = nil, card: UUID? = nil) -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: late, amount: AmountE4(whole: 1000), creditDebtId: credit)
    draft.paymentMethodId = card
    draft.normalizeSinglePart()
    var entry = try! draft.materialize()
    entry.transaction.timeZoneId = "Asia/Makassar"
    return entry
  }

  @Test func anInstalmentPlanStartsOnTheDayOfThePurchaseInItsZone() {
    let (debt, _) = InstalmentPlan.make(
      purchase: Self.purchase(), price: AmountE4(whole: 1000), count: 4, everyDays: 14,
      paymentDay: nil, markup: nil, name: "Plan", id: id(1), calendar: .utc)
    #expect(debt.steps?.firstDue == Self.october1)
  }

  @Test func aRefundCandidateIsDatedInTheZoneOfThePurchase() {
    let entries = [Self.purchase()]
    let found = RefundCandidates.list(
      entries: entries, index: RefundIndex(entries: entries, debts: [:]), tree: CategoryTree(),
      since: Self.october1, calendar: .utc)
    #expect(found.candidates.count == 1)
    let early = RefundCandidates.list(
      entries: entries, index: RefundIndex(entries: entries, debts: [:]), tree: CategoryTree(),
      since: DateOnly(year: 2026, month: 10, day: 2), calendar: .utc)
    #expect(early.candidates.isEmpty)
  }

  @Test func aCreditOpeningIsKeyedByTheDayInTheZoneOfThePurchase() {
    let debt = id(5)
    let openings = AccountBalances.creditOpenings(
      [Self.purchase(credit: debt)], calendar: .utc)
    #expect(openings.keys.map(\.day) == [Self.october1])
  }

  @Test func aCardMovementIsDatedInTheZoneOfItsOperation() {
    let card = PaymentMethod(id: id(60), name: "Card", currency: .rub)
    let ledger = Ledger(
      dataset: Dataset(
        entries: [Self.purchase(card: card.id)], paymentMethods: [card]),
      calendar: .utc)
    let moved = CreditStatements.movements(account: card, ledger: ledger, transfers: [])
    #expect(moved.map(\.day) == [Self.october1])
  }
}
