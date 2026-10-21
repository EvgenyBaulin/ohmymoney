import AppCore
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// Events with budgets: spent, left, by category; the upcoming ones with what they cost
/// last time and how much to put aside a month. «+ Событие» and «Изменить» set an event and
/// its budget right here — the free sum keeps back what is left of it — each one step of ⌘Z.
struct EventsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.planningCardHosted) private var hosted
  @State private var form: EventFormItem?

  var body: some View {
    ComputedBlock(
      title: hosted ? nil : t("events.title"), state: compute.states.data,
      style: hosted ? .plain : .card, retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let shown = Self.shown(
        snapshot.planning.events, budgeted: snapshot.planning.budgetedEvents)
      VStack(alignment: .leading, spacing: 10) {
        if shown.isEmpty, hosted {
          PlanningEmptyHint(block: .events) { form = EventFormItem(event: nil) }
        } else {
          HStack {
            if shown.isEmpty {
              Text(verbatim: t("events.none")).foregroundStyle(.secondary)
            }
            Spacer()
            Button(t("events.add")) { form = EventFormItem(event: nil) }
              .buttonStyle(.bordered)
              .controlSize(.small)
          }
        }
        ForEach(shown, id: \.event.id) { plan in
          VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
              Text(verbatim: plan.event.name)
              Text(verbatim: PlanningText.eventWhen(plan, environment))
                .appFont(.caption).foregroundStyle(.secondary)
              Spacer(minLength: 6)
              if let budget = plan.budget {
                Text(
                  verbatim: String(
                    format: t("planning.spentOf"), locale: environment.language.locale,
                    environment.money.rounded(plan.spent), environment.money.rounded(budget))
                )
                .monospacedDigit()
              }
              Button(t("events.edit")) { form = EventFormItem(event: plan.event) }
                .buttonStyle(.link)
                .appFont(.caption)
                .accessibilityLabel(Text(verbatim: "\(t("events.edit")): \(plan.event.name)"))
            }
            if plan.overBudget || plan.pacing {
              Label {
                Text(verbatim: t(plan.overBudget ? "events.over" : "events.pacing"))
              } icon: {
                Image(systemName: "exclamationmark.triangle")
              }
              .appFont(.caption)
            }
            if !plan.byCategory.isEmpty {
              Text(
                verbatim: plan.byCategory.prefix(4).map {
                  "\(PlanningText.categoryPath($0.categoryId, tree: snapshot.ledger.tree) ?? "—") \(environment.money.rounded($0.amount))"
                }.joined(separator: " · ")
              )
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            let tied = Self.tiedDues(of: plan.event, snapshot)
            if !tied.isEmpty {
              Text(
                verbatim: environment.format(
                  "events.tiedPayments", table: "Planning",
                  tied.map { due in
                    let name =
                      snapshot.dataset.planning.scheduled.first { $0.id == due.paymentId }?.name
                      ?? "—"
                    return "\(name) \(environment.dates.dayAndMonth(due.due)) — "
                      + environment.money.exact(due.amount, currency: due.currency)
                  }.joined(separator: "; "))
              )
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.isActive, let last = plan.lastTimeTotal {
              Text(
                verbatim: environment.format(
                  "events.lastTime", table: "Planning", environment.money.rounded(last))
                  + (plan.monthlySaving.map {
                    " · "
                      + environment.format(
                        "events.monthly", table: "Planning", environment.money.rounded($0))
                  } ?? "")
              )
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .sheet(item: $form) { item in
      EventForm(original: item.event)
        .handingOver(dependencies)
    }
  }

  /// The events of the block: under way, with a budget, coming within 120 days — and every
  /// event with a budget still ahead however far, since the free sum keeps its budget back
  /// until a day up to a year away (`budgeted`): what it keeps back is here to see and change.
  /// Each once.
  static func shown(_ events: EventsPlanning, budgeted: [EventPlan]) -> [EventPlan] {
    var seen: Set<UUID> = []
    return (events.active + events.withBudget + events.upcoming + budgeted)
      .filter { seen.insert($0.event.id).inserted }
  }

  /// The unpaid due dates of the payments tied to `event`, through its last day: part of its
  /// budget, so the free sum holds them inside it.
  static func tiedDues(of event: Event, _ snapshot: DataSnapshot) -> [ScheduledDue] {
    let tied = Set(snapshot.dataset.planning.scheduled.filter { $0.eventId == event.id }.map(\.id))
    guard !tied.isEmpty, event.endDate >= snapshot.today else { return [] }
    return CashPlan.scheduledDues(
      ledger: snapshot.ledger, book: snapshot.dataset.planning,
      accounts: snapshot.planning.accounts, today: snapshot.today, until: event.endDate,
      matches: snapshot.planning.matches
    ).filter { tied.contains($0.paymentId) }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
