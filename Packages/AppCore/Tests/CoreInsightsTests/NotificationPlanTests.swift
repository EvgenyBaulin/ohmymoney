import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

/// The notifications of the Mac: a payment the day before it, a limit nearly or over spent,
/// «Итоги» ready — each once — and permission asked only when there is something to say.
@Suite("What the Mac notifies about")
struct NotificationPlanTests {
  let today = DateOnly(year: 2026, month: 11, day: 1)
  let internet = UUID()
  let rent = UUID()

  func payment(_ id: UUID, due: DateOnly, kind: ReminderKind = .payment) -> Reminder {
    Reminder(
      id: "pay:\(id.uuidString.lowercased()):\(due.iso)", kind: kind, due: due, subjectId: id,
      urgency: ReminderUrgency(due: due, today: today))
  }

  func limit(_ status: LimitStatus, budget: Budget) -> LimitLine {
    LimitLine(
      budget: budget, month: today.monthKey, amount: AmountE4(whole: 10_000), carry: .zero,
      spent: AmountE4(whole: 9_000), spentShareBp: 9_000, elapsedShareBp: 500, paceBp: nil,
      planned: .zero, forecast: .zero, lowData: false, status: status)
  }

  @Test func aPaymentIsAnnouncedTheDayBeforeIt() {
    let tomorrow = today.adding(days: 1)
    let later = today.adding(days: 3)
    let notices = NotificationPlan.notices(
      today: today,
      reminders: [
        payment(internet, due: tomorrow), payment(rent, due: later),
        // Due today or overdue is not «tomorrow»: the list of reminders says it.
        payment(UUID(), due: today), payment(UUID(), due: today.adding(days: -2)),
        // A trial or a debt is not a payment of this notice.
        payment(UUID(), due: tomorrow, kind: .trialEnds),
      ],
      limits: [], summaries: [], posted: [])
    #expect(
      notices.map(\.subject) == [
        .paymentTomorrow(paymentId: internet, due: tomorrow),
        .paymentTomorrow(paymentId: rent, due: later),
      ])
    #expect(notices.map(\.day) == [today, today.adding(days: 2)])
    #expect(notices[0].id == "pay:\(internet.uuidString.lowercased()):\(tomorrow.iso)")
  }

  @Test func aLimitIsAnnouncedOncePerMonthAndLevel() {
    let food = Budget(scope: .category, categoryId: UUID(), amountE4: AmountE4(whole: 10_000))
    let fun = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    let calm = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    let notices = NotificationPlan.notices(
      today: today, reminders: [],
      limits: [limit(.warning, budget: food), limit(.over, budget: fun), limit(.ok, budget: calm)],
      summaries: [], posted: [])
    #expect(
      notices.map(\.subject) == [
        .limitNear(budgetId: food.id, month: today.monthKey),
        .limitOver(budgetId: fun.id, month: today.monthKey),
      ])
    #expect(notices[0].id == "limit:\(food.id.uuidString.lowercased()):2026-11:near")
    // Shown once: the next run says nothing about them, until the level or the month changes.
    let again = NotificationPlan.notices(
      today: today, reminders: [],
      limits: [limit(.over, budget: food), limit(.over, budget: fun)], summaries: [],
      posted: Set(notices.map(\.id)))
    #expect(again.map(\.subject) == [.limitOver(budgetId: food.id, month: today.monthKey)])
  }

  @Test func readySummariesAreAnnounced() {
    let october = SummaryID.month(MonthKey(year: 2026, month: 10))
    let notices = NotificationPlan.notices(
      today: today, reminders: [], limits: [], summaries: [october], posted: [])
    #expect(notices.map(\.id) == ["summary:month:2026-10"])
    #expect(notices.first?.day == today)
  }

  @Test func eachKindCanBeSwitchedOff() {
    let food = Budget(scope: .badTotal, amountE4: AmountE4(whole: 1))
    let all = NotificationPlan.notices(
      today: today, reminders: [payment(internet, due: today.adding(days: 1))],
      limits: [limit(.over, budget: food)], summaries: [.year(2025)], posted: [], kinds: [.limits])
    #expect(all.map(\.kind) == [.limits])
  }

  /// A notice is seen outside the app: a payment of a hidden account is never announced.
  @Test func paymentsOfHiddenAccountsAreNotAnnounced() {
    let notices = NotificationPlan.notices(
      today: today,
      reminders: [
        payment(internet, due: today.adding(days: 1)), payment(rent, due: today.adding(days: 1)),
      ],
      limits: [], summaries: [], posted: [], hiddenPayments: [rent])
    #expect(
      notices.map(\.subject) == [
        .paymentTomorrow(paymentId: internet, due: today.adding(days: 1))
      ])
  }

  @Test func postedIdsAreForgottenOnceTheyAreNoNews() {
    let kept = NotificationPlan.posted(
      keeping: ["a", "b", "c"], adding: ["d"], active: ["b", "c", "x"])
    #expect(kept == ["b", "c", "d"])
  }

  @Test func permissionIsAskedOnlyWhenThereIsSomethingToSay() {
    let notice = NotificationPlan.Notice(
      id: "summary:month:2026-10", subject: .summary(.month(MonthKey(year: 2026, month: 10))),
      day: today)
    #expect(
      NotificationPlan.step(notices: [], permission: .undetermined, explained: false) == .nothing)
    #expect(
      NotificationPlan.step(notices: [notice], permission: .undetermined, explained: false)
        == .explain)
    // Explained once, whatever the answer: the app does not ask again.
    #expect(
      NotificationPlan.step(notices: [notice], permission: .undetermined, explained: true)
        == .nothing)
    #expect(
      NotificationPlan.step(notices: [notice], permission: .allowed, explained: true) == .post)
    #expect(
      NotificationPlan.step(notices: [notice], permission: .denied, explained: true) == .nothing)
  }
}
