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
  @State private var width: CGFloat = 0
  @Environment(\.themeSurfaces) private var surfaces

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
        Spacer()
        Button(environment.language("action.ok")) { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("travel.summary.done")
      }
    }
    .padding(20)
    .background(surfaces.background)
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

  /// The cards of the screen in the order they are dealt into columns.
  private enum Card: Hashable {
    case budget, currency, category, day, settlement
  }

  private func content(event: Event, summary: TripSummary, snapshot: DataSnapshot) -> some View {
    let money = environment.money
    let cards: [Card] =
      [summary.budget != nil ? .budget : nil, .currency, .category, .day, .settlement]
      .compactMap { $0 }
    let columns = ScreenColumns.count(forWidth: width - 40)
    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ScreenTitleBlock(
          title: TravelText.format("travel.summary.title", environment, event.name))
        ScreenHero(
          caption: TravelText.t("travel.summary.total", environment),
          figure: money.rounded(summary.total), lines: [budgetLine(summary)],
          figureIdentifier: "travel.summary.total")
        HStack(alignment: .top, spacing: 16) {
          ForEach(Array(ScreenColumns.deal(cards, into: columns).enumerated()), id: \.offset) {
            _, column in
            VStack(alignment: .leading, spacing: 16) {
              ForEach(column, id: \.self) { card in
                self.card(card, summary: summary, snapshot: snapshot)
              }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }

  @ViewBuilder
  private func card(_ card: Card, summary: TripSummary, snapshot: DataSnapshot) -> some View {
    let money = environment.money
    switch card {
    case .budget:
      budgetCard(summary)
    case .currency:
      section("travel.summary.byCurrency", caption: nil) {
        ForEach(summary.byCurrency, id: \.currency) { row in
          tileRow(
            symbol: "banknote", title: row.currency.code,
            value: money.exact(row.amount, currency: row.currency) + " ≈ "
              + money.rounded(row.rubles))
        }
      }
    case .category:
      section("travel.summary.byCategory", caption: nil) {
        ForEach(summary.byCategory, id: \.categoryId) { row in
          line(
            row.categoryId.flatMap { snapshot.ledger.tree.category($0)?.name }
              ?? TravelText.t("travel.summary.noCategory", environment),
            money.rounded(row.amount))
        }
      }
    case .day:
      section("travel.summary.byDay", caption: nil) {
        ForEach(summary.byDay, id: \.day) { row in
          line(PlanningBlockText.dayText(row.day, environment), money.rounded(row.amount))
        }
      }
    case .settlement:
      section(
        "travel.summary.settlement", caption: TravelText.t("travel.summary.forOthers", environment)
      ) {
        if summary.settlement.isEmpty {
          Text(verbatim: TravelText.t("travel.summary.settlement.none", environment))
            .foregroundStyle(.secondary)
        }
        ForEach(summary.settlement, id: \.personId) { share in
          tileRow(
            symbol: "person.crop.circle.badge.clock",
            title: snapshot.dataset.people.first { $0.id == share.personId }?.name ?? "",
            value: money.rounded(share.owed))
        }
        Text(verbatim: TravelText.t("travel.summary.settlement.note", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
        Button {
          exportFiles()
        } label: {
          Text(verbatim: TravelText.t("travel.summary.export", environment))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(files() == nil)
        .accessibilityIdentifier("travel.summary.export")
      }
    }
  }

  /// «Бюджет поездки · 36 %» over the bar and what is left of it in words.
  private func budgetCard(_ summary: TripSummary) -> some View {
    let share: Int = {
      guard let budget = summary.budget, budget.raw > 0 else { return 0 }
      let ratio = Decimal(summary.total.raw) / Decimal(budget.raw) * Decimal(Shares.whole)
      return max(0, NSDecimalNumber(decimal: ratio).intValue)
    }()
    return VStack(alignment: .leading, spacing: 10) {
      ScreenCardHeader(
        title: TravelText.t("travel.summary.budgetCard", environment),
        caption: environment.money.percent(basisPoints: share, fractionDigits: 0))
      GoalProgressBar(basisPoints: share)
      Text(verbatim: budgetLine(summary))
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("travel.summary.budget")
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
    _ key: String, caption: String?, @ViewBuilder _ content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ScreenCardHeader(title: TravelText.t(key, environment), caption: caption)
      content()
    }
    .contentCard()
  }

  /// A row with a tile: the symbol says what it is, the name and the figure at the right.
  private func tileRow(symbol: String, title: String, value: String) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: symbol)
        .appFont(.callout.weight(.semibold))
        .foregroundStyle(surfaces.accent)
        .frame(width: 36, height: 36)
        .background(surfaces.accent.opacity(0.14), in: .rect(cornerRadius: 10))
        .accessibilityHidden(true)
      Text(verbatim: title)
        .appFont(.body.weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: 6)
      Text(verbatim: value)
        .appFont(.body.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .accessibilityElement(children: .combine)
  }

  private func line(_ name: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(verbatim: name)
        .foregroundStyle(.secondary)
      Spacer()
      Text(verbatim: value)
        .appFont(.body.weight(.semibold).monospacedDigit())
    }
    .accessibilityElement(children: .combine)
  }
}
