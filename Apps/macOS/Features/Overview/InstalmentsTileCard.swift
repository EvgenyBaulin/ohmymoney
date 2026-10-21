import AppCore
import SwiftUI

/// The tile «Рассрочки» of Overview: what the open instalment plans and purchases on credit
/// still ask, in rubles at today's rate, and the payments coming first — «В рассрочках 34,000 ₽
/// · ближайшее 2,500 ₽ 14 ноября». A click opens «Почему так»; «Открыть «Долги»» goes where the
/// plans are paid.
struct InstalmentsTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .installments, environment),
      state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      InstalmentsTileContent(
        summary: snapshot.planning.instalments,
        names: Dictionary(
          snapshot.dataset.debts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
        ))
    }
  }
}

/// The body of the tile, apart so a test lays it out with figures of its own.
struct InstalmentsTileContent: View {
  @Dependency(\.environment) private var environment
  let summary: InstalmentsSummary
  /// The names of the debts the payments are of.
  var names: [UUID: String] = [:]
  /// How many of the coming payments the tile lists.
  static let shown = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if summary.count == 0 {
        Text(verbatim: Self.t("overview.instalments.none", environment))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("overview.instalments.none")
      } else {
        Text(verbatim: environment.money.rounded(summary.totalRub))
          .appFont(.title2.monospacedDigit())
          .accessibilityIdentifier("overview.instalments.total")
        Text(verbatim: Self.headline(summary, environment))
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(Array(summary.next.prefix(Self.shown).enumerated()), id: \.offset) { _, payment in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: environment.dates.dayAndMonth(payment.due))
              .foregroundStyle(.secondary)
            Text(verbatim: names[payment.debtId] ?? "—")
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(verbatim: environment.money.rounded(payment.amountE4, currency: payment.currency))
              .monospacedDigit()
          }
          .appFont(.callout)
          .accessibilityElement(children: .combine)
        }
        if !summary.withoutRate.isEmpty {
          Text(verbatim: Self.t("overview.instalments.withoutRate", environment))
            .appFont(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Button(Self.t("overview.instalments.open", environment)) {
        NotificationCenter.default.post(
          name: .selectSection, object: MainWindow.Section.debts.shortcutIndex)
      }
      .buttonStyle(.link)
      .accessibilityIdentifier("overview.instalments.open")
    }
  }

  /// «Рассрочек: 2 · ближайшее 2,500 ₽ 14 ноября»; without a payment to come, the count alone.
  static func headline(_ summary: InstalmentsSummary, _ environment: AppEnvironment) -> String {
    let count = environment.format(
      "overview.instalments.count", table: "Overview", counts: summary.count)
    guard let next = summary.next.first else { return count }
    return environment.format(
      "overview.instalments.next", table: "Overview", count,
      environment.money.rounded(next.amountE4, currency: next.currency),
      environment.dates.dayAndMonth(next.due))
  }

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: "Overview")
  }

  static let keys = [
    "overview.instalments.none", "overview.instalments.withoutRate", "overview.instalments.open",
    "overview.instalments.next",
  ]
}
