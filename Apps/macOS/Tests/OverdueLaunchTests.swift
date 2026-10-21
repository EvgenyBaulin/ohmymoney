import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// When the main window asks about the due dates passed and unpaid: at every launch while
/// there are some, once a launch, whatever the daily reminders did.
final class OverdueLaunchTests: XCTestCase {
  private let rent = OverdueDue(
    subject: .scheduled(UUID()), name: "Rent", due: DateOnly(year: 2026, month: 9, day: 5),
    amount: AmountE4(whole: 30_000), currency: .rub, moreOverdue: 0, countAfter: nil, key: nil)

  private let reminder = Reminder(
    id: "reconcile:none", kind: .reconciliation, due: nil, subjectId: nil, urgency: .today)

  /// The daily reminders were shown today already: at the next launch the overdue section is
  /// still asked, with no daily list.
  func testOverdueDuesAreAskedAtEveryLaunchAfterTheDailySheet() {
    let first = RemindersPresentation.decide(
      daily: [reminder], overdue: [rent], shownToday: false, askedThisLaunch: false)
    XCTAssertEqual(first, RemindersPresentation(daily: [reminder], asksOverdue: true))
    XCTAssertEqual(first?.marksDailyShown, true)
    let nextLaunch = RemindersPresentation.decide(
      daily: [reminder], overdue: [rent], shownToday: true, askedThisLaunch: false)
    XCTAssertEqual(nextLaunch, RemindersPresentation(daily: [], asksOverdue: true))
    XCTAssertEqual(nextLaunch?.marksDailyShown, false)
  }

  /// Once asked this launch, nothing more is asked until the next one.
  func testOnlyOncePerLaunch() {
    XCTAssertNil(
      RemindersPresentation.decide(
        daily: [reminder], overdue: [rent], shownToday: true, askedThisLaunch: true))
    XCTAssertEqual(
      RemindersPresentation.decide(
        daily: [reminder], overdue: [rent], shownToday: false, askedThisLaunch: true),
      RemindersPresentation(daily: [reminder], asksOverdue: false))
  }

  /// Nothing overdue: the daily rule of 1.1 — once a day, when there is anything.
  func testNothingOverdueKeepsTheDailyRule() {
    XCTAssertEqual(
      RemindersPresentation.decide(
        daily: [reminder], overdue: [], shownToday: false, askedThisLaunch: false),
      RemindersPresentation(daily: [reminder], asksOverdue: false))
    XCTAssertNil(
      RemindersPresentation.decide(
        daily: [reminder], overdue: [], shownToday: true, askedThisLaunch: false))
    XCTAssertNil(
      RemindersPresentation.decide(
        daily: [], overdue: [], shownToday: false, askedThisLaunch: false))
  }

  /// A launch that said «no reminders» asks nothing.
  func testSuppressedByNoReminders() {
    XCTAssertNil(
      RemindersPresentation.decide(
        daily: [reminder], overdue: [rent], shownToday: false, askedThisLaunch: false,
        suppressed: true))
  }
}

/// The words and pieces of the free sum on the screens: the goals-exceed row of Overview, the
/// valuation picker of Settings, the archived account of a payment, the events of a payment.
@MainActor
final class FreeSumScreensTests: XCTestCase {
  /// The keys the screens read, in both languages.
  func testTheNewWordsAreTranslated() {
    let tables: [(String, [String])] = [
      ("Overview", ["overview.goalsExceed", "overview.goalsExceedDetail", "overview.openGoals"]),
      (
        "Settings",
        [
          "settings.planning.goalValuation", "settings.planning.goalValuation.today",
          "settings.planning.goalValuation.deposits", "settings.planning.goalValuationHint",
          "settings.planning.reserveHint", "settings.planning.includesGoalsHint",
        ]
      ),
    ]
    let language = AppLanguage()
    let before = language.choice
    defer { language.choice = before }
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for (table, keys) in tables {
        for key in keys {
          XCTAssertNotEqual(language(key, table: table), key, "\(choice) \(key)")
        }
      }
    }
  }

  /// The hint of the reserve switch says «до выбранной даты», not «этого месяца»: the free sum
  /// reserves the plans up to the date chosen on the block.
  func testTheReserveHintSaysUntilTheChosenDate() {
    let language = AppLanguage()
    let before = language.choice
    defer { language.choice = before }
    language.choice = .russian
    XCTAssertEqual(
      language("settings.planning.reserveHint", table: "Settings"),
      "Несделанные плановые взносы до выбранной даты не считаются свободными деньгами.")
    language.choice = .english
    XCTAssertEqual(
      language("settings.planning.reserveHint", table: "Settings"),
      "Planned contributions not yet made by the chosen date are not counted as free money.")
  }

  /// The valuation is a setting stored under its key, read back as written; an unknown value
  /// reads as today's rate.
  func testValuationPickerWritesTheKey() {
    var settings = PlanningSettings()
    XCTAssertEqual(settings.goalSavingsValuation, .today)
    let before = settings.storedValues
    settings.goalSavingsValuation = .deposits
    let after = settings.storedValues
    XCTAssertEqual(
      PlanningSettingsView.changedKeys(before: before, after: after),
      [PlanningSettings.goalSavingsValuationKey])
    XCTAssertEqual(after[PlanningSettings.goalSavingsValuationKey] ?? nil, "deposits")
    XCTAssertEqual(
      PlanningSettings(storedValues: [PlanningSettings.goalSavingsValuationKey: "deposits"])
        .goalSavingsValuation, .deposits)
    XCTAssertEqual(
      PlanningSettings(storedValues: [PlanningSettings.goalSavingsValuationKey: "someday"])
        .goalSavingsValuation, .today)
  }

  /// The payment form names an archived account the payment still points at; a live one, or
  /// none, gives no note.
  func testArchivedAccountNote() {
    let old = PaymentMethod(name: "Old card", currency: .rub, archived: true)
    let live = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
    var payment = ScheduledPayment(name: "Gym", amountE4: AmountE4(whole: 2_000))
    payment.paymentMethodId = old.id
    XCTAssertEqual(
      ScheduledPaymentForm.archivedAccount(of: payment, among: [old, live])?.name, "Old card")
    payment.paymentMethodId = live.id
    XCTAssertNil(ScheduledPaymentForm.archivedAccount(of: payment, among: [old, live]))
    payment.paymentMethodId = nil
    XCTAssertNil(ScheduledPaymentForm.archivedAccount(of: payment, among: [old, live]))
  }

  /// The picker offers the live events not over yet and keeps the one the payment names, even
  /// archived.
  func testScheduledFormOffersTheEvents() {
    let today = DateOnly(year: 2026, month: 9, day: 19)
    let trip = Event(
      name: "Trip", startDate: DateOnly(year: 2026, month: 9, day: 25),
      endDate: DateOnly(year: 2026, month: 9, day: 29))
    let past = Event(
      name: "Past", startDate: DateOnly(year: 2026, month: 8, day: 1),
      endDate: DateOnly(year: 2026, month: 8, day: 2))
    var gone = Event(
      name: "Gone", startDate: DateOnly(year: 2026, month: 10, day: 1),
      endDate: DateOnly(year: 2026, month: 10, day: 2))
    gone.archived = true
    let snapshot = DataSnapshot.build(
      dataset: Dataset(events: [gone, past, trip]), calendar: .utc, today: today,
      context: SnapshotContext(), version: DataVersion(load: 1))
    let compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    compute.applyLight(snapshot)
    let environment = AppEnvironment()
    let choices = PlanningChoices(compute, environment)
    XCTAssertEqual(choices.events(keeping: nil, today: today).map(\.name), ["Trip"])
    XCTAssertEqual(
      choices.events(keeping: gone.id, today: today).map(\.name), ["Trip", "Gone"])
    XCTAssertEqual(
      choices.events(keeping: past.id, today: today).map(\.name), ["Past", "Trip"])
  }
}
