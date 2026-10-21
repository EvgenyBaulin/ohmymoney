import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Reminders: payments, trials, prices, debts and reconciliation")
struct RemindersTests {
  typealias S = ReconcileSketch

  /// Friday 18 September 2026.
  let today = S.day("2026-09-18")

  private func build(
    _ sketch: ReconcileSketch, today: DateOnly? = nil
  ) -> [Reminder] {
    ReminderRules.build(
      book: sketch.book, debts: sketch.debts, ledger: sketch.ledger, today: today ?? self.today)
  }

  private func payment(
    _ number: Int, next: String? = nil, trialEnd: String? = nil, amount: String = "500",
    remindDaysBefore: Int? = nil, active: Bool = true
  ) -> ScheduledPayment {
    ScheduledPayment(
      id: S.id(number), name: "Payment", kind: .subscription, amountE4: S.money(amount),
      nextDate: next.map(S.day), trialEnd: trialEnd.map(S.day),
      remindDaysBefore: remindDaysBefore, active: active)
  }

  /// A sketch with no reconciliation due, so a case sees only its own kind.
  private func quietSketch() -> ReconcileSketch {
    var sketch = S()
    sketch.book.reconciliations = [
      Reconciliation(id: S.id(1), date: today, actualTotalRubE4: S.money("100000"))
    ]
    return sketch
  }

  // MARK: - Scheduled payments

  @Test func paymentsDueWithinTheirDaysBefore() {
    var sketch = quietSketch()
    sketch.book.scheduled = [
      payment(401, next: "2026-09-20"),
      payment(402, next: "2026-09-22"),
      payment(403, next: "2026-09-22", remindDaysBefore: 5),
      payment(404, next: "2026-09-15"),
      payment(405, next: "2026-09-18"),
      payment(406, next: "2026-09-18", active: false),
      payment(407, next: nil),
    ]
    let reminders = build(sketch)
    #expect(
      reminders.map(\.id) == [
        "pay:\(S.id(404).uuidString.lowercased()):2026-09-15",
        "pay:\(S.id(405).uuidString.lowercased()):2026-09-18",
        "pay:\(S.id(401).uuidString.lowercased()):2026-09-20",
        "pay:\(S.id(403).uuidString.lowercased()):2026-09-22",
      ])
    #expect(reminders.map(\.urgency) == [.overdue, .today, .soon, .soon])
    #expect(reminders.allSatisfy { $0.kind == .payment })
    #expect(reminders.first?.subjectId == S.id(404))
    #expect(reminders.first?.due == S.day("2026-09-15"))
  }

  /// «Mark as paid» wrote the operation for that due date: nothing left to remind of, even
  /// if the next date has not moved on.
  @Test func aPaymentAlreadyMarkedAsPaidIsNotReminded() {
    var sketch = quietSketch()
    sketch.book.scheduled = [payment(401, next: "2026-09-19")]
    sketch.add(
      .expense, "500", at: S.at("2026-09-17", 12),
      link: .scheduled(paymentId: S.id(401), due: S.day("2026-09-19")))
    #expect(build(sketch).isEmpty)
  }

  @Test func idsUseLowercasedUUIDs() throws {
    var sketch = quietSketch()
    let paymentId = try #require(UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789"))
    var subscription = payment(401, next: "2026-09-20")
    subscription.id = paymentId
    sketch.book.scheduled = [subscription]
    #expect(build(sketch).map(\.id) == ["pay:abcdef01-2345-6789-abcd-ef0123456789:2026-09-20"])
  }

  @Test func theEndOfATrial() {
    var sketch = quietSketch()
    sketch.book.scheduled = [
      payment(411, trialEnd: "2026-09-21"),
      payment(412, trialEnd: "2026-09-22"),
      payment(413, trialEnd: "2026-09-17"),
      payment(414, trialEnd: "2026-09-18"),
      payment(415, trialEnd: "2026-09-18", active: false),
    ]
    let reminders = build(sketch)
    #expect(
      reminders.map(\.id) == [
        "trial:\(S.id(414).uuidString.lowercased()):2026-09-18",
        "trial:\(S.id(411).uuidString.lowercased()):2026-09-21",
      ])
    #expect(reminders.map(\.urgency) == [.today, .soon])
    #expect(reminders.allSatisfy { $0.kind == .trialEnds })
  }

  @Test func aPriceChangeWithinAWeek() {
    var sketch = quietSketch()
    sketch.book.scheduled = [
      payment(421), payment(422), payment(423), payment(424, amount: "500"),
    ]
    sketch.book.prices = [
      // 421: 500 since January, 600 in five days.
      SubscriptionPrice(
        id: S.id(1421), paymentId: S.id(421), date: S.day("2026-01-01"),
        amountE4: S.money("500")),
      SubscriptionPrice(
        id: S.id(2421), paymentId: S.id(421), date: S.day("2026-09-23"),
        amountE4: S.money("600")),
      // 422: the row repeats the price.
      SubscriptionPrice(
        id: S.id(1422), paymentId: S.id(422), date: S.day("2026-01-01"),
        amountE4: S.money("450")),
      SubscriptionPrice(
        id: S.id(2422), paymentId: S.id(422), date: S.day("2026-09-23"),
        amountE4: S.money("450")),
      // 423: eight days away, too early.
      SubscriptionPrice(
        id: S.id(2423), paymentId: S.id(423), date: S.day("2026-09-26"),
        amountE4: S.money("700")),
      // 424: no history, the price of the payment is the current one.
      SubscriptionPrice(
        id: S.id(2424), paymentId: S.id(424), date: S.day("2026-09-20"),
        amountE4: S.money("450")),
    ]
    let reminders = build(sketch)
    #expect(
      reminders.map(\.id) == [
        "price:\(S.id(424).uuidString.lowercased()):2026-09-20",
        "price:\(S.id(421).uuidString.lowercased()):2026-09-23",
      ])
    #expect(reminders.allSatisfy { $0.kind == .priceChange && $0.urgency == .soon })
    #expect(reminders.map(\.subjectId) == [S.id(424), S.id(421)])
  }

  // MARK: - Debts

  @Test func debtPaymentsOnTheirDay() {
    var sketch = quietSketch()
    func debt(
      _ number: Int, day: Int?, direction: DebtDirection = .iOwe, closed: Bool = false,
      remindDaysBefore: Int? = nil
    ) -> Debt {
      Debt(
        id: S.id(number), direction: direction, type: .loan, name: "Debt", paymentDay: day,
        remindDaysBefore: remindDaysBefore, closed: closed)
    }
    sketch.debts = [
      debt(431, day: 20),
      debt(432, day: 10),
      // Paid on the 5th: the next due date is 20 October, too far.
      debt(433, day: 20),
      // The 31st is the 30th in September.
      debt(434, day: 31, remindDaysBefore: 12),
      debt(435, day: 20, closed: true),
      debt(436, day: 20, direction: .owedToMe),
      debt(437, day: nil),
    ]
    sketch.add(.expense, "5000", at: S.at("2026-09-05", 12), debt: S.id(433))
    let reminders = build(sketch)
    #expect(
      reminders.map(\.id) == [
        "debt:\(S.id(432).uuidString.lowercased()):2026-09-10",
        "debt:\(S.id(431).uuidString.lowercased()):2026-09-20",
        "debt:\(S.id(434).uuidString.lowercased()):2026-09-30",
      ])
    #expect(reminders.map(\.urgency) == [.overdue, .soon, .soon])
    #expect(reminders.allSatisfy { $0.kind == .debtPayment })
  }

  /// Paid this month, the next due date is next month's: on 29 September a debt due on the
  /// 1st is reminded of 1 October. A payment typed for 1 October pays nothing before its day:
  /// until then October is still reminded; on the 1st it is paid, and November is not near.
  @Test func aDebtPaidThisMonthIsDueNextMonth() {
    var sketch = quietSketch()
    sketch.book.reconciliations = [
      Reconciliation(id: S.id(1), date: S.day("2026-09-29"), actualTotalRubE4: .zero)
    ]
    sketch.debts = [
      Debt(id: S.id(441), direction: .iOwe, type: .loan, name: "Debt", paymentDay: 1)
    ]
    sketch.add(.expense, "5000", at: S.at("2026-09-01", 12), debt: S.id(441))
    let reminders = build(sketch, today: S.day("2026-09-29"))
    #expect(reminders.map(\.id) == ["debt:\(S.id(441).uuidString.lowercased()):2026-10-01"])
    #expect(reminders.first?.urgency == .soon)

    sketch.add(.expense, "5000", at: S.at("2026-10-01", 9), debt: S.id(441))
    #expect(
      build(sketch, today: S.day("2026-09-29")).map(\.id) == [
        "debt:\(S.id(441).uuidString.lowercased()):2026-10-01"
      ])
    #expect(build(sketch, today: S.day("2026-10-01")).filter { $0.kind == .debtPayment }.isEmpty)
  }

  /// A payment written on the debt card alone — a journal `payment` line without an
  /// operation — settles its month as well, the way the card counts it (`DebtSchedule`).
  /// Money borrowed on a debt through the entry line — an operation that points at the debt
  /// with a `borrowed` line — is not the month's payment (third review, 19.09): the reminder
  /// of the 20th stays.
  @Test func moneyBorrowedOnADebtIsNotItsPayment() {
    var sketch = quietSketch()
    sketch.debts = [
      Debt(
        id: S.id(461), direction: .iOwe, type: .creditCard, name: "Card",
        monthlyPaymentE4: S.money("8500"), paymentDay: 20)
    ]
    let borrowed = sketch.add(.income, "50000", at: S.at("2026-09-10", 12), debt: S.id(461))
    sketch.journal(S.id(461), "50000", on: "2026-09-10", kind: .borrowed, transactionId: borrowed)
    #expect(build(sketch).map(\.id) == ["debt:\(S.id(461).uuidString.lowercased()):2026-09-20"])
  }

  /// A price edit after a due was paid — today or ahead — announces only the real change,
  /// never the old price as a «change» back (fourth review, 19.09). «Internet» at 900, the
  /// due of the 22nd paid ahead, edited to 950: one reminder, «from the 23rd: 950 instead of
  /// 900»; the same when the due paid is today's.
  @Test func aPriceEditAfterAPaymentAnnouncesOnlyTheRealChange() {
    for charged in ["2026-09-22", "2026-09-18"] {
      var sketch = quietSketch()
      let before = payment(431, next: "2026-10-22", amount: "900")
      var after = before
      after.amountE4 = S.money("950")
      let edit = SubscriptionMath.priceEdit(
        previous: before, updated: after, prices: [], today: today,
        since: S.day(charged), charged: S.day(charged))
      sketch.book.scheduled = [after]
      sketch.book.prices = edit.rows
      let changes = build(sketch).filter { $0.kind == .priceChange }
      #expect(changes.map(\.due) == [S.day(charged).adding(days: 1)], "charged \(charged)")
      #expect(
        SubscriptionMath.price(of: after, on: S.day(charged), prices: edit.rows)
          == S.money("900"))
    }
  }

  /// An edit after a due charged before today sets the new price from today: that is the
  /// owner's own change, already in force, not a change to announce. A row dated today is
  /// the price today (`upcomingPriceChange` reads it so); only a later one is announced.
  @Test func aPriceInForceTodayIsNotAnnounced() {
    var sketch = quietSketch()
    let before = payment(431, next: "2026-10-10", amount: "900")
    var after = before
    after.amountE4 = S.money("950")
    let edit = SubscriptionMath.priceEdit(
      previous: before, updated: after, prices: [], today: today,
      since: S.day("2026-09-10"), charged: S.day("2026-09-10"))
    #expect(edit.rows.map(\.date).contains(today))
    sketch.book.scheduled = [after]
    sketch.book.prices = edit.rows
    #expect(build(sketch).filter { $0.kind == .priceChange }.isEmpty)
    #expect(
      SubscriptionMath.upcomingPriceChange(
        of: after, prices: edit.rows, today: today, within: ReminderRules.priceChangeDaysAhead)
        == nil)
  }

  /// A payment written on the debt card alone closes the earliest due, as an operation does.
  @Test func aJournalPaymentSettlesTheEarliestDue() {
    var sketch = quietSketch()
    sketch.book.reconciliations = [
      Reconciliation(id: S.id(1), date: S.day("2026-09-29"), actualTotalRubE4: .zero)
    ]
    sketch.debts = [
      Debt(id: S.id(451), direction: .iOwe, type: .loan, name: "Debt", paymentDay: 1)
    ]
    // Borrowed in the middle of August: the 1st of September is the first due, and the
    // payment written on the card alone pays it.
    sketch.book.debtEntries = [
      DebtRules.makeEntry(
        id: S.id(453), debtId: S.id(451), kind: .borrowed, amountE4: S.money("50000"),
        date: S.day("2026-08-15")),
      DebtRules.makeEntry(
        id: S.id(452), debtId: S.id(451), kind: .payment, amountE4: S.money("5000"),
        date: S.day("2026-09-01")),
    ]
    let reminders = build(sketch, today: S.day("2026-09-29"))
    #expect(reminders.map(\.id) == ["debt:\(S.id(451).uuidString.lowercased()):2026-10-01"])
  }

  // MARK: - Reconciliation

  @Test func reconcileBeforeTheFirstAndAfterEveryNDays() {
    var none = S()
    none.book.reconciliations = []
    let first = build(none)
    #expect(first.map(\.id) == ["reconcile:none"])
    #expect(first.first?.urgency == .today)
    #expect(first.first?.due == nil)
    #expect(first.first?.kind == .reconciliation)

    var sketch = S()
    sketch.book.reconciliations = [
      Reconciliation(id: S.id(2), date: S.day("2026-09-01"), actualTotalRubE4: .zero)
    ]
    #expect(build(sketch, today: S.day("2026-09-15")).isEmpty)
    let due = build(sketch, today: S.day("2026-09-16"))
    #expect(due.map(\.id) == ["reconcile:2026-09-01"])
    #expect(due.first?.due == S.day("2026-09-16"))
    #expect(due.first?.urgency == .today)
    #expect(due.first?.subjectId == S.id(2))
    #expect(build(sketch, today: S.day("2026-09-20")).first?.urgency == .overdue)

    sketch.book.settings.reconcileEveryDays = 30
    #expect(build(sketch, today: S.day("2026-09-20")).isEmpty)
  }

  // MARK: - The list

  @Test func dismissedRemindersStayAwayUntilTheOccasionChanges() {
    var sketch = quietSketch()
    sketch.book.scheduled = [payment(401, next: "2026-09-20"), payment(402, next: "2026-09-19")]
    let dismissed = "pay:\(S.id(401).uuidString.lowercased()):2026-09-20"
    sketch.book.settings.dismissedReminders = [dismissed]
    #expect(build(sketch).map(\.subjectId) == [S.id(402)])

    // The next due date is a new reminder.
    sketch.book.scheduled[0].nextDate = S.day("2026-09-21")
    #expect(build(sketch).map(\.subjectId) == [S.id(402), S.id(401)])
  }

  /// × keeps every reminder put off while its occasion lasts, however old the date in its
  /// id: a payment unpaid for seven weeks and a reconciliation due since August are still
  /// there to remind of. What goes is what no longer reminds — a due date paid, a
  /// reconciliation made.
  @Test func putOffRemindersAreKeptWhileTheyStillRemind() {
    var sketch = S()
    sketch.book.reconciliations = [
      Reconciliation(id: S.id(2), date: S.day("2026-08-01"), actualTotalRubE4: .zero)
    ]
    sketch.book.scheduled = [payment(401, next: "2026-08-01")]
    let overdue = "pay:\(S.id(401).uuidString.lowercased()):2026-08-01"
    let reconcile = "reconcile:2026-08-01"
    let paid = "pay:\(S.id(401).uuidString.lowercased()):2026-07-01"

    let active = Set(
      ReminderRules.all(
        book: sketch.book, debts: sketch.debts, ledger: sketch.ledger, today: today
      ).map(\.id))
    #expect(active == [overdue, reconcile])

    let kept = ReminderRules.dismissed(adding: overdue, to: [reconcile, paid], active: active)
    #expect(kept == [overdue, reconcile])
    // With nothing known of what is active (no data yet), nothing is forgotten.
    #expect(
      ReminderRules.dismissed(adding: overdue, to: [reconcile, paid], active: nil)
        == [overdue, reconcile, paid])
    // `build` still leaves the put-off ones out.
    sketch.book.settings.dismissedReminders = kept
    #expect(build(sketch).isEmpty)
  }

  /// Overdue first, then today's, then the coming ones; by date inside each, a reminder
  /// without a date last, then by kind.
  @Test func theMostPressingComeFirst() {
    var sketch = S()
    sketch.book.reconciliations = []
    sketch.book.scheduled = [
      payment(401, next: "2026-09-20", trialEnd: "2026-09-18"),
      payment(402, next: "2026-09-12"),
      payment(403, next: "2026-09-18"),
    ]
    sketch.debts = [
      Debt(id: S.id(431), direction: .iOwe, type: .loan, name: "Debt", paymentDay: 19),
      Debt(id: S.id(432), direction: .iOwe, type: .loan, name: "Debt", paymentDay: 14),
    ]
    let reminders = build(sketch)
    #expect(
      reminders.map(\.kind) == [
        .payment, .debtPayment, .payment, .trialEnds, .reconciliation, .debtPayment, .payment,
      ])
    #expect(
      reminders.map(\.urgency) == [.overdue, .overdue, .today, .today, .today, .soon, .soon])
    #expect(
      reminders.map(\.subjectId) == [
        S.id(402), S.id(432), S.id(403), S.id(401), nil, S.id(431), S.id(401),
      ])
  }

  @Test func urgencyAndKeys() {
    #expect(ReminderUrgency(due: S.day("2026-09-17"), today: today) == .overdue)
    #expect(ReminderUrgency(due: today, today: today) == .today)
    #expect(ReminderUrgency(due: S.day("2026-09-19"), today: today) == .soon)
    #expect(ReminderUrgency.overdue < .today && ReminderUrgency.today < .soon)
    #expect(ReminderKind.debtPayment.key == "reminders.kind.debtPayment")
  }
}
