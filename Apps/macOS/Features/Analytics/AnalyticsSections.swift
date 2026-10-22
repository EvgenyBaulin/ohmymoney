import AppCore
import SwiftUI

/// The page of one section: the line of its period, then its cards — two in a row on a wide
/// window, the wide charts always across. Every card shows the state of the section's one
/// model, so they turn ready together; the words come from `AnalyticsText` in the language of
/// the moment.
struct AnalyticsSectionView: View {
  @Dependency(\.environment) private var environment
  let section: AnalyticsSection
  let title: String
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void
  @State private var width: CGFloat = 0

  /// From here on two small charts stand side by side.
  static let wideWidth: CGFloat = 860

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(verbatim: headerLine)
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        sectionBody
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }

  private var isWide: Bool { width >= Self.wideWidth }

  private var headerLine: String {
    AnalyticsText.sectionHeader(section, title: title, model: state.value, environment)
  }

  @ViewBuilder
  private var sectionBody: some View {
    switch section {
    case .overview: OverviewSection(state: state, retry: retry, isWide: isWide)
    case .quality: QualitySection(state: state, retry: retry, isWide: isWide)
    case .others: OthersSection(state: state, retry: retry, isWide: isWide)
    case .forWhom: ForWhomSection(state: state, retry: retry, isWide: isWide)
    case .places: PlacesSection(state: state, retry: retry, isWide: isWide)
    case .events: EventsSection(state: state, retry: retry)
    case .paymentMethods: PaymentMethodsSection(state: state, retry: retry)
    case .forecast: ForecastSection(state: state, retry: retry)
    case .anomalies: AnomaliesSection(state: state, retry: retry)
    case .modelQuality: ModelQualitySection(state: state, retry: retry)
    }
  }
}

// MARK: - Overview

private struct OverviewSection: View {
  @Dependency(\.environment) private var environment
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void
  let isWide: Bool
  @State private var expanded: Set<ReportKey> = []
  @State private var stepChoice = SeriesStepChoice()

  var body: some View {
    let names = state.value?.names ?? AnalyticsNames()
    VStack(alignment: .leading, spacing: 16) {
      AnalyticsCard(
        block: AnalyticsBlock.categories.rawValue,
        title: t("analytics.block.categories"), subtitle: t("analytics.basis.byDate"),
        state: state.block { $0.overview?.categories }, retry: retry
      ) { values in
        RankedBarChart(
          bars: AnalyticsText.bars(values, names: names, expanded: expanded, environment),
          onToggle: toggle)
      }

      AnalyticsPair(isWide: isWide) {
        seriesCard
      } second: {
        AnalyticsCard(
          block: AnalyticsBlock.incomeVsExpenses.rawValue,
          title: t("analytics.block.incomeVsExpenses"), subtitle: t("analytics.basis.byMonth"),
          state: state.block { $0.overview?.incomeVsExpenses }, retry: retry
        ) { months in
          let spansYears = Set(months.map(\.month.year)).count > 1
          PairedColumnChart(
            pairs: months.map { month in
              ChartPair(
                id: month.month.iso,
                axisLabel: environment.dates.shortMonth(month.month, withYear: spansYears),
                spokenLabel: environment.dates.monthTitle(month.month), first: month.income,
                second: month.expenses, firstText: environment.money.rubles(month.income),
                secondText: environment.money.rubles(month.expenses))
            },
            first: AnalyticsText.incomeStyle(environment),
            second: AnalyticsText.expensesStyle(environment))
        }
      }

      AnalyticsPair(isWide: isWide) {
        AnalyticsCard(
          block: AnalyticsBlock.incomeSources.rawValue,
          title: t("analytics.block.incomeSources"), subtitle: t("analytics.basis.byMonthFor"),
          state: state.block { $0.overview?.incomeSources }, retry: retry
        ) { values in
          RankedBarChart(
            bars: AnalyticsText.bars(values, names: names, environment), tint: .green)
        }
      } second: {
        AnalyticsCard(
          block: AnalyticsBlock.weekdays.rawValue, title: t("analytics.block.weekdays"),
          subtitle: weekdaysBasis, state: state.block { $0.overview?.weekdays }, retry: retry
        ) { model in
          ColumnChart(columns: AnalyticsText.weekdayColumns(model, environment))
        }
      }

      AnalyticsCard(
        block: AnalyticsBlock.comparison.rawValue, title: t("analytics.block.comparison"),
        subtitle: comparisonBasis, state: state.block { $0.overview?.comparison },
        retry: retry
      ) { model in
        ComparisonChart(model: model)
      }
    }
  }

  private var seriesCard: some View {
    AnalyticsCard(
      block: AnalyticsBlock.series.rawValue, title: t("analytics.block.series"),
      subtitle: t("analytics.basis.byDate"), state: state.block { $0.overview?.series },
      retry: retry
    ) {
      Picker(selection: stepBinding) {
        ForEach(TimeSeries.Step.allCases, id: \.self) { step in
          Text(verbatim: t("analytics.step.\(step.rawValue)")).tag(step)
        }
      } label: {
        Text(verbatim: t("analytics.step.title"))
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
    } content: { steps in
      let series = steps.series(stepChoice.step(for: steps))
      ColumnChart(
        columns: AnalyticsText.columns(series, environment),
        xLabels: AnalyticsText.columnTicks(series, environment),
        average: series.average.map {
          ChartRule(
            value: $0,
            label: AnalyticsText.format(
              "analytics.average", environment, environment.money.rubles($0)))
        })
    }
  }

  /// The step of the series: the one chosen, or the one the model prefers for its period.
  private var stepBinding: Binding<TimeSeries.Step> {
    Binding(
      get: { state.value?.overview?.series.content.map(stepChoice.step(for:)) ?? .day },
      set: { chosen in
        if let steps = state.value?.overview?.series.content {
          stepChoice.choose(chosen, for: steps)
        }
      })
  }

  private var weekdaysBasis: String {
    guard let model = state.value?.overview?.weekdays.content, !model.interval.isEmpty else {
      return t("analytics.basis.weekdaysPlain")
    }
    return AnalyticsText.format(
      "analytics.basis.weekdays", environment, environment.dates.span(model.interval))
  }

  private var comparisonBasis: String {
    guard let model = state.value?.overview?.comparison.content else {
      return t("analytics.basis.cumulative")
    }
    return AnalyticsText.format(
      "analytics.basis.comparison", environment, environment.dates.span(model.current),
      environment.dates.span(model.previous))
  }

  private func toggle(_ id: String) {
    guard
      let key = state.value?.overview?.categories.content?.first(where: {
        $0.key.description == id
      })?.key
    else { return }
    if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// The step of «По дням / неделям / месяцам» the person chose, kept for periods of one shape:
/// one month, or several (the step the model prefers tells them apart — days, or months).
/// «Месяцы» chosen on a year would be one column on a month, so a period of the other shape
/// opens on its own preferred step, or on the one chosen for that shape before; stepping
/// from month to month keeps the choice.
struct SeriesStepChoice: Hashable {
  /// The chosen step by the preferred step of the period it was chosen on.
  private var chosen: [TimeSeries.Step: TimeSeries.Step] = [:]

  func step(for steps: SeriesSteps) -> TimeSeries.Step {
    chosen[steps.preferred] ?? steps.preferred
  }

  mutating func choose(_ step: TimeSeries.Step, for steps: SeriesSteps) {
    chosen[steps.preferred] = step
  }
}

/// The period and the one before, day by day as running totals, with the change of
/// spending and income in words under it.
private struct ComparisonChart: View {
  @Dependency(\.environment) private var environment
  let model: ComparisonModel

  var body: some View {
    let money = environment.money
    let longest = max(model.currentPoints.count, model.previousPoints.count)
    VStack(alignment: .leading, spacing: 8) {
      SeriesLineChart(
        series: [
          line(
            "current", t("analytics.series.current"), .current, model.currentPoints,
            model.current),
          line(
            "previous", t("analytics.series.previous"), .previous, model.previousPoints,
            model.previous),
        ],
        xLabels: AnalyticsText.spanTicks(
          model.current.dayCount >= longest
            ? model.current
            : DayRange(model.current.start, model.current.start.adding(days: longest - 1)),
          environment))
      HStack(spacing: 16) {
        change("analytics.change.expenses", model.expenses, money)
        change("analytics.change.income", model.income, money)
      }
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
  }

  private func line(
    _ id: String, _ label: String, _ style: ChartSeriesStyle, _ points: [Int64], _ span: DayRange
  ) -> ChartLineSeries {
    let days = span.days
    return ChartLineSeries(
      id: id, label: label, style: style,
      points: points.enumerated().map { index, value in
        ChartLinePoint(
          x: index + 1,
          value: value,
          spokenLabel: index < days.count ? environment.dates.longDay(days[index]) : "",
          valueText: environment.money.rubles(value))
      },
      endText: points.last.map { environment.money.rubles($0) })
  }

  private func change(_ key: String, _ change: Change, _ money: MoneyFormatter) -> some View {
    let text = money.change(change)
    let words = AnalyticsText.changeWords(change, period: model.period, environment)
    return HStack(spacing: 4) {
      Image(systemName: Palette.changeSymbol(text.direction))
        .accessibilityHidden(true)
      Text(verbatim: AnalyticsText.format(key, environment, words))
    }
    .accessibilityElement(children: .combine)
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

// MARK: - Good vs Bad

private struct QualitySection: View {
  @Dependency(\.environment) private var environment
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void
  let isWide: Bool

  var body: some View {
    let names = state.value?.names ?? AnalyticsNames()
    VStack(alignment: .leading, spacing: 16) {
      AnalyticsCard(
        block: AnalyticsBlock.qualityShares.rawValue, title: t("analytics.block.qualityShares"),
        subtitle: t("analytics.basis.byDate"), state: state.block { $0.quality?.shares },
        retry: retry
      ) { columns in
        let styles = Quality.allCases.map { AnalyticsText.qualityStyle($0, environment) }
        let spansYears = Set(columns.map(\.month.year)).count > 1
        StackedShareChart(
          columns: columns.map { column in
            ChartStack(
              id: column.month.iso,
              axisLabel: environment.dates.shortMonth(column.month, withYear: spansYears),
              spokenLabel: environment.dates.monthTitle(column.month),
              segments: column.segments.map { segment in
                let percent = environment.money.percent(
                  basisPoints: segment.basisPoints, fractionDigits: 0)
                return ChartSegment(
                  id: segment.quality.rawValue,
                  style: AnalyticsText.qualityStyle(segment.quality, environment),
                  start: segment.start, end: segment.end, text: percent,
                  spokenValue: "\(environment.money.rubles(segment.value)), \(percent)")
              })
          },
          styles: styles)
      }

      if case .ready(let columns)? = state.value?.quality?.shares {
        QualityTiles(totals: QualityTotals.make(columns: columns))
      }

      AnalyticsPair(isWide: isWide) {
        AnalyticsCard(
          block: AnalyticsBlock.badByCategory.rawValue,
          title: t("analytics.block.badByCategory"), subtitle: t("analytics.basis.byDate"),
          state: state.block { $0.quality?.badByCategory }, retry: retry
        ) {
          QualityTag(quality: .bad, title: environment.language(Palette.qualityKey(.bad)))
        } content: { values in
          RankedBarChart(
            bars: AnalyticsText.bars(values, names: names, environment), tint: .orange)
        }
      } second: {
        VStack(alignment: .leading, spacing: 16) {
          AnalyticsCard(
            block: AnalyticsBlock.streaks.rawValue, title: t("analytics.block.streaks"),
            subtitle: t("analytics.basis.streaks"), state: state.block { $0.quality?.streaks },
            retry: retry
          ) { streaks in
            StreaksView(streaks: streaks)
          }
          AnalyticsCard(
            block: AnalyticsBlock.goals.rawValue, title: t("analytics.block.goals"),
            subtitle: t("analytics.basis.byDate"), state: state.block { $0.quality?.goals },
            retry: retry
          ) { split in
            GoalsSplitView(split: split)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// «Текущая — 12 дней», «лучшая — 40 дней»: two numbers, not a chart.
private struct StreaksView: View {
  @Dependency(\.environment) private var environment
  let streaks: Streaks

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 24) {
      figure("analytics.streak.current", streaks.current)
      figure("analytics.streak.best", streaks.best)
    }
  }

  private func figure(_ key: String, _ days: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: environment.money.count(Int64(days)))
        .appFont(.title2.monospacedDigit())
      Text(verbatim: AnalyticsText.format(key, environment, count: days))
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Goals and the rest of the spending as one bar of 100 %: goals on the left, each segment
/// named on the bar, the figures in words under it.
private struct GoalsSplitView: View {
  @Dependency(\.environment) private var environment
  let split: GoalsSplit

  var body: some View {
    let goals = style("goals", "analytics.segment.goals", "target", .accent)
    let rest = style("rest", "analytics.segment.rest", "circle.grid.2x2", .secondary)
    let goalsShare = Int64(max(0, split.goalsShare ?? 0))
    let restShare = Int64(max(0, split.restShare ?? 0))
    let segments = [
      ChartSegment(
        id: goals.id, style: goals, start: 0, end: goalsShare,
        text: "\(goals.label) · \(percent(split.goalsShare))",
        spokenValue: words(split.goals, split.goalsShare)),
      ChartSegment(
        id: rest.id, style: rest, start: goalsShare, end: goalsShare + restShare,
        text: "\(rest.label) · \(percent(split.restShare))",
        spokenValue: words(split.rest, split.restShare)),
    ].filter { $0.end > $0.start }
    VStack(alignment: .leading, spacing: 6) {
      StackedRowChart(
        rows: [
          ChartStack(
            id: "split", axisLabel: "",
            spokenLabel: AnalyticsText.t(
              "analytics.block.goals", environment), segments: segments)
        ],
        styles: [goals, rest], scale: .share)
      HStack(spacing: 16) {
        Text(verbatim: "\(goals.label): \(words(split.goals, split.goalsShare))")
        Text(verbatim: "\(rest.label): \(words(split.rest, split.restShare))")
      }
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
  }

  private func style(
    _ id: String, _ key: String, _ symbol: String, _ tint: ChartTint
  )
    -> SegmentStyle
  {
    SegmentStyle(
      id: id, label: AnalyticsText.t(key, environment), systemImage: symbol, tint: tint)
  }

  private func percent(_ share: Int?) -> String {
    share.map { environment.money.percent(basisPoints: $0, fractionDigits: 0) } ?? "—"
  }

  private func words(_ value: Int64, _ share: Int?) -> String {
    AnalyticsText.amountAndShare(value, share: share, environment)
  }
}

// MARK: - Paid for others

private struct OthersSection: View {
  @Dependency(\.environment) private var environment
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void
  let isWide: Bool

  var body: some View {
    let names = state.value?.names ?? AnalyticsNames()
    VStack(alignment: .leading, spacing: 16) {
      AnalyticsPair(isWide: isWide) {
        AnalyticsCard(
          block: AnalyticsBlock.othersTotals.rawValue, title: t("analytics.block.othersTotals"),
          subtitle: t("analytics.basis.byPurchase"), state: state.block { $0.others?.totals },
          retry: retry
        ) { figures in
          OthersFiguresView(figures: figures)
        }
      } second: {
        AnalyticsCard(
          block: AnalyticsBlock.othersSubscriptions.rawValue,
          title: t("analytics.block.othersSubscriptions"),
          subtitle: t("analytics.basis.byPurchase"),
          state: state.block { $0.others?.bySubscription }, retry: retry
        ) { subscriptions in
          StackedRowChart(
            rows: subscriptions.map { item in
              let name = AnalyticsText.name(ofPayment: item.paymentId, names, environment)
              return ChartStack(
                id: item.paymentId.uuidString, axisLabel: name, spokenLabel: name,
                segments: item.segments.map { segment in
                  let text = environment.money.rubles(segment.value)
                  return ChartSegment(
                    id: segment.kind.rawValue,
                    style: AnalyticsText.othersStyle(segment.kind, environment),
                    start: segment.start, end: segment.end, text: text, spokenValue: text)
                })
            },
            styles: OthersSegment.allCases.map { AnalyticsText.othersStyle($0, environment) })
        }
      }

      AnalyticsCard(
        block: AnalyticsBlock.othersByPerson.rawValue, title: t("analytics.block.othersByPerson"),
        subtitle: t("analytics.basis.byPurchase"), state: state.block { $0.others?.byPerson },
        retry: retry
      ) { people in
        StackedRowChart(
          rows: people.map { person in
            let name =
              person.personId.map { AnalyticsText.name(of: .person($0), names, environment) }
              ?? t("analytics.none.person")
            return ChartStack(
              id: person.personId?.uuidString ?? "none", axisLabel: name, spokenLabel: name,
              segments: person.segments.map { segment in
                let text = environment.money.rubles(segment.value)
                return ChartSegment(
                  id: segment.kind.rawValue,
                  style: AnalyticsText.othersStyle(segment.kind, environment),
                  start: segment.start, end: segment.end, text: text, spokenValue: text)
              })
          },
          styles: OthersSegment.allCases.map { AnalyticsText.othersStyle($0, environment) })
      }
    }
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// Paid, returned, written off, waiting; the shortfall and the surplus — each with the
/// symbol of its status and its words, in a plain grid.
private struct OthersFiguresView: View {
  @Dependency(\.environment) private var environment
  let figures: OthersFigures

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
      row("person.2", "analytics.others.paid", figures.paid)
      row(Palette.reimbursementSymbol(.returned), "analytics.others.returned", figures.returned)
      row(
        Palette.reimbursementSymbol(.writtenOff), "analytics.others.writtenOff",
        figures.writtenOff)
      row(Palette.reimbursementSymbol(.expected), "analytics.others.waiting", figures.waiting)
      Divider()
      row("minus.circle", "analytics.others.shortfall", figures.shortfall)
      row("plus.circle", "analytics.others.surplus", figures.surplus)
    }
    .appFont(.callout)
  }

  private func row(_ symbol: String, _ key: String, _ value: Int64) -> some View {
    GridRow {
      Label {
        Text(verbatim: AnalyticsText.t(key, environment))
      } icon: {
        Image(systemName: symbol)
          .foregroundStyle(.secondary)
      }
      Text(verbatim: environment.money.rubles(value))
        .monospacedDigit()
        .gridColumnAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - For whom

private struct ForWhomSection: View {
  @Dependency(\.environment) private var environment
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void
  let isWide: Bool

  var body: some View {
    let names = state.value?.names ?? AnalyticsNames()
    VStack(alignment: .leading, spacing: 16) {
      AnalyticsPair(isWide: isWide) {
        AnalyticsCard(
          block: AnalyticsBlock.forWhomValues.rawValue, title: t("analytics.block.forWhomValues"),
          subtitle: t("analytics.basis.shareOfSpending"),
          state: state.block { $0.forWhom?.values }, retry: retry
        ) { values in
          RankedBarChart(bars: AnalyticsText.bars(values, names: names, environment))
        }
      } second: {
        AnalyticsCard(
          block: AnalyticsBlock.forWhomPeople.rawValue, title: t("analytics.block.forWhomPeople"),
          subtitle: t("analytics.basis.shareOfSpending"),
          state: state.block { $0.forWhom?.people }, retry: retry
        ) { values in
          RankedBarChart(bars: AnalyticsText.bars(values, names: names, environment))
        }
      }

      AnalyticsCard(
        block: AnalyticsBlock.forWhomDynamics.rawValue,
        title: t("analytics.block.forWhomDynamics"), subtitle: t("analytics.basis.byDate"),
        state: state.block { $0.forWhom?.dynamics }, retry: retry
      ) { model in
        let spansYears = Set(model.months.map(\.year)).count > 1
        SeriesLineChart(
          series: AnalyticsText.dynamicsLines(model, environment),
          xLabels: Dictionary(
            uniqueKeysWithValues: ChartAxis.thinned(Array(model.months.indices), limit: 12).map {
              ($0, environment.dates.shortMonth(model.months[$0], withYear: spansYears))
            }))
      }
    }
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

// MARK: - Places

private struct PlacesSection: View {
  @Dependency(\.environment) private var environment
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void
  let isWide: Bool

  var body: some View {
    let names = state.value?.names ?? AnalyticsNames()
    VStack(alignment: .leading, spacing: 16) {
      AnalyticsPair(isWide: isWide) {
        AnalyticsCard(
          block: AnalyticsBlock.placesByAmount.rawValue, title: t("analytics.block.placesByAmount"),
          subtitle: t("analytics.basis.mySpending"),
          state: state.block { $0.places?.byAmount }, retry: retry
        ) { values in
          RankedBarChart(bars: AnalyticsText.bars(values, names: names, environment))
        }
      } second: {
        AnalyticsCard(
          block: AnalyticsBlock.placesByPurchases.rawValue,
          title: t("analytics.block.placesByPurchases"), subtitle: t("analytics.basis.byDate"),
          state: state.block { $0.places?.byPurchases }, retry: retry
        ) { values in
          RankedBarChart(
            bars: AnalyticsText.bars(values, names: names, counts: true, environment),
            scale: .count, tint: .blue)
        }
      }

      AnalyticsCard(
        block: AnalyticsBlock.placesTable.rawValue, title: t("analytics.block.placesTable"),
        subtitle: t("analytics.basis.averageReceipt"), state: state.block { $0.places?.table },
        retry: retry
      ) { table in
        PlacesTableView(table: table, names: names)
      }

      AnalyticsCard(
        block: AnalyticsBlock.newPlaces.rawValue, title: t("analytics.block.newPlaces"),
        subtitle: t("analytics.basis.newPlaces"), state: state.block { $0.places?.newPlaces },
        retry: retry
      ) { rows in
        VStack(alignment: .leading, spacing: 4) {
          ForEach(rows, id: \.placeId) { row in
            HStack(spacing: 8) {
              Image(systemName: "sparkle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
              Text(verbatim: AnalyticsText.name(of: .place(row.placeId), names, environment))
              Spacer(minLength: 8)
              Text(verbatim: environment.dates.longDay(row.firstDay))
                .foregroundStyle(.secondary)
            }
            .appFont(.callout)
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// Places of the period in a plain grid: my spending, purchases, the average receipt and
/// the day of the first visit; the amounts rounded, in digits of one width, to the right.
private struct PlacesTableView: View {
  @Dependency(\.environment) private var environment
  let table: PlacesTable
  let names: AnalyticsNames

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
        GridRow {
          header("analytics.column.place")
          header("analytics.column.spent").gridColumnAlignment(.trailing)
          header("analytics.column.purchases").gridColumnAlignment(.trailing)
          header("analytics.column.averageReceipt").gridColumnAlignment(.trailing)
          header("analytics.column.firstTime")
        }
        Divider()
        ForEach(table.rows, id: \.placeId) { row in
          GridRow {
            HStack(spacing: 4) {
              Text(verbatim: AnalyticsText.name(of: .place(row.placeId), names, environment))
                .lineLimit(1)
              if row.isNew {
                Text(verbatim: AnalyticsText.t("analytics.places.new", environment))
                  .appFont(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Text(verbatim: environment.money.rubles(row.spent))
              .monospacedDigit()
            Text(verbatim: environment.money.count(Int64(row.purchases)))
              .monospacedDigit()
            Text(verbatim: row.averageReceipt.map { environment.money.rubles($0) } ?? "—")
              .monospacedDigit()
            Text(verbatim: environment.dates.longDay(row.firstDay))
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
        }
      }
      .appFont(.callout)
      if table.hidden > 0 {
        Text(
          verbatim: AnalyticsText.format(
            "analytics.places.more", environment, count: table.hidden)
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func header(_ key: String) -> some View {
    Text(verbatim: AnalyticsText.t(key, environment))
      .appFont(.caption)
      .foregroundStyle(.secondary)
  }
}

// MARK: - Events

private struct EventsSection: View {
  @Dependency(\.environment) private var environment
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void

  var body: some View {
    let names = state.value?.names ?? AnalyticsNames()
    VStack(alignment: .leading, spacing: 16) {
      AnalyticsCard(
        block: AnalyticsBlock.events.rawValue, title: t("analytics.block.events"),
        subtitle: t("analytics.basis.wholeEvent"), state: state.block { $0.events?.events },
        retry: retry
      ) { items in
        EventsTableView(items: items, names: names)
      }
      if let items = state.value?.events?.events.content {
        ForEach(items, id: \.eventId) { item in
          AnalyticsCard(
            block: AnalyticsBlock.event(item.eventId),
            title: AnalyticsText.name(of: .event(item.eventId), names, environment),
            subtitle: environment.dates.span(DayRange(item.start, item.end)),
            state: state.block { _ in
              item.hasChart ? .ready(item) : .notEnoughData(.noEventSpending)
            },
            retry: retry
          ) { item in
            EventChartsView(item: item, names: names)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// Every event of the period in a plain grid: its days, what it cost, its budget and what
/// is left of it, and the same event a year before.
private struct EventsTableView: View {
  @Dependency(\.environment) private var environment
  let items: [EventItem]
  let names: AnalyticsNames

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
      GridRow {
        header("analytics.column.event")
        header("analytics.column.dates")
        header("analytics.column.spent").gridColumnAlignment(.trailing)
        header("analytics.column.budget").gridColumnAlignment(.trailing)
        header("analytics.column.left").gridColumnAlignment(.trailing)
        header("analytics.column.lastYear").gridColumnAlignment(.trailing)
      }
      Divider()
      ForEach(items, id: \.eventId) { item in
        GridRow {
          Text(verbatim: AnalyticsText.name(of: .event(item.eventId), names, environment))
            .lineLimit(1)
          Text(verbatim: environment.dates.span(DayRange(item.start, item.end)))
            .foregroundStyle(.secondary)
          amount(item.total)
          amount(item.budget)
          amount(item.left, signed: true)
          amount(item.lastYearTotal)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .appFont(.callout)
  }

  private func amount(_ value: Int64?, signed: Bool = false) -> some View {
    let text = value.map {
      signed ? environment.money.signedRubles($0) : environment.money.rubles($0)
    }
    return Text(verbatim: text ?? "—")
      .monospacedDigit()
  }

  private func header(_ key: String) -> some View {
    Text(verbatim: AnalyticsText.t(key, environment))
      .appFont(.caption)
      .foregroundStyle(.secondary)
  }
}

/// One event: spent against its budget and against last year, then its categories.
private struct EventChartsView: View {
  @Dependency(\.environment) private var environment
  let item: EventItem
  let names: AnalyticsNames

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      BudgetChart(bars: bars, budget: budget)
      if !item.byCategory.isEmpty {
        RankedBarChart(bars: AnalyticsText.bars(item.byCategory, names: names, environment))
      }
    }
  }

  private var bars: [BudgetChart.Bar] {
    var bars = [
      BudgetChart.Bar(
        id: "spent", label: AnalyticsText.t("analytics.events.spent", environment),
        value: item.total, text: environment.money.rubles(item.total), isMain: true)
    ]
    if let lastYear = item.lastYearTotal {
      bars.append(
        BudgetChart.Bar(
          id: "lastYear", label: item.lastYear.map(String.init) ?? "—", value: lastYear,
          text: environment.money.rubles(lastYear), isMain: false))
    }
    return bars
  }

  private var budget: ChartRule? {
    item.budget.map { value in
      ChartRule(
        value: value,
        label: AnalyticsText.format(
          "analytics.events.budget", environment, environment.money.rubles(value)))
    }
  }
}

// MARK: - Payment methods

private struct PaymentMethodsSection: View {
  @Dependency(\.environment) private var environment
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void

  var body: some View {
    let names = state.value?.names ?? AnalyticsNames()
    VStack(alignment: .leading, spacing: 16) {
      AnalyticsCard(
        block: AnalyticsBlock.methodSpending.rawValue, title: t("analytics.block.methodSpending"),
        subtitle: t("analytics.basis.mySpending"),
        state: state.block { $0.paymentMethods?.spending }, retry: retry
      ) { values in
        RankedBarChart(bars: AnalyticsText.bars(values, names: names, environment))
      }
      AnalyticsCard(
        block: AnalyticsBlock.methodTable.rawValue, title: t("analytics.block.methodTable"),
        subtitle: t("analytics.basis.turnover"),
        state: state.block { $0.paymentMethods?.table }, retry: retry
      ) { rows in
        MethodsTableView(rows: rows, names: names)
      }
      AnalyticsCard(
        block: AnalyticsBlock.cashbackMonths.rawValue, title: t("analytics.block.cashbackMonths"),
        subtitle: t("analytics.basis.cashbackMonths"),
        state: state.block { $0.paymentMethods?.cashbackMonths }, retry: retry
      ) { model in
        CashbackMonthsView(model: model, names: names)
      }
    }
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// «Кэшбэк по месяцам»: for all accounts, one account or one card, each month's expected
/// cashback — by the month of the purchases — beside what came for it and the difference,
/// received − expected, with its sign and no colour of good or bad.
private struct CashbackMonthsView: View {
  @Dependency(\.environment) private var environment
  let model: CashbackMonthsModel
  let names: AnalyticsNames
  @State private var choice: CashbackMonthsModel.Choice = .all

  var body: some View {
    let shown = model.choices.contains(choice) ? choice : .all
    VStack(alignment: .leading, spacing: 8) {
      Picker(selection: $choice) {
        ForEach(model.choices, id: \.self) { choice in
          Text(verbatim: AnalyticsText.cashbackChoice(choice, model: model, names, environment))
            .tag(choice)
        }
      } label: {
        Text(verbatim: AnalyticsText.t("analytics.cashback.holder", environment))
      }
      .fixedSize()
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
        GridRow {
          header("analytics.column.month")
          header("analytics.column.cashbackExpected").gridColumnAlignment(.trailing)
          header("analytics.column.cashback").gridColumnAlignment(.trailing)
          header("analytics.column.cashbackDifference").gridColumnAlignment(.trailing)
        }
        Divider()
        ForEach(model.months[shown] ?? [], id: \.month) { row in
          // VoiceOver hears the month once, with every figure after its header: a modifier on
          // the row would reach each cell on its own and leave the figures unnamed.
          let line = AnalyticsText.cashbackMonthLine(row, environment)
          GridRow {
            Text(verbatim: line.first)
              .accessibilityLabel(Text(verbatim: line.spoken))
            ForEach(Array(line.figures.enumerated()), id: \.offset) { _, figure in
              Text(verbatim: figure)
                .monospacedDigit()
                .accessibilityHidden(true)
            }
          }
        }
      }
      .appFont(.callout)
    }
  }

  private func header(_ key: String) -> some View {
    Text(verbatim: AnalyticsText.t(key, environment))
      .appFont(.caption)
      .foregroundStyle(.secondary)
  }
}

/// Every payment method: my spending, the turnover cashback is paid on, the cashback its cards'
/// rules expect, the cashback received and its actual share of the turnover — «—» when there
/// was no turnover. An account with more than one card has a line per card under it, the
/// symbol of a card telling them from the accounts.
private struct MethodsTableView: View {
  @Dependency(\.environment) private var environment
  let rows: [MethodRow]
  let names: AnalyticsNames

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
      GridRow {
        header("analytics.column.method")
        header("analytics.column.mySpending").gridColumnAlignment(.trailing)
        header("analytics.column.turnover").gridColumnAlignment(.trailing)
        header("analytics.column.cashbackExpected").gridColumnAlignment(.trailing)
        header("analytics.column.cashback").gridColumnAlignment(.trailing)
        header("analytics.column.cashbackShare").gridColumnAlignment(.trailing)
      }
      Divider()
      ForEach(rows, id: \.key) { row in
        // VoiceOver hears each line once, from its name, with every figure after its header: a
        // modifier on the row would reach each cell on its own and leave the figures unnamed.
        let line = AnalyticsText.methodLine(row, names, environment)
        GridRow {
          Text(verbatim: line.first)
            .lineLimit(1)
            .accessibilityLabel(Text(verbatim: line.spoken))
          figures(line)
        }
        ForEach(row.cards, id: \.cardId) { card in
          let cardLine = AnalyticsText.cardMethodLine(card, names, environment)
          GridRow {
            Label {
              Text(verbatim: cardLine.first)
                .lineLimit(1)
            } icon: {
              Image(systemName: "creditcard")
            }
            .padding(.leading, 16)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: cardLine.spoken))
            figures(cardLine)
            Text(verbatim: "")
              .accessibilityHidden(true)
          }
        }
      }
    }
    .appFont(.callout)
  }

  /// The figures of a line, silent: its first cell says them.
  private func figures(_ line: AnalyticsText.GridLine) -> some View {
    ForEach(Array(line.figures.enumerated()), id: \.offset) { _, figure in
      Text(verbatim: figure)
        .monospacedDigit()
        .accessibilityHidden(true)
    }
  }

  private func header(_ key: String) -> some View {
    Text(verbatim: AnalyticsText.t(key, environment))
      .appFont(.caption)
      .foregroundStyle(.secondary)
  }
}

// MARK: - Forecast

private struct ForecastSection: View {
  @Dependency(\.environment) private var environment
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      AnalyticsCard(
        block: AnalyticsBlock.forecast.rawValue, title: t("analytics.block.forecast"),
        subtitle: t("analytics.basis.forecast"), state: state.block { $0.forecast?.chart },
        retry: retry
      ) { plot in
        ForecastView(plot: plot, month: state.value?.forecast?.month)
      }
      AnalyticsCard(
        block: AnalyticsBlock.accountBalances.rawValue,
        title: t("analytics.block.accountBalances"), subtitle: t("analytics.basis.accountBalances"),
        state: state.block { $0.forecast?.accounts }, retry: retry
      ) { forecast in
        AccountBalancesForecastView(forecast: forecast)
      }
    }
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// The balance of every account at the end of the month in a plain grid: the account (and its
/// currency when it has several), the balance now, about how much at the end of the month and
/// the interval, each in the account's own currency. The accounts in the summary end with
/// their total in rubles; each group left out follows under its own name with its own total;
/// then the currencies never counted, which have no forecast.
struct AccountBalancesForecastView: View {
  @Dependency(\.environment) private var environment
  let forecast: AccountForecast

  var body: some View {
    let rows = AccountBalancesForecastText.rows(forecast, environment)
    VStack(alignment: .leading, spacing: 8) {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
        GridRow {
          header("analytics.accounts.account")
          header("analytics.accounts.now").gridColumnAlignment(.trailing)
          Text(
            verbatim: AnalyticsText.format(
              "analytics.accounts.end", environment,
              environment.dates.dayAndMonth(forecast.through))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .gridColumnAlignment(.trailing)
          header("analytics.accounts.range").gridColumnAlignment(.trailing)
        }
        Divider()
        ForEach(rows, id: \.id) { row in
          switch row.kind {
          case .line(let line):
            // VoiceOver hears the account once, as text: the name carries the whole line and
            // the other cells are silent. A modifier on the row would reach every cell and
            // repeat the line once per column.
            GridRow {
              Text(verbatim: line.name)
                .lineLimit(1)
                .accessibilityLabel(Text(verbatim: line.spoken))
              Text(verbatim: line.now)
                .monospacedDigit()
                .accessibilityHidden(true)
              HStack(spacing: 4) {
                if line.negative {
                  Image(systemName: "exclamationmark.triangle")
                }
                Text(verbatim: line.end)
                  .monospacedDigit()
              }
              .accessibilityHidden(true)
              Text(verbatim: line.range)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
          case .title(let text):
            Text(verbatim: text)
              .appFont(.callout.weight(.semibold))
              .padding(.top, 6)
              .gridCellColumns(4)
          case .total(let text):
            Text(verbatim: text)
              .monospacedDigit()
              .gridCellColumns(4)
          }
        }
      }
      .appFont(.callout)
      ForEach(AccountBalancesForecastText.notes(forecast, environment), id: \.text) { note in
        Label {
          Text(verbatim: note.text)
        } icon: {
          Image(systemName: note.symbol)
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func header(_ key: String) -> some View {
    Text(verbatim: AnalyticsText.t(key, environment))
      .appFont(.caption)
      .foregroundStyle(.secondary)
  }
}

/// The words of the balances grid, built without a view so they can be checked in both
/// languages.
@MainActor
enum AccountBalancesForecastText {
  struct Line: Hashable, Sendable {
    var name: String
    var now: String
    var end: String
    var range: String
    var negative: Bool
    var spoken: String
  }

  struct Row: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
      case line(Line)
      case title(String)
      case total(String)
    }

    var id: String
    var kind: Kind
  }

  struct Note: Hashable, Sendable {
    var symbol: String
    var text: String
  }

  /// The accounts in the summary, their total, then each group left out with its own.
  static func rows(_ forecast: AccountForecast, _ environment: AppEnvironment) -> [Row] {
    let money = environment.money
    var rows: [Row] = []
    func lines(of section: AccountForecast.Section) -> [Row] {
      section.lines.filter { $0.status != .notCounted }.map { line in
        Row(
          id: "line.\(line.key.accountId.uuidString).\(line.key.currency.code)",
          kind: .line(self.line(line, environment)))
      }
    }
    let inSummary = forecast.sections.filter(\.inSummary)
    rows += inSummary.flatMap(lines(of:))
    if let total = forecast.inSummaryTotalRub {
      rows.append(
        Row(
          id: "total",
          kind: .total(
            AnalyticsText.format(
              "analytics.accounts.total", environment, money.rounded(total.middle)))))
    }
    for section in forecast.sections where !section.inSummary {
      let own = lines(of: section)
      guard !own.isEmpty else { continue }
      let group = section.group?.name ?? ""
      rows.append(
        Row(
          id: "group.\(section.group?.id.uuidString ?? "")",
          kind: .title(AnalyticsText.format("analytics.accounts.excluded", environment, group))))
      rows += own
      if let total = section.totalRub {
        rows.append(
          Row(
            id: "groupTotal.\(section.group?.id.uuidString ?? "")",
            kind: .total(
              AnalyticsText.format(
                "analytics.accounts.groupTotal", environment, money.rounded(total.middle)))))
      }
    }
    return rows
  }

  static func line(_ line: AccountForecast.Line, _ environment: AppEnvironment) -> Line {
    let money = environment.money
    let currency = line.key.currency
    let account = line.flows.account
    let name =
      account.currencies.count > 1 || !line.flows.isHeld
      ? "\(account.name) · \(currency.code)" : account.name
    let now = line.flows.now.map { money.rounded($0, currency: currency) } ?? "—"
    guard let balance = line.balance else {
      let noRate = AnalyticsText.t("analytics.accounts.noRate", environment)
      return Line(
        name: name, now: now, end: noRate, range: "—", negative: false,
        spoken: "\(name), \(now), \(noRate)")
    }
    let end = "≈\u{00A0}\(money.rounded(balance.middle, currency: currency))"
    let range =
      "\(money.rounded(balance.low, currency: currency)) – "
      + money.rounded(balance.high, currency: currency)
    var spoken = "\(name), \(now), \(end), \(range)"
    if line.mayGoNegative {
      spoken += ", " + AnalyticsText.t("analytics.accounts.negative", environment)
    }
    return Line(
      name: name, now: now, end: end, range: range, negative: line.mayGoNegative,
      spoken: spoken)
  }

  /// What the grid cannot show: the currencies never counted, the ones that could not be
  /// converted, the accounts that may go below zero, a short history.
  static func notes(_ forecast: AccountForecast, _ environment: AppEnvironment) -> [Note] {
    var notes: [Note] = []
    let all = forecast.sections.flatMap(\.lines)
    let negative = all.filter(\.mayGoNegative).map { self.line($0, environment).name }
    if !negative.isEmpty {
      notes.append(
        Note(
          symbol: "exclamationmark.triangle",
          text: AnalyticsText.format(
            "analytics.accounts.negativeList", environment, negative.joined(separator: ", "))))
    }
    let unanchored = forecast.unanchored.compactMap { key -> String? in
      guard let account = all.first(where: { $0.key == key })?.flows.account else { return nil }
      return "\(account.name) (\(key.currency.code))"
    }
    if !unanchored.isEmpty {
      notes.append(
        Note(
          symbol: "hourglass",
          text: AnalyticsText.format(
            "analytics.accounts.unanchored", environment, unanchored.joined(separator: ", "))))
    }
    let missing = Set(forecast.sections.flatMap(\.withoutRate)).sorted { $0.code < $1.code }
    if !missing.isEmpty {
      notes.append(
        Note(
          symbol: "exclamationmark.circle",
          text: AnalyticsText.format(
            "analytics.accounts.withoutRate", environment,
            missing.map(\.code).joined(separator: ", "))))
    }
    if forecast.lowData {
      notes.append(
        Note(symbol: "hourglass", text: AnalyticsText.t("analytics.forecast.lowData", environment)))
    }
    return notes
  }
}

private struct ForecastView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.windowWidth) private var windowWidth
  let plot: ForecastPlot
  let month: MonthKey?

  var body: some View {
    let money = environment.money
    VStack(alignment: .leading, spacing: 8) {
      ForecastChart(
        actual: plot.actual.map { point($0) },
        projection: plot.projection.map { point($0) },
        band: plot.band.map { band in
          ForecastChart.BandPoint(
            day: band.day, low: band.low, high: band.high,
            spokenLabel: "\(t("analytics.forecast.interval")), \(dayName(band.day))",
            valueText: range(band.low, band.high))
        },
        dayCount: plot.dayCount,
        xLabels: Dictionary(
          uniqueKeysWithValues: AnalyticsText.dayTicks(count: plot.dayCount).map {
            ($0, String($0))
          }),
        middleText: "≈ \(money.rubles(plot.p50))",
        // On a phone the range does not fit beside the end of the line: it goes under the chart.
        rangeText: plot.p10 == plot.p90 || narrow ? nil : range(plot.p10, plot.p90),
        legend: [
          ChartLegend.series("actual", t("analytics.forecast.actual"), .current),
          ChartLegend.series("projection", t("analytics.forecast.projection"), .projection),
          ChartLegend.Item(
            id: "interval", label: t("analytics.forecast.interval"),
            systemImage: "rectangle.fill", tint: .accent, dash: nil),
        ])
      if narrow, plot.p10 != plot.p90 {
        Text(verbatim: range(plot.p10, plot.p90))
          .appFont(.callout.monospacedDigit())
      }
      Text(
        verbatim: AnalyticsText.format(
          "analytics.forecast.summary", environment, money.rubles(plot.spent),
          money.rubles(plot.planned))
      )
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      if plot.lowData {
        Label {
          Text(verbatim: t("analytics.forecast.lowData"))
        } icon: {
          Image(systemName: "hourglass")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var narrow: Bool { windowWidth > 0 && windowWidth < 640 }

  private func point(_ value: DayValue) -> ChartLinePoint {
    ChartLinePoint(
      x: value.day, value: value.value, spokenLabel: dayName(value.day),
      valueText: environment.money.rubles(value.value))
  }

  private func dayName(_ day: Int) -> String {
    guard let month else { return String(day) }
    return environment.dates.longDay(DateOnly(year: month.year, month: month.month, day: day))
  }

  private func range(_ low: Int64, _ high: Int64) -> String {
    String(
      format: environment.language("overview.forecastRange", table: "Overview"),
      locale: environment.language.locale, environment.money.rubles(low),
      environment.money.rubles(high))
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

// MARK: - Anomalies

/// «Аномалии»: what the seven rules found in the period on screen, each with the two
/// numbers it is made of, and «Это нормально» to put one away.
private struct AnomaliesSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void
  /// Why the last «Это нормально» or «Вернуть» was not written: a key of the Analytics table.
  @State private var failure: String?

  var body: some View {
    let names = state.value?.names ?? AnalyticsNames()
    VStack(alignment: .leading, spacing: 16) {
      if let failure {
        Label {
          Text(verbatim: t(failure))
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
        }
        .appFont(.callout)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      }
      AnalyticsCard(
        block: AnalyticsBlock.anomalies.rawValue, title: t("analytics.block.anomalies"),
        subtitle: t("analytics.basis.anomalies"), state: state.block { $0.anomalies?.found },
        retry: retry
      ) { found in
        VStack(alignment: .leading, spacing: 12) {
          ForEach(found, id: \.id) { anomaly in
            AnomalyRow(anomaly: anomaly, names: names) { hide(anomaly) }
          }
        }
      }
      if let hidden = state.value?.anomalies?.hidden, !hidden.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(verbatim: t("analytics.anomaly.hidden"))
            .appFont(.headline)
            .accessibilityAddTraits(.isHeader)
          ForEach(hidden, id: \.id) { anomaly in
            AnomalyRow(anomaly: anomaly, names: names, isHidden: true) { show(anomaly) }
          }
        }
      }
    }
  }

  private var actions: AnomalyActions {
    AnomalyActions(repository: environment.anomalies) { [compute] in
      compute.retry(ComputeStep.data)
    }
  }

  /// «Это нормально». A write that failed is said above the list, until one goes through.
  private func hide(_ anomaly: Anomaly) {
    failure = actions.hide(anomaly, active: compute.states.anomalies.value?.activeKeys)
  }

  private func show(_ anomaly: Anomaly) {
    failure = actions.show(anomaly)
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

private struct AnomalyRow: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  let anomaly: Anomaly
  let names: AnalyticsNames
  var isHidden = false
  let act: () -> Void

  /// The rule as a capsule with a warning triangle: the kind is said in words and a shape, the
  /// warm tint only confirms it.
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label {
          Text(verbatim: AnalyticsText.t("analytics.anomaly.\(anomaly.rule.rawValue)", environment))
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
        }
        .appFont(.caption.weight(.semibold))
        .foregroundStyle(surfaces.warning)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(surfaces.warning.opacity(0.14), in: .capsule)
        Text(verbatim: environment.dates.dayAndMonth(anomaly.day))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      Text(verbatim: AnalyticsText.anomalyDetail(anomaly, names: names, environment))
        .appFont(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Button(
        AnalyticsText.t(
          isHidden ? "analytics.anomaly.restore" : "analytics.anomaly.normal", environment),
        action: act
      )
      .buttonStyle(.bordered)
      .tint(surfaces.secondary)
      .foregroundStyle(surfaces.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(surfaces.background, in: .rect(cornerRadius: 10))
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Model quality

/// «Качество модели»: two tables of measured numbers — what the category model scored
/// on this history, and what the month forecast scored against the days that have already
/// happened. Both are measurements of this book, never claims about the app.
private struct ModelQualitySection: View {
  @Dependency(\.environment) private var environment
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      AnalyticsCard(
        block: AnalyticsBlock.modelCategories.rawValue,
        title: t("analytics.block.modelCategories"), subtitle: t("analytics.basis.modelQuality"),
        state: state.block { $0.modelQuality?.categories }, retry: retry
      ) { categories in
        MeasuredTable(rows: MeasuredTable.rows(of: categories, environment))
      }
      AnalyticsCard(
        block: AnalyticsBlock.modelForecast.rawValue,
        title: t("analytics.block.modelForecast"), subtitle: t("analytics.basis.modelQuality"),
        state: state.block { $0.modelQuality?.forecast }, retry: retry
      ) { backtest in
        ForecastQualityTable(backtest: backtest)
      }
    }
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// One line per way of forecasting, the one in use marked.
private struct ForecastQualityTable: View {
  @Dependency(\.environment) private var environment
  let backtest: ForecastBacktest

  var body: some View {
    let money = environment.money
    VStack(alignment: .leading, spacing: 10) {
      Text(
        verbatim: "\(t("analytics.forecast.origins")): "
          + money.count(Int64(backtest.metrics(of: backtest.chosen)?.origins ?? 0))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
      ForEach(backtest.lines, id: \.method) { line in
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(verbatim: t("analytics.forecast.method.\(line.method.rawValue)"))
              .appFont(.subheadline.weight(line.method == backtest.chosen ? .semibold : .regular))
            if line.method == backtest.chosen {
              Text(verbatim: t("analytics.forecast.inUse"))
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Text(
            verbatim: "\(t("analytics.forecast.mae")) \(money.rounded(line.metrics.mae))  ·  "
              + "\(t("analytics.forecast.pinball")) "
              + "\(money.rounded(line.metrics.pinball10)) / "
              + "\(money.rounded(line.metrics.pinball50)) / "
              + "\(money.rounded(line.metrics.pinball90))  ·  "
              + "\(t("analytics.forecast.coverage")) "
              + "\(environment.money.percent(basisPoints: line.metrics.coverageBp))"
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// A plain two-column list of measured numbers: the name on the left, the figure on the
/// right in monospaced digits, so a column of them can be read down.
struct MeasuredTable: View {
  struct Row: Hashable {
    var title: String
    var value: String
  }

  /// The model's figures, in the order they are worth reading: how often it is right, how
  /// often it dares, and the two baselines it has to beat to be worth having.
  static func rows(
    of categories: ModelQuality.Categories, _ environment: AppEnvironment
  ) -> [Row] {
    guard let metrics = categories.metrics else { return [] }
    let count = { (value: Int) in environment.money.count(Int64(value)) }
    func share(_ key: String, _ bp: Int) -> Row {
      Row(
        title: AnalyticsText.t(key, environment),
        value: environment.money.percent(basisPoints: bp))
    }
    return [
      Row(
        title: AnalyticsText.t("analytics.model.examples", environment),
        value: count(categories.examples)),
      Row(
        title: AnalyticsText.t("analytics.model.asked", environment), value: count(metrics.asked)),
      Row(
        title: AnalyticsText.t("analytics.model.classes", environment),
        value: "\(count(metrics.classes)) / \(count(metrics.classesReady))"),
      share("analytics.model.top1", metrics.top1Bp),
      share("analytics.model.top3", metrics.top3Bp),
      share("analytics.model.coverage", metrics.coverageBp),
      share("analytics.model.precision", metrics.precisionBp),
      share("analytics.model.macroF1", metrics.macroF1Bp),
      share("analytics.model.baselineFrequent", metrics.baselineMostFrequentBp),
      share("analytics.model.baselineText", metrics.baselineLastSameTextBp),
    ] + choiceRows(of: categories.choices, environment)
  }

  /// The owner's own choices against what the model offered, once there are any
  /// (`category_feedback`).
  private static func choiceRows(
    of choices: ModelQuality.Choices, _ environment: AppEnvironment
  ) -> [Row] {
    guard choices.made > 0 else { return [] }
    let count = { (value: Int) in environment.money.count(Int64(value)) }
    var rows = [
      Row(
        title: AnalyticsText.t("analytics.model.choices", environment),
        value: count(choices.made)),
      Row(
        title: AnalyticsText.t("analytics.model.overruled", environment),
        value: count(choices.overruled)),
    ]
    if let sure = choices.confidenceWhenOverruledBp {
      rows.append(
        Row(
          title: AnalyticsText.t("analytics.model.sureWhenOverruled", environment),
          value: environment.money.percent(basisPoints: sure)))
    }
    return rows
  }

  let rows: [Row]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(rows, id: \.self) { row in
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: row.title)
          Spacer(minLength: 12)
          Text(verbatim: row.value)
            .monospacedDigit()
        }
        .appFont(.callout)
        .accessibilityElement(children: .combine)
      }
    }
  }
}
