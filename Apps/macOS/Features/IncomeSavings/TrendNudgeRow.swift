import AppCore
import SwiftUI

/// The line of «Стоит посмотреть» that says spending grows faster than income («за 3 месяца
/// доход +20 %, траты +25 % к тем же месяцам год назад»). It is due when it is switched on, the
/// spending really outpaces the income and it was not shown yet this quarter.
///
/// Once due it stays on the card until the owner answers: «Понятно» remembers the quarter, so
/// the line comes back no sooner than the next one, and «Больше не показывать» switches it off
/// for good (the switch is in Settings → Планирование). It is not marked as shown when it
/// appears — that write would reload the data and take the line away before it was read.
struct TrendNudgeRow: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  /// The trend while the line is due; kept for the session once it appeared.
  @State private var trend: SpendingFollowsIncome?

  var body: some View {
    Group {
      if let trend {
        VStack(alignment: .leading, spacing: 4) {
          Label {
            Text(verbatim: IncomeSavingsText.nudgeLine(trend, environment))
              .appFont(.callout)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "arrow.up.right")
              .accessibilityHidden(true)
          }
          HStack(spacing: 12) {
            Button(IncomeSavingsText.t("income.nudge.done", environment)) {
              answer(neverAgain: false)
            }
            .accessibilityIdentifier("income.nudge.done")
            Button(IncomeSavingsText.t("income.nudge.stop", environment)) {
              answer(neverAgain: true)
            }
            .accessibilityIdentifier("income.nudge.stop")
          }
          .buttonStyle(.link)
          .appFont(.caption)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("income.nudge")
      }
    }
    .task(id: compute.generation) { await refresh() }
  }

  private func refresh() async {
    guard trend == nil, compute.states.data.phase == .ready, let snapshot = compute.snapshot
    else { return }
    let due = try? await compute.analysis.incomeSavings.trendNudge(snapshot)
    guard !Task.isCancelled, let due else { return }
    trend = due
  }

  private func answer(neverAgain: Bool) {
    guard let snapshot = compute.snapshot else { return }
    let settings = snapshot.dataset.incomeSavings
    environment.saveIncomeSavings(
      neverAgain
        ? TrendNudge.turnedOff(settings)
        : TrendNudge.markShown(settings, today: snapshot.today))
    trend = nil
  }
}
