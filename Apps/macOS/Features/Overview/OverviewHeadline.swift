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

  /// The one free sum the screen shows, for the owner's horizon (`planning.freeMoneyHorizon`)
  /// with the cushion kept out unless the owner turned that off: the main card and «Из чего
  /// складывается сумма» both read it from here, so they never show two figures.
  @MainActor
  static func configured(
    _ snapshot: DataSnapshot
  ) -> (free: FreeMoney, horizon: FreeMoneyHorizon) {
    (
      snapshot.planning.configuredFreeMoney(ledger: snapshot.ledger),
      snapshot.planning.book.settings.freeMoneyHorizon
    )
  }

  /// The words of the card: «До 9 декабря · 30 дней», «Сейчас свободно 41 600 ₽» (or «Свободно
  /// до дохода …»), and the daily guide or the separate shortages with a recovery guide.
  /// `nil` while nothing is counted and there is no figure to show.
  @MainActor
  static func make(
    free: FreeMoney, horizon: FreeMoneyHorizon, environment: AppEnvironment
  ) -> OverviewHeadlineContent? {
    guard let words = OverviewHero.content(free: free, horizon: horizon, environment),
      let figure = free.grey
    else { return nil }
    let days = environment.format("overview.headline.days", table: table, counts: free.days)
    let caption = environment.format(
      "overview.headline.until", table: table,
      PlanningBlockText.dayText(free.until, environment), days)
    let line = words.lines.first ?? ""
    switch FreeVerdict(free: figure) {
    case .enough:
      return OverviewHeadlineContent(
        caption: caption, title: "\(words.caption) \(words.figure)", line: line,
        verdict: environment.language("overview.verdict.enough", table: table), tone: .good)
    case .short:
      return OverviewHeadlineContent(
        caption: caption,
        title: "\(words.caption) \(words.figure)",
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
  @Environment(\.layoutIdiom) private var idiom

  /// The figure: 24 bold on the Mac and a tablet, 20 on a phone.
  static func figureFont(_ idiom: LayoutIdiom) -> AppFont {
    idiom == .mac ? StyleType.mainFigure : OverviewPageMetrics.of(idiom).mainFigureFont
  }

  var body: some View {
    if let snapshot = compute.snapshot,
      case let (free, horizon) = OverviewHeadline.configured(snapshot),
      let content = OverviewHeadline.make(free: free, horizon: horizon, environment: environment)
    {
      MainCard(stripe: OverviewHeadline.stripe(content.tone, in: surfaces)) {
        HStack(alignment: .top, spacing: 8) {
          VStack(alignment: .leading, spacing: StyleMetrics.mainCardLineGap) {
            Text(verbatim: content.caption)
              .appFont(StyleType.mainCaption)
              .foregroundStyle(surfaces.secondary)
            Text(verbatim: content.title)
              .appFont(Self.figureFont(LayoutIdiom.resolved(idiom)))
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
