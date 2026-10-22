import AppCore
import SwiftUI

/// «Итог поездки»: what the trip cost — every operation of the event, whatever its date, in the
/// rubles of the bank's debits —, against its budget, by day, by category and by currency, and
/// what the people who travelled with the owner still owe. The figures are the core's
/// (`TripSummary`); the screen lays them out. A row with a figure always carries its words, and
/// the budget says «осталось» or «сверх» in words as well as in the sign.
struct TripSummaryView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  let eventId: UUID
  /// The four CSV files handed to the file exporter on a phone; the Mac asks in its panels.
  @State private var exportRequest: PersonalDataExport?
  @State private var exportFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let snapshot = compute.snapshot,
        let event = snapshot.dataset.events.first(where: { $0.id == eventId })
      {
        let summary = TripSummary(
          event: event, ledger: snapshot.ledger,
          budgetRub: TripBudget.inRubles(
            event, rates: snapshot.planning.dayRates, on: environment.today))
        content(event: event, summary: summary, snapshot: snapshot)
      } else {
        Text(verbatim: TravelText.t("travel.summary.missing", environment))
          .foregroundStyle(.secondary)
      }
      HStack {
        Button(TravelText.t("travel.summary.export", environment)) { exportFiles() }
          .disabled(files() == nil)
          .accessibilityIdentifier("travel.summary.export")
        Spacer()
        Button(environment.language("action.ok")) { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("travel.summary.done")
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 600)
    .accessibilityIdentifier("travel.summary")
    .exportsPersonalData(
      $exportRequest, environment: environment,
      onFinished: { result in
        if case .failure = result { exportFailed = true }
      }
    )
    .alert(TravelText.t("travel.export.failed", environment), isPresented: $exportFailed) {
      Button(environment.language("action.ok")) {}
    }
  }

  private func content(event: Event, summary: TripSummary, snapshot: DataSnapshot) -> some View {
    let money = environment.money
    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ScreenTitleBlock(
          title: TravelText.format("travel.summary.title", environment, event.name))
        ScreenHero(
          caption: TravelText.t("travel.summary.total", environment),
          figure: money.rounded(summary.total), lines: [budgetLine(summary)],
          figureIdentifier: "travel.summary.total")
        section("travel.summary.byDay") {
          ForEach(summary.byDay, id: \.day) { row in
            line(PlanningBlockText.dayText(row.day, environment), money.rounded(row.amount))
          }
        }
        section("travel.summary.byCategory") {
          ForEach(summary.byCategory, id: \.categoryId) { row in
            line(
              row.categoryId.flatMap { snapshot.ledger.tree.category($0)?.name }
                ?? TravelText.t("travel.summary.noCategory", environment),
              money.rounded(row.amount))
          }
        }
        section("travel.summary.byCurrency") {
          ForEach(summary.byCurrency, id: \.currency) { row in
            line(
              money.exact(row.amount, currency: row.currency),
              "≈ " + money.rounded(row.rubles))
          }
        }
        section("travel.summary.settlement") {
          if summary.settlement.isEmpty {
            Text(verbatim: TravelText.t("travel.summary.settlement.none", environment))
              .foregroundStyle(.secondary)
          }
          ForEach(summary.settlement, id: \.personId) { share in
            line(
              snapshot.dataset.people.first { $0.id == share.personId }?.name ?? "",
              money.rounded(share.owed))
          }
          Text(verbatim: TravelText.t("travel.summary.settlement.note", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var snapshotEventName: String? {
    compute.snapshot?.dataset.events.first(where: { $0.id == eventId })?.name
  }

  /// The four files of the screen: the same figures, written as CSV.
  private func files() -> [TripSummaryCSV.File]? {
    guard let snapshot = compute.snapshot,
      let event = snapshot.dataset.events.first(where: { $0.id == eventId })
    else { return nil }
    let summary = TripSummary(
      event: event, ledger: snapshot.ledger,
      budgetRub: TripBudget.inRubles(
        event, rates: snapshot.planning.dayRates, on: environment.today))
    return TripSummaryCSV.files(
      for: summary, tripName: event.name,
      category: { id in
        id.flatMap { snapshot.ledger.tree.category($0)?.name }
          ?? TravelText.t("travel.summary.noCategory", environment)
      },
      person: { id in snapshot.dataset.people.first { $0.id == id }?.name ?? "" })
  }

  private func exportFiles() {
    guard let files = files() else { return }
    #if os(macOS)
      TripSummaryExport.run(files: files, environment: environment)
    #else
      let name =
        snapshotEventName.map { "trip-\($0)" } ?? "trip-summary"
      exportRequest = PersonalDataExport(
        defaultName: name, files: files.map { .init(name: $0.name, data: $0.data) })
    #endif
  }

  /// «Осталось 3 500 ₽ из 100 000 ₽» or «Сверх бюджета на 3 500 ₽»; no budget — it says so.
  private func budgetLine(_ summary: TripSummary) -> String {
    let money = environment.money
    guard let budget = summary.budget, let left = summary.versusBudget else {
      return TravelText.t("travel.summary.budget.none", environment)
    }
    if left.isNegative {
      return TravelText.format(
        "travel.summary.budget.over", environment, money.rounded(left.magnitude))
    }
    return TravelText.format(
      "travel.summary.budget.left", environment, money.rounded(left), money.rounded(budget))
  }

  private func section<Content: View>(
    _ key: String, @ViewBuilder _ content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ScreenCardHeader(title: TravelText.t(key, environment))
      content()
    }
    .contentCard()
  }

  private func line(_ name: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(verbatim: name)
      Spacer()
      Text(verbatim: value)
        .appFont(.body.monospacedDigit())
    }
    .accessibilityElement(children: .combine)
  }
}
