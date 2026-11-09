import AppCore
import SwiftUI

/// The words of the main card of Overview: how far the free sum counts, the sum itself with a
/// verdict, and the line under it. Every figure is the free sum's (`FreeMoney`); only the words
/// are put here.
struct OverviewHeadlineContent: Equatable {
  var caption: String
  var title: String
  var line: String
  var verdict: String
  var tone: StatusTone
}

enum OverviewHeadline {
  static let table = "Overview"

  /// `nil` while nothing is counted and there is no figure to show.
  @MainActor
  static func make(free: FreeMoney, environment: AppEnvironment) -> OverviewHeadlineContent? {
    guard free.state == .ready, let main = free.main else { return nil }
    return make(
      main: main, perDay: free.dailyGuide, until: free.until, days: free.days,
      environment: environment)
  }

  /// The same from the figures themselves.
  @MainActor
  static func make(
    main: AmountE4, perDay: AmountE4, until: DateOnly, days dayCount: Int,
    environment: AppEnvironment
  ) -> OverviewHeadlineContent {
    let money = environment.money
    let verdict = FreeVerdict(free: main)
    let days = environment.format("overview.headline.days", table: table, counts: dayCount)
    let caption = environment.format(
      "overview.headline.until", table: table,
      PlanningBlockText.dayText(until, environment), days)
    let taken = environment.language("overview.headline.taken", table: table)
    let line =
      perDay > .zero
      ? environment.format("overview.headline.perDay", table: table, money.rounded(perDay), taken)
      : taken
    switch verdict {
    case .enough:
      return OverviewHeadlineContent(
        caption: caption,
        title: environment.format("overview.headline.free", table: table, money.rounded(main)),
        line: line, verdict: environment.language("overview.verdict.enough", table: table),
        tone: .good)
    case .short:
      return OverviewHeadlineContent(
        caption: caption,
        title: environment.format("overview.headline.short", table: table, money.rounded(-main)),
        line: line, verdict: environment.language("overview.verdict.short", table: table),
        tone: .bad)
    }
  }

  /// The colour of the stripe by the tone; the words carry the meaning too.
  static func stripe(_ tone: StatusTone, in surfaces: ThemeSurfaces) -> Color {
    tone == .bad ? surfaces.negative : surfaces.positive
  }
}

/// «Главный вывод»: the white main card with a coloured stripe, the verdict as a status label.
struct OverviewHeadlineCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    if let snapshot = compute.snapshot,
      let content = OverviewHeadline.make(free: snapshot.planning.freeMoney, environment: environment)
    {
      MainCard(stripe: OverviewHeadline.stripe(content.tone, in: surfaces)) {
        HStack(alignment: .top, spacing: 8) {
          VStack(alignment: .leading, spacing: StyleMetrics.mainCardLineGap) {
            Text(verbatim: content.caption)
              .appFont(StyleType.mainCaption)
              .foregroundStyle(surfaces.secondary)
            Text(verbatim: content.title)
              .appFont(StyleType.mainFigure)
              .foregroundStyle(surfaces.primary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("overview.hero.figure")
            Text(
              verbatim: OverviewHero.line(
                content.line,
                partHidden: OverviewPartHidden.shows(.freeMoney, covered: snapshot.coveredAccounts)
                  ? environment.language("privacy.partHidden", table: "PrivacyScreens") : nil)
                ?? content.line
            )
            .appFont(StyleType.mainLine)
            .foregroundStyle(surfaces.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 4)
          StatusLabel(tone: content.tone, text: content.verdict)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("screen.hero")
    }
  }
}
