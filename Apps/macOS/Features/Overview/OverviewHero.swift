import AppCore
import SwiftUI

/// «Можно тратить сейчас» on the theme's hero gradient, over the groups of tiles on a wide
/// screen (an iPad): the one figure of the screen, the free sum with its sentence about the day.
/// The «Свободные средства» tile keeps the terms it is made of. Content, never glass; the figures
/// are the core's, only put into words (`PlanningHero`).
struct OverviewHero: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  /// The hero stands over tiles in several columns, i.e. a wide tablet; on the Mac the free-sum
  /// tile carries the figure, on a phone the first tile does.
  static func shows(forWidth width: CGFloat) -> Bool {
    #if os(iOS)
      width >= 700
    #else
      false
    #endif
  }

  var body: some View {
    if let snapshot = compute.snapshot,
      let content = PlanningHero.make(free: snapshot.planning.freeMoney, environment: environment)
    {
      ScreenHero(
        caption: content.caption, figure: content.figure,
        lines: Array(content.lines.prefix(1)), figureIdentifier: "overview.hero.figure")
    }
  }
}
