import AppCore
import SwiftUI

/// The event a form edits, or none for a new one.
struct EventFormItem: Identifiable {
  let event: Event?
  var id: String { event?.id.uuidString ?? "new" }
}

/// An event and its budget: its name, its days, and how much it may cost — an empty budget is
/// none. «Save» writes one `PlanningChange`, one step of ⌘Z.
struct EventForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let original: Event?
  @State private var name: String
  /// The event's own days from the first frame: pickers given a day and its minimum in one
  /// update later show a day that is not the event's (`EventDaysFields`). A new event without
  /// `today` gets today's when it appears, and its pickers are made only then.
  @State private var start: DateOnly?
  @State private var end: DateOnly?
  @State private var budget: AmountE4

  init(original: Event?, today: DateOnly? = nil) {
    self.original = original
    _name = State(initialValue: original?.name ?? "")
    _start = State(initialValue: original?.startDate ?? today)
    _end = State(initialValue: original.map { max($0.startDate, $0.endDate) } ?? today)
    _budget = State(initialValue: original?.budgetE4 ?? .zero)
  }

  var body: some View {
    let event = edited
    let issue = PlanningActions.issue(
      of: event, among: compute.snapshot?.dataset.events ?? [])
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "events.form.new" : "events.form.edit"))
        .appFont(.headline)
      Form {
        TextField(text: $name) { Text(verbatim: t("events.form.name")) }
        if let start, let end {
          EventDaysFields(
            owner: original?.id,
            start: Binding(get: { self.start ?? start }, set: { self.start = $0 }),
            end: Binding(get: { self.end ?? end }, set: { self.end = $0 }),
            startLabel: t("events.form.start"), endLabel: t("events.form.end"))
        }
        LabeledContent(t("events.form.budget")) {
          HStack {
            AmountField(amount: $budget)
            Text(verbatim: "₽").foregroundStyle(.secondary)
          }
        }
        Text(verbatim: t("events.form.budgetHint"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let issue {
          Text(verbatim: t("events.issue.\(issue.rawValue)"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: issue == nil) {
        guard let dependencies else { return false }
        return PlanningActions(dependencies).save(event)
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 400)
    .onAppear {
      guard start == nil else { return }
      start = environment.today
      end = environment.today
    }
  }

  /// The event as the form has it: the name without spaces around it, the days in order, an
  /// empty or zero budget as none.
  private var edited: Event {
    let today = environment.today
    var event = original ?? Event(name: "", startDate: today, endDate: today)
    event.name = PlanningActions.trimmed(name)
    event.startDate = start ?? today
    event.endDate = max(event.startDate, end ?? event.startDate)
    event.budgetE4 = budget > .zero ? budget : nil
    return event
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
