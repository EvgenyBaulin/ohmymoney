import AppCore
import Foundation

/// The writes of the page «Год». Each is one call of the store or of `PlanningActions` and so one
/// step of ⌘Z, except «Новое событие из шаблона», which is two (the event, then its articles):
/// the event is an ordinary one and can be taken back alone.
@MainActor
struct YearActions {
  let deps: AppDependencies

  init(_ deps: AppDependencies) { self.deps = deps }

  var environment: AppEnvironment { deps.environment }
  var store: TransactionsStore { deps.store }
  private var planning: PlanningActions { PlanningActions(deps) }

  // MARK: Limits

  /// «Поднять лимит на декабрь»: the suggested amount for that one month.
  @discardableResult
  func raiseLimit(_ suggestion: LimitSeasonSuggestion) -> Bool {
    store.setMonthLimit(suggestion.suggested, budget: suggestion.budgetId, month: suggestion.month)
  }

  @discardableResult
  func setMonthLimit(_ amount: AmountE4, budget: UUID, month: MonthKey) -> Bool {
    store.setMonthLimit(amount, budget: budget, month: month)
  }

  @discardableResult
  func removeMonthLimit(_ exception: LimitMonthException) -> Bool {
    store.removeMonthLimit(budget: exception.budgetId, month: exception.month)
  }

  // MARK: Reserves and taxes

  /// «Завести копилку»: an ordinary goal with a monthly plan and a date (`AnnualReserve`).
  @discardableResult
  func startReserve(_ expense: YearlyExpense, name: String) -> Bool {
    planning.save(AnnualReserve.goal(for: expense, name: name, today: environment.today))
  }

  /// «Запланировать»: the yearly payment of the property tax, reminding two weeks ahead.
  @discardableResult
  func planTax(_ hint: PropertyTaxHint) -> Bool {
    planning.save(hint.scheduledPayment(), previous: nil)
  }

  // MARK: Buffer

  @discardableResult
  func saveBuffer(_ amount: AmountE4, income: AmountE4) -> Bool {
    store.setBuffer(
      MonthBufferSettings(amount: amount, incomeAtSet: amount.raw > 0 ? income : nil))
  }

  /// The answer to «Доход вырос больше чем на 10 % — повысить буфер?»: yes with the offered sum,
  /// or no; the income is noted either way, so the question comes again only after another rise.
  @discardableResult
  func answerRaise(
    settings: MonthBufferSettings, income: AmountE4, accepted newAmount: AmountE4?
  ) -> Bool {
    store.setBuffer(MonthBuffer.answered(settings: settings, income: income, newAmount: newAmount))
  }

  @discardableResult
  func setMarks(_ marks: Set<UUID>) -> Bool { store.setBufferMarks(marks) }

  // MARK: Events

  /// A new event from a template: the event with the budget given, then its articles — the
  /// template's shares of that budget, the last taking what is left.
  @discardableResult
  func createEvent(
    from template: EventTemplate, name: String, start: DateOnly, end: DateOnly,
    budget: AmountE4
  ) -> Bool {
    var event = Event(name: name, startDate: start, endDate: max(start, end), budgetE4: budget)
    event.kind = template.eventKind
    guard planning.save(event) else { return false }
    let items = YearText.localizedItems(template, event: event.id, total: budget, environment)
    return store.setEventItems(items, event: event.id)
  }

  @discardableResult
  func setItems(_ items: [EventBudgetItem], event: UUID) -> Bool {
    let ordered = items.enumerated().map { index, item -> EventBudgetItem in
      var item = item
      item.eventId = event
      item.sort = index
      return item
    }
    return store.setEventItems(ordered, event: event)
  }

  @discardableResult
  func saveTemplate(name: String, items: [EventBudgetItem]) -> Bool {
    guard let template = EventTemplates.saving(name: name, items: items) else { return false }
    return store.saveEventTemplate(template)
  }

  @discardableResult
  func deleteTemplate(_ template: EventTemplate) -> Bool {
    store.deleteEventTemplate(id: template.id)
  }
}
