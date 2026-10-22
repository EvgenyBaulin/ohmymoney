import AppCore
import SwiftUI

/// The cards of a counted page, so a test lays them out with figures of its own.
struct YearCards: View {
  @Dependency(\.environment) private var environment
  @Environment(\.windowWidth) private var windowWidth
  let page: YearPage
  @Binding var span: YearPage.Span
  let open: (YearSheet) -> Void
  let dismiss: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker(YearText.t("year.span", environment), selection: $span) {
        Text(verbatim: YearText.t("year.span.rolling", environment)).tag(YearPage.Span.rolling)
        Text(verbatim: YearText.t("year.span.calendar", environment)).tag(YearPage.Span.calendar)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("year.span")
      ScreenHero(
        caption: YearText.f(
          "year.hero.caption", environment,
          environment.dates.monthTitle(page.plan.months.first ?? page.today.monthKey),
          environment.dates.monthTitle(page.plan.months.last ?? page.today.monthKey)),
        figure: "≈ " + environment.money.rounded(page.forecast.usualTotal),
        lines: YearText.heroLines(page, environment), figureIdentifier: "year.hero.figure")
      YearGridCard(page: page, open: open)
      pair {
        YearSeasonCard(page: page)
      } second: {
        YearForecastCard(page: page)
      }
      YearLimitsCard(page: page, open: open, dismiss: dismiss)
      YearAdviceCard(page: page, dismiss: dismiss)
      pair {
        YearBufferCard(page: page, open: open)
      } second: {
        YearEventsCard(page: page, open: open)
      }
    }
  }

  @ViewBuilder
  private func pair<First: View, Second: View>(
    @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second
  ) -> some View {
    if ScreenWidth.isCompact(windowWidth) || windowWidth < ScreenColumns.twoFrom {
      VStack(alignment: .leading, spacing: 16) {
        first()
        second()
      }
    } else {
      HStack(alignment: .top, spacing: 16) {
        first()
        second()
      }
    }
  }
}

// MARK: - Seasons

/// How the months differ: twelve bars against a usual month, the dear ones marked with a symbol
/// and «дороже на 38 %», and the note of how many years it stands on.
struct YearSeasonCard: View {
  @Dependency(\.environment) private var environment
  let page: YearPage

  var body: some View {
    YearCard(
      title: YearText.t("year.season.title", environment), symbol: "chart.bar",
      subtitle: YearText.seasonNote(page, environment), identifier: "year.season"
    ) {
      if let season = page.season.seasonality {
        bars(season)
        let dear = season.expensiveMonths
        if dear.isEmpty {
          Text(verbatim: YearText.t("year.season.none", environment))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(dear, id: \.month) { month in
              Label {
                Text(
                  verbatim: YearText.f(
                    "year.season.line", environment, YearText.monthName(month.month, environment),
                    YearText.against(month, environment)))
              } icon: {
                Image(systemName: "arrow.up.circle")
              }
              .appFont(.callout)
              .accessibilityIdentifier("year.season.dear.\(month.month)")
            }
          }
        }
      } else {
        Label {
          Text(verbatim: environment.language("common.noData"))
        } icon: {
          Image(systemName: "hourglass")
        }
        .foregroundStyle(.secondary)
      }
    }
  }

  /// January…December as bars, tallest the dearest; a dear month has an arrow above its bar,
  /// so the colour only confirms.
  private func bars(_ season: Seasonality) -> some View {
    let top = max(season.months.map(\.indexBp).max() ?? Seasonality.whole, 1)
    return HStack(alignment: .bottom, spacing: 4) {
      ForEach(season.months, id: \.month) { month in
        VStack(spacing: 2) {
          Image(systemName: month.isExpensive ? "arrow.up" : "minus")
            .appFont(.caption)
            .foregroundStyle(month.isExpensive ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .accessibilityHidden(true)
          RoundedRectangle(cornerRadius: 3)
            .fill(month.isExpensive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.5)))
            .frame(height: max(4, 64 * CGFloat(month.indexBp) / CGFloat(top)))
          Text(verbatim: YearText.monthName(month.month, environment))
            .appFont(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          Text(
            verbatim:
              "\(YearText.monthName(month.month, environment)), \(YearText.against(month, environment))"
          ))
      }
    }
    .frame(height: 96, alignment: .bottom)
  }
}

// MARK: - The forecast

/// The spending of the twelve months ahead: the total as usual and as in dear months, the biggest
/// categories with the same pair, and the end of this month as a pair.
struct YearForecastCard: View {
  @Dependency(\.environment) private var environment
  let page: YearPage

  /// The categories listed before «Показать все».
  static let listed = 6

  @State private var showsAll = false

  var body: some View {
    YearCard(
      title: YearText.t("year.forecast.title", environment), symbol: "chart.line.uptrend.xyaxis",
      subtitle: page.forecast.lowData
        ? YearText.t("year.forecast.lowData", environment)
        : YearText.t("year.forecast.subtitle", environment), identifier: "year.forecast"
    ) {
      if let range = page.monthRange {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: YearText.t("year.range.title", environment)).appFont(
            .callout.weight(.semibold))
          Text(verbatim: rangeLine(range))
            .appFont(.callout.monospacedDigit())
            .accessibilityIdentifier("year.range")
        }
      }
      let rows = sortedCategories
      if rows.isEmpty {
        Text(verbatim: YearText.t("year.forecast.none", environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
      ForEach(Array((showsAll ? rows : Array(rows.prefix(Self.listed))).enumerated()), id: \.offset)
      { _, row in
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: name(row.categoryId)).lineLimit(1)
          Spacer(minLength: 8)
          Text(verbatim: line(row))
            .monospacedDigit()
            .appFont(.callout)
        }
        .accessibilityElement(children: .combine)
      }
      if rows.count > Self.listed {
        Button(YearText.t(showsAll ? "year.forecast.less" : "year.forecast.more", environment)) {
          showsAll.toggle()
        }
        .buttonStyle(.link)
        .appFont(.caption)
      }
    }
  }

  private var sortedCategories: [CategoryYearForecast] {
    page.forecast.categories.sorted {
      ($1.usualTotal, $0.categoryId?.uuidString ?? "") < (
        $0.usualTotal, $1.categoryId?.uuidString ?? ""
      )
    }
  }

  private func name(_ id: UUID?) -> String {
    id.flatMap { page.categoryNames[$0] } ?? YearText.t("year.forecast.other", environment)
  }

  /// «≈ 410 000 ₽ (380 000–450 000)»: as usual, and as in dear months when that is more.
  private func line(_ row: CategoryYearForecast) -> String {
    let money = environment.money
    guard row.expensiveTotal > row.usualTotal else { return "≈ " + money.rounded(row.usualTotal) }
    return YearText.f(
      "year.forecast.line", environment, money.rounded(row.usualTotal),
      money.rounded(row.expensiveTotal))
  }

  private func rangeLine(_ range: MonthRange) -> String {
    let money = environment.money
    guard range.hasSecondFigure else {
      return YearText.f("year.range.usual", environment, money.rounded(range.usual))
    }
    return YearText.f(
      "year.range.both", environment, money.rounded(range.usual), money.rounded(range.expensive))
  }
}
