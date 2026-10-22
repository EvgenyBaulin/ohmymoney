import AppCore
import SwiftUI

/// What the tile «Подписки» shows, apart from the view so a test reads it in both languages.
struct SubscriptionsTileFigure: Equatable {
  var value: String
  var caption: String
  var details: [String]

  /// `nil` when nothing is subscribed to: the tile says so instead of «0 ₽».
  @MainActor
  static func make(_ page: SubscriptionsPage, _ environment: AppEnvironment) -> Self? {
    guard !page.rows.isEmpty else { return nil }
    let money = environment.money
    var details = [
      SubscriptionsText.f(
        "subs.tile.perYear", environment, money.rounded(page.totals.yearlyRub),
        money.rounded(page.perDayRub))
    ]
    if !page.advice.isEmpty {
      details.append(
        SubscriptionsText.f(
          "subs.advice.saving", environment, money.rounded(page.advice.savingYearlyRub)))
    }
    return Self(
      value: money.rounded(page.totals.monthlyRub),
      caption: SubscriptionsText.count("subs.tile.count", environment, page.rows.count),
      details: details)
  }
}

/// «Подписки» on Overview: what everything charged by itself costs a month, with the year and the
/// day under it and, when something could be cancelled, what that would save. The same page the
/// screen shows, so the two never disagree.
struct SubscriptionsTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  var compact = false
  @State private var page: SubscriptionsPage?

  var body: some View {
    let figure = page.flatMap { SubscriptionsTileFigure.make($0, environment) }
    ComputedBlock(
      title: OverviewTileText.name(of: .subscriptions, environment), state: state(figure),
      fillsHeight: true, emptyReason: SubscriptionsText.t("subs.tile.none", environment),
      retry: { compute.retry(ComputeStep.data) }
    ) { figure in
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(verbatim: figure.value)
            .appFont(compact ? .title3.monospacedDigit() : .title2.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityIdentifier("overview.subscriptions.value")
        }
        Text(verbatim: figure.caption)
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        if !compact {
          ForEach(figure.details, id: \.self) { line in
            Text(verbatim: line)
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .accessibilityElement(children: .combine)
    }
    .task(id: compute.generation) { await load() }
  }

  private func state(_ figure: SubscriptionsTileFigure?) -> BlockState<SubscriptionsTileFigure> {
    if let waiting = compute.states.data.waiting { return waiting.never() }
    guard page != nil else { return .calculating }
    return figure.map { .ready($0, at: .distantPast) } ?? .notEnoughData
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    guard let counted = try? await compute.analysis.subscriptionsPage(snapshot),
      !Task.isCancelled
    else { return }
    page = counted
  }
}
