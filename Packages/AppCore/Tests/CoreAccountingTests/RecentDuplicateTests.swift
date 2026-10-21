import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A new expense or income that repeats what the owner wrote down in the last five minutes — a
/// double press, or the same receipt entered twice — is shown to them before it is added.
@Suite("A repeat of an operation just written")
struct RecentDuplicateTests {
  let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func written(
    _ amount: String, kind: TransactionKind = .expense, currency: CurrencyCode = .rub,
    secondsAgo: TimeInterval, external: String? = nil, deleted: Bool = false, number: Int = 1
  ) -> TransactionEntry {
    let at = now.addingTimeInterval(-secondsAgo)
    let total = money(amount)
    let transaction = Transaction(
      id: id(number), kind: kind, occurredAt: at, currency: currency, amountE4: total,
      note: "coffee", externalId: external, createdAt: at, updatedAt: at,
      deletedAt: deleted ? at : nil)
    return TransactionEntry(
      transaction: transaction, parts: [part(id(number + 100), amount: total)])
  }

  private func draft(
    _ amount: String, kind: TransactionKind = .expense, currency: CurrencyCode = .rub
  ) -> TransactionDraft {
    var draft = TransactionDraft(kind: kind, currency: currency, amount: money(amount))
    draft.normalizeSinglePart()
    return draft
  }

  @Test func theSameAmountWrittenMomentsAgoIsARepeat() {
    let recent = [written("250", secondsAgo: 120)]
    #expect(RecentDuplicate.match(of: draft("250"), among: recent, now: now)?.id == id(1))
  }

  @Test func anotherAmountIsNoRepeat() {
    let recent = [written("250", secondsAgo: 30)]
    #expect(RecentDuplicate.match(of: draft("251"), among: recent, now: now) == nil)
  }

  @Test func anotherCurrencyIsNoRepeat() {
    let recent = [written("250", currency: .usd, secondsAgo: 30)]
    #expect(RecentDuplicate.match(of: draft("250"), among: recent, now: now) == nil)
  }

  @Test func anotherKindIsNoRepeat() {
    let recent = [written("250", kind: .income, secondsAgo: 30)]
    #expect(RecentDuplicate.match(of: draft("250"), among: recent, now: now) == nil)
    #expect(RecentDuplicate.match(of: draft("250", kind: .income), among: recent, now: now) != nil)
  }

  /// Five minutes is the window: what was written exactly that long ago still counts, a second
  /// longer does not.
  @Test func theWindowIsFiveMinutes() {
    #expect(RecentDuplicate.window == 300)
    let edge = [written("250", secondsAgo: 300)]
    #expect(RecentDuplicate.match(of: draft("250"), among: edge, now: now) != nil)
    let past = [written("250", secondsAgo: 301)]
    #expect(RecentDuplicate.match(of: draft("250"), among: past, now: now) == nil)
  }

  /// What the app writes by itself — the fee of a transfer, the difference of a count — carries
  /// an external id and is never the owner's repeat.
  @Test func whatTheAppWroteItselfIsNoRepeat() {
    let recent = [
      written("50", secondsAgo: 10, external: "transfer:1:fee"),
      written("50", secondsAgo: 20, external: "reconcile:1:2", number: 2),
    ]
    #expect(RecentDuplicate.match(of: draft("50"), among: recent, now: now) == nil)
  }

  @Test func aDeletedOperationIsNoRepeat() {
    let recent = [written("250", secondsAgo: 30, deleted: true)]
    #expect(RecentDuplicate.match(of: draft("250"), among: recent, now: now) == nil)
  }

  @Test func theLatestOfSeveralIsTheOneNamed() {
    let recent = [
      written("250", secondsAgo: 200, number: 1), written("250", secondsAgo: 20, number: 2),
      written("250", secondsAgo: 100, number: 3),
    ]
    #expect(RecentDuplicate.match(of: draft("250"), among: recent, now: now)?.id == id(2))
  }

  /// A refund and money back repeat nothing: they are tied to what they take back.
  @Test func onlyAnExpenseOrAnIncomeIsAsked() {
    let recent = [
      written("250", kind: .refund, secondsAgo: 10),
      written("250", kind: .reimbursement, secondsAgo: 10, number: 2),
    ]
    #expect(RecentDuplicate.match(of: draft("250", kind: .refund), among: recent, now: now) == nil)
    #expect(
      RecentDuplicate.match(of: draft("250", kind: .reimbursement), among: recent, now: now) == nil)
  }

  /// «Провести» of a planned payment is the owner's own record of the money, though the app
  /// writes it with a link to the payment: the rent marked as paid in Planning and typed in the
  /// line a minute later is the same rent twice.
  @Test func aPaymentMarkedAsPaidIsTheOwnersOwn() {
    let payment = UUID(uuidString: "6F1C1D5E-0000-4000-8000-000000000001")!
    let link = OperationLink.scheduled(
      paymentId: payment, due: DateOnly(year: 2026, month: 9, day: 1)
    ).externalId
    let recent = [written("30000", secondsAgo: 60, external: link)]
    #expect(RecentDuplicate.match(of: draft("30000"), among: recent, now: now)?.id == id(1))
  }

  @Test func aZeroAmountRepeatsNothing() {
    let recent = [written("0", secondsAgo: 10)]
    #expect(RecentDuplicate.match(of: draft("0"), among: recent, now: now) == nil)
  }
}
