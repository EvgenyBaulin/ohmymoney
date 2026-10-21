import AppCore
import SwiftUI

/// The tile «Самозанятость» of Overview: the tax to pay and by when, the income of the month and
/// what is left of the limit of the year. While self-employment is off it says how to turn it on.
struct SelfEmploymentTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    let snapshot = compute.snapshot
    let today = snapshot?.today ?? environment.today
    if let npd = snapshot?.planning.npd,
      let block = SelfEmploymentBlock.build(npd: npd, today: today)
    {
      SelfEmploymentFigures(block: block, year: npd.year, compact: true)
        .accessibilityIdentifier("selfEmployed.tile")
    } else {
      Text(verbatim: AllocationText.t("selfEmployed.tile.off", environment))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("selfEmployed.tile.off")
    }
  }
}
