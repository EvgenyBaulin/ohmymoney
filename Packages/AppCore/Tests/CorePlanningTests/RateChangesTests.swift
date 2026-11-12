import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The rate a bank announced for a savings account: listed, reminded a week ahead, and gone once
/// it is the rate itself. Synthetic data.
@Suite("The announced rate of a savings account")
struct RateChangesTests {
  let today = DateOnly(year: 2026, month: 11, day: 25)

  func account(
    _ number: Int, rate: Decimal = 16, next: Decimal? = 12, on: DateOnly? = nil,
    archived: Bool = false
  ) -> PaymentMethod {
    PaymentMethod(
      id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
      name: "Savings \(number)", archived: archived,
      interest: DepositTerms(
        rate: rate, period: .monthly, nextRate: next,
        nextRateOn: on ?? DateOnly(year: 2026, month: 12, day: 1)))
  }

  @Test func announcedChangesAreListedNearestFirstWithTheirDirection() {
    let down = account(1)
    let up = account(2, next: 20, on: DateOnly(year: 2026, month: 11, day: 30))
    let same = account(3, next: 16)
    let notices = RateChanges.announced(accounts: [down, up, same], today: today)
    #expect(notices.map(\.accountId) == [up.id, down.id, same.id])
    #expect(notices.map(\.direction) == [.up, .down, .same])
    #expect(notices[0].daysLeft == 5 && notices[1].daysLeft == 6)
    #expect(notices[1].currentRate == 16 && notices[1].nextRate == 12)
  }

  @Test func aChangeThatStartedOrWasNotAnnouncedOrIsArchivedIsNotListed() {
    let started = account(1, on: DateOnly(year: 2026, month: 11, day: 24))
    let nothing = PaymentMethod(
      name: "Plain", interest: DepositTerms(rate: 16, period: .monthly))
    let withoutInterest = PaymentMethod(name: "Card")
    let archived = account(2, archived: true)
    let zero = account(3, next: 0)
    #expect(
      RateChanges.announced(
        accounts: [started, nothing, withoutInterest, archived, zero], today: today
      ).isEmpty)
    // The day itself is still ahead.
    let onTheDay = account(4, on: today)
    #expect(RateChanges.announced(accounts: [onTheDay], today: today).first?.daysLeft == 0)
  }

  @Test func theReminderComesAWeekAheadAndOnlyThen() {
    let near = account(1, on: DateOnly(year: 2026, month: 12, day: 2))
    let far = account(2, on: DateOnly(year: 2026, month: 12, day: 3))
    let reminders = RateChanges.reminders(accounts: [far, near], today: today)
    #expect(reminders.count == 1)
    let reminder = reminders[0]
    #expect(reminder.kind == .rateChange && reminder.subjectId == near.id)
    #expect(reminder.due == DateOnly(year: 2026, month: 12, day: 2))
    #expect(reminder.urgency == .soon)
    #expect(reminder.id == "rate:\(near.id.uuidString.lowercased()):2026-12-02")
    #expect(RateChanges.reminders(accounts: [near], today: DateOnly(year: 2026, month: 12, day: 2))
      .first?.urgency == .today)
  }

  @Test func theReminderPipelineCarriesIt() {
    let near = account(1, on: DateOnly(year: 2026, month: 11, day: 28))
    let ledger = Ledger(
      dataset: Dataset(paymentMethods: [near], planning: PlanningBook()), calendar: .utc)
    let all = ReminderRules.all(book: PlanningBook(), debts: [], ledger: ledger, today: today)
    #expect(all.contains { $0.kind == .rateChange && $0.subjectId == near.id })
    #expect(ReminderKind.rateChange.key == "reminders.kind.rateChange")
  }
}
