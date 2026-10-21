import AppCore
import SwiftUI

/// «Капитал» on Overview: net worth, how it changed this month, what there is and what is owed.
/// The change has an arrow and a sign and no colour of good or bad. A click opens «Капитал».
struct CapitalTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .capital, environment),
      state: compute.states.data.flatMap { snapshot, at in
        let lines = CapitalTileLines(snapshot.planning.capital, environment)
        return lines.isEmpty ? .notEnoughData : .ready(lines, at: at)
      },
      fillsHeight: true, emptyReason: CapitalText.t("capital.empty", environment),
      retry: { compute.retry(ComputeStep.data) }
    ) { lines in
      Button {
        NotificationCenter.default.post(
          name: .selectSection, object: MainWindow.Section.capital.shortcutIndex)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: lines.net)
            .appFont(.title2.monospacedDigit())
          if let change = lines.change {
            Label {
              Text(verbatim: change)
            } icon: {
              Image(systemName: lines.arrow)
            }
            .appFont(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
          }
          Text(verbatim: lines.haveAndOwe)
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("overview.capital")
    }
  }
}

/// The words of the tile «Капитал», worked out from the snapshot of the core.
struct CapitalTileLines: Hashable, Sendable {
  /// «4,213,000 ₽».
  var net: String
  /// «+85,000 ₽ за месяц»; `nil` without the end of last month.
  var change: String?
  /// The symbol of the change: up, down, level.
  var arrow: String
  /// «Есть 4,500,000 ₽ · Должен 287,000 ₽».
  var haveAndOwe: String
  /// Nothing counted at all: no line in either column.
  var isEmpty: Bool

  @MainActor
  init(_ capital: CapitalSnapshot, _ environment: AppEnvironment) {
    let money = environment.money
    let now = capital.now
    net = money.rounded(now.netRub)
    change = capital.changeThisMonth.map {
      CapitalText.format("capital.tile.thisMonth", environment, money.signedRounded($0))
    }
    arrow = CapitalText.arrow(of: capital.changeThisMonth ?? .zero)
    haveAndOwe = CapitalText.format(
      "capital.tile.haveOwe", environment, money.rounded(now.haveRub),
      money.rounded(now.iOweRub))
    isEmpty = capital.breakdown.have.isEmpty && capital.breakdown.owe.isEmpty
  }
}
