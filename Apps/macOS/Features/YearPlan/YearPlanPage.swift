import AppCore
import SwiftUI

/// The page «Год» of Planning: the plan of twelve months on one screen, how the months differ,
/// the forecast of the year, the limits to raise before a dear month, the yearly expenses and
/// the property tax coming, the buffer of the month with the week, and the budgets of events with
/// their templates. It is counted once (`YearPage`) off the main thread and the cards turn ready
/// together; a write keeps the old figures on screen until the new ones are there. Content,
/// never glass. Every write is one step of ⌘Z (`YearActions`).
struct YearPlanPage: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var span: YearPage.Span = .rolling
  @State private var page: YearPage?
  @State private var failed = false
  @State private var dismissals = 0
  @State private var sheet: YearSheet?

  var body: some View {
    ComputedBlock(
      title: nil, state: state, style: .plain, retry: { compute.retry(ComputeStep.data) }
    ) { page in
      YearCards(page: page, span: $span, open: open, dismiss: dismiss)
    }
    .task(id: loadKey) { await load() }
    .sheet(item: $sheet) { sheet in
      YearSheetView(sheet: sheet)
        .handingOver(dependencies)
    }
    .accessibilityIdentifier("year.page")
  }

  private var loadKey: String { "\(compute.generation)|\(span.rawValue)|\(dismissals)" }

  private var state: BlockState<YearPage> {
    if let waiting = compute.states.data.waiting { return waiting.never() }
    if let page { return .ready(page, at: .distantPast) }
    return failed ? .failed(messageKey: "compute.failed.step") : .calculating
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    let monthEnd = compute.states.forecast.value.map { remainder in
      MonthForecast(
        spent: snapshot.summary.expenses.current, planned: snapshot.planning.planned.total,
        remainder: remainder
      ).p50
    }
    do {
      let counted = try await YearPage.load(
        snapshot, analysis: compute.analysis, span: span, dismissed: YearDismissals().ids,
        monthEnd: monthEnd,
        firstWeekday: CalendarScreen.firstWeekday(locale: environment.language.locale))
      guard !Task.isCancelled else { return }
      page = counted
      failed = false
    } catch {
      guard !Task.isCancelled else { return }
      failed = page == nil
    }
  }

  private func open(_ sheet: YearSheet) { self.sheet = sheet }

  private func dismiss(_ id: String) {
    YearDismissals().dismiss(id)
    dismissals += 1
  }
}

/// Which form or editor the page shows.
enum YearSheet: Identifiable {
  /// A form of Planning: a payment, a goal, an expectation.
  case planning(PlanningSheet)
  /// A new expectation that starts filled in (the month a cell of the plan was added to).
  case newExpected(ExpectedIncome)
  case event(Event?)
  case newEvent(day: DateOnly)
  case monthLimit(budget: UUID?, month: MonthKey?)
  case buffer
  case bufferMarks
  case eventItems(Event)
  case fromTemplate
  case saveTemplate(Event)

  var id: String {
    switch self {
    case .planning(let sheet): "planning-\(sheet.id)"
    case .newExpected(let income): "expected-\(income.id.uuidString)"
    case .event(let event): "event-\(event?.id.uuidString ?? "new")"
    case .newEvent(let day): "newEvent-\(day.iso)"
    case .monthLimit(let budget, let month):
      "limit-\(budget?.uuidString ?? "new")-\(month?.iso ?? "")"
    case .buffer: "buffer"
    case .bufferMarks: "bufferMarks"
    case .eventItems(let event): "items-\(event.id.uuidString)"
    case .fromTemplate: "fromTemplate"
    case .saveTemplate(let event): "saveTemplate-\(event.id.uuidString)"
    }
  }
}

/// The editor a `YearSheet` stands for.
struct YearSheetView: View {
  let sheet: YearSheet

  var body: some View {
    switch sheet {
    case .planning(let sheet): PlanningSheetView(sheet: sheet)
    case .newExpected(let income): ExpectedIncomeForm(original: nil, start: income)
    case .event(let event): EventForm(original: event)
    case .newEvent(let day): EventForm(original: nil, today: day)
    case .monthLimit(let budget, let month): MonthLimitSheet(budget: budget, month: month)
    case .buffer: BufferSheet()
    case .bufferMarks: BufferMarksSheet()
    case .eventItems(let event): EventItemsSheet(event: event)
    case .fromTemplate: EventFromTemplateSheet()
    case .saveTemplate(let event): SaveTemplateSheet(event: event)
    }
  }
}
