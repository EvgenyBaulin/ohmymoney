import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// The planning a set with accounts and cards adds:
  ///
  /// * a hotel paid once, tied to the coming New Year and its budget, three weeks before it, on
  ///   the main account's own card: the event's remaining budget covers it, never both;
  /// * the plan of the history's ruble goal counted from the month before the last day, and a
  ///   deposit in that month half as big again as the plan: what went in beyond it is paid ahead
  ///   for the months after;
  /// * the salary expected on the main account on the 2nd of every month from the next one;
  /// * with `demo`, a car inspection due three days before the last day and not paid: the app
  ///   asks about it at every launch. The sample has none, so its screenshots stay calm.
  ///
  /// The deposit is money put into a goal: it moves no account, and it is my spending in
  /// «Цели», as every contribution is.
  func withPlanningLayer(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?, demo: Bool
  ) -> SampleDataSet {
    let layer = SampleLayer(
      tag: 0x0012_914A_0000_0012, seed: seed, set: self, calendar: calendar, language: language,
      now: now)
    var set = self
    guard let main = mainAccount else { return set }
    let ownCard = cards.first { $0.id == CardsMigration.cardId(forAccount: main.id) }

    if let newYear = events.first(where: { event in
      event.kind == .newYear && event.endDate > lastDay && event.budgetE4 != nil
    }), let travel = starter("Travel") {
      let due = min(
        newYear.endDate,
        max(
          calendar.adding(days: 1, to: lastDay), calendar.adding(days: -21, to: newYear.startDate)))
      var rng = layer.stream("hotel", on: newYear.startDate)
      set.oneOffPayments.append(
        ScheduledPayment(
          id: rng.nextUUID(), name: layer.word("Hotel for New Year", "Отель на Новый год"),
          amountE4: AmountE4(whole: Int64(rng.int(in: 16...28)) * 500),
          categoryId: travel.category.id, paymentMethodId: main.id, day: due.day, nextDate: due,
          endDate: due, remindDaysBefore: 7, cardId: ownCard?.id, eventId: newYear.id))
    }

    set.planGoalAhead(layer: layer, account: main.id)

    if let work = starter("Work", .income) {
      let due =
        lastDay.day < Self.salaryDay
        ? DateOnly(year: lastDay.year, month: lastDay.month, day: Self.salaryDay)
        : DateOnly(
          year: lastDay.monthKey.next.year, month: lastDay.monthKey.next.month, day: Self.salaryDay)
      var rng = layer.stream("salary expected")
      set.addedExpectedIncome.append(
        ExpectedIncome(
          id: rng.nextUUID(), name: layer.word("Salary", "Зарплата"), categoryId: work.category.id,
          kind: .recurring, totalE4: Self.expectedSalary, dueDate: due, freq: .monthly,
          day: Self.salaryDay, paymentMethodId: main.id))
    }

    if demo, let maintenance = starter("Maintenance") {
      let due = calendar.adding(days: -3, to: lastDay)
      var rng = layer.stream("car inspection", on: due)
      set.oneOffPayments.append(
        ScheduledPayment(
          id: rng.nextUUID(), name: layer.word("Car inspection", "Техосмотр"),
          amountE4: AmountE4(whole: Int64(rng.int(in: 24...36)) * 100),
          categoryId: maintenance.category.id, paymentMethodId: main.id, day: due.day,
          nextDate: due, endDate: due, remindDaysBefore: 3))
    }
    return set
  }

  /// The day of the month the expected salary comes on, and how much of it.
  static let salaryDay = 2
  static let expectedSalary = AmountE4(whole: 120_000)

  /// The plan of the first ruble goal with a monthly plan counted from the month before the last
  /// day, and a deposit on the 20th of that month of one and a half plans.
  private mutating func planGoalAhead(layer: SampleLayer, account: UUID) {
    guard
      let index = goals.firstIndex(where: { goal in
        !goal.archived && goal.currency == .rub && (goal.monthlyPlanE4?.raw ?? 0) > 0
      }), let plan = goals[index].monthlyPlanE4
    else { return }
    let month = lastDay.monthKey.previous
    let day = DateOnly(year: month.year, month: month.month, day: 20)
    guard day >= firstDay, day < lastDay,
      let subcategory = categories.first(where: { $0.id == goals[index].subcategoryId })
    else { return }
    goals[index].planStartMonth = month
    var rng = layer.stream("goal paid ahead", on: day)
    let amount = AmountE4(raw: plan.raw * 3 / 2)
    let parent = subcategory.parentId.flatMap { id in categories.first { $0.id == id } }
    add(
      layer.purchase(
        amount, of: subcategory, parent: parent, at: layer.moment(on: day, rng: &rng),
        account: account, note: goals[index].name, goalId: goals[index].id, rng: &rng),
      calendar: layer.calendar)
  }
}
