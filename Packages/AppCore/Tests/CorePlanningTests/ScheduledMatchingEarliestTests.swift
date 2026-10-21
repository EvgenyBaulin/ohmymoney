import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A payment is paid oldest due first; «Это другое» dismisses an operation for the whole
/// payment.
@Suite("Scheduled matching: the earliest due first, a dismissal for the whole payment")
struct ScheduledMatchingEarliestTests {
  typealias Fx = CashFx

  func cleaning(next: String = "2026-09-14") -> ScheduledPayment {
    var payment = Fx.payment(1, "Cleaning", "2000", day: 1, next: next)
    payment.freq = .weekly
    return payment
  }

  func matches(
    _ fx: CashFx, rejections: Set<String> = [], today: DateOnly = CashFx.today
  ) -> ScheduledMatches {
    ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: today, rejections: rejections)
  }

  /// Cleaning every Monday for 2 000; the 14th unpaid, the 21st ahead; one operation on
  /// Friday the 18th pays the 14th — the older due —, not the nearer 21st.
  @Test func anOperationPaysTheEarliestUnpaidDueInItsWindow() {
    var fx = Fx()
    fx.scheduled = [cleaning()]
    let paid = fx.add(.expense, "2000", at: Fx.at("2026-09-18", 10), category: Fx.housing)
    let found = matches(fx)
    #expect(found.operation(for: Fx.id(1), Fx.day("2026-09-14")) == paid)
    #expect(!found.isPaid(Fx.id(1), Fx.day("2026-09-21")))
  }

  /// Dues on Monday the 7th and the 14th, operations on the 11th and on the 3rd: the 7th takes
  /// the one of the 3rd, the 14th the one of the 11th — both paid.
  @Test func aSecondPassGivesTheLaterDueToTheOtherOperation() {
    var fx = Fx()
    fx.scheduled = [cleaning(next: "2026-09-07")]
    let eleventh = fx.add(.expense, "2000", at: Fx.at("2026-09-11", 10), category: Fx.housing)
    let third = fx.add(.expense, "2000", at: Fx.at("2026-09-03", 10), category: Fx.housing)
    let found = matches(fx)
    #expect(found.operation(for: Fx.id(1), Fx.day("2026-09-07")) == third)
    #expect(found.operation(for: Fx.id(1), Fx.day("2026-09-14")) == eleventh)
  }

  /// Two payments of one category on the 20th and on the 22nd and one operation on the 22nd:
  /// across payments the nearest still wins — it pays the 22nd.
  @Test func acrossPaymentsTheNearestStillWins() {
    var fx = Fx()
    let first = Fx.payment(8, "Parking", "5000", day: 20, next: "2026-09-20")
    let second = Fx.payment(9, "Storage", "5000", day: 22, next: "2026-09-22")
    fx.scheduled = [first, second]
    let paid = fx.add(.expense, "5000", at: Fx.at("2026-09-22", 10), category: Fx.housing)
    let found = matches(fx, today: Fx.day("2026-09-23"))
    #expect(found.operation(for: second.id, Fx.day("2026-09-22")) == paid)
    #expect(!found.isPaid(first.id, Fx.day("2026-09-20")))
  }

  /// «Это другое» said about the 14th dismisses the operation for every due of the payment:
  /// it pays neither the 14th nor the 21st, is ordinary spending for the forecast, and the 14th
  /// stays overdue.
  @Test func aRejectionCoversEveryDueOfThePayment() {
    var fx = Fx()
    fx.scheduled = [cleaning()]
    let spent = fx.add(.expense, "2000", at: Fx.at("2026-09-17", 10), category: Fx.housing)
    let rejections: Set<String> = [
      ScheduledMatching.rejectionKey(operation: spent, payment: Fx.id(1), due: Fx.day("2026-09-14"))
    ]
    let found = matches(fx, rejections: rejections)
    #expect(found.matchedDues(of: Fx.id(1)).isEmpty)
    #expect(!found.operationIds.contains(spent))
    #expect(
      ScheduledMatching.isRejected(operation: spent, payment: Fx.id(1), rejections: rejections))
    #expect(
      !ScheduledMatching.isRejected(operation: spent, payment: Fx.id(2), rejections: rejections))
    fx.settings.scheduledMatchRejections = rejections
    #expect(fx.snapshot().overdue.map(\.due) == [Fx.day("2026-09-14")])
  }

  /// A key written by 1.1 about one due date, in capitals or not, now covers the whole
  /// payment: the stored text is not rewritten, its meaning widens to what the hint promised.
  @Test func aStoredOneOneRejectionWidensToThePayment() {
    var fx = Fx()
    fx.scheduled = [cleaning(next: "2026-09-07")]
    let spent = fx.add(.expense, "2000", at: Fx.at("2026-09-17", 10), category: Fx.housing)
    let stored = "\(spent.uuidString):\(Fx.id(1).uuidString):2026-09-07"
    let found = matches(fx, rejections: [stored])
    #expect(found.operation(for: Fx.id(1), Fx.day("2026-09-14")) == nil)
    #expect(found.operation(for: Fx.id(1), Fx.day("2026-09-21")) == nil)
    #expect(ScheduledMatching.rejectionDay(stored) == Fx.day("2026-09-07"))
  }

  /// «Привязать» of a due that belongs to an event puts the event on every part without one.
  @Test func bindingPutsTheEventOnThePartsWithoutOne() {
    var fx = Fx()
    fx.scheduled = [cleaning()]
    fx.add(.expense, "2000", at: Fx.at("2026-09-17", 10), category: Fx.housing)
    let bound = ScheduledMatching.bind(
      fx.entries[0], to: cleaning(), due: Fx.day("2026-09-14"), eventId: Fx.id(501))
    #expect(bound.operation.parts.map(\.eventId) == [Fx.id(501)])
    #expect(
      ScheduledMatching.bind(fx.entries[0], to: cleaning(), due: Fx.day("2026-09-14"))
        .operation.parts.map(\.eventId) == [nil])
  }
}
