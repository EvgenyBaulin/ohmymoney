import AppCore
import SwiftUI

/// The four spending sections of Analytics that count on demand, off the main thread, through
/// `ComputeStore.analysis`: «Сравнение», «Дни и время», «Места и привычки», «Утечки и лимиты».
/// They follow the period of the toolbar where a period makes sense.
struct SpendingSectionsHost: View {
  let section: AnalyticsSection
  let period: AnalyticsPeriod

  var body: some View {
    switch section {
    case .comparison: ComparisonSection(period: period)
    case .days: DaysSection(period: period)
    case .habits: HabitsSection(period: period)
    case .leaks: LeaksSection(period: period)
    default: EmptyView()
    }
  }
}

// MARK: - Days and time

private struct DaysSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let period: AnalyticsPeriod
  @State private var withoutOneOff = false

  private struct WeekendRequest: Hashable, Sendable {
    var range: DayRange
    var withoutOneOff: Bool
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SpendingBlock(
        identifier: "spending.weekend", title: t("spending.weekend.title"),
        subtitle: t("spending.weekend.basis"),
        request: WeekendRequest(range: period.period.range, withoutOneOff: withoutOneOff),
        fetch: { snapshot, request async throws -> SpendingOutcome<WeekendPrice> in
          let price = try await compute.analysis.spending.weekendPrice(
            snapshot, range: request.range, excludingOneOff: request.withoutOneOff)
          return price.total.raw > 0
            ? .ready(price) : .empty(reason: t("spending.weekend.empty"))
        },
        accessory: {
          Toggle(isOn: $withoutOneOff) {
            Text(verbatim: t("spending.weekend.excludeOneOff"))
          }
          .toggleStyle(.switch)
          .controlSize(.small)
          .accessibilityIdentifier("spending.weekend.excludeOneOff")
        }
      ) { price in
        WeekendPriceView(price: price)
      }
      SpendingBlock(
        identifier: "spending.usualDay", title: t("spending.usual.title"),
        subtitle: t("spending.usual.basis"), request: 0,
        fetch: { snapshot, _ in .ready(try await compute.analysis.spending.usualDay(snapshot)) }
      ) { usual in
        UsualDayView(usual: usual)
      }
      SpendingBlock(
        identifier: "spending.heatmap", title: t("spending.heat.title"),
        subtitle: t("spending.heat.basis"), request: period.period.range,
        fetch: { snapshot, range async throws -> SpendingOutcome<HourHeatmap> in
          let map = try await compute.analysis.spending.heatmap(snapshot, range: range)
          return map.total.raw > 0 ? .ready(map) : .empty(reason: t("spending.heat.empty"))
        }
      ) { map in
        HourHeatmapView(heatmap: map)
      }
    }
  }

  private func t(_ key: String) -> String { SpendingText.t(key, environment) }
}

/// The weekend against the weekdays of a period, and month by month.
struct WeekendPriceView: View {
  @Dependency(\.environment) private var environment
  let price: WeekendPrice

  var body: some View {
    let money = environment.money
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 24) {
        figure(
          SpendingText.t("spending.weekend.weekend", environment), money.rounded(price.weekend),
          symbol: "sun.max", id: "spending.weekend.figure")
        figure(
          SpendingText.t("spending.weekend.weekdays", environment), money.rounded(price.weekdays),
          symbol: "briefcase", id: "spending.weekend.weekdays")
      }
      if let share = price.weekendShare {
        Text(
          verbatim: SpendingText.format(
            "spending.weekend.share", environment,
            money.percent(basisPoints: share, fractionDigits: 0))
        )
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }
      Text(verbatim: SpendingText.windowLine(price.window, environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("spending.weekend.window")
      if price.months.count > 1 {
        Divider()
        ForEach(price.months.reversed(), id: \.month) { month in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(verbatim: environment.dates.shortMonthAndYear(month.month))
              Spacer()
              Text(verbatim: money.rounded(month.weekend)).monospacedDigit()
            }
            .appFont(.callout)
            ShareBar(
              basisPoints: (month.weekend + month.weekdays).raw > 0
                ? Shares.ratio(month.weekend, of: month.weekend + month.weekdays) : nil)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func figure(_ caption: String, _ value: String, symbol: String, id: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Label(caption, systemImage: symbol).appFont(.caption).foregroundStyle(.secondary)
      Text(verbatim: value).appFont(.title2.monospacedDigit())
        .accessibilityIdentifier(id)
    }
  }
}

/// The usual day: overall, on weekdays and on weekends, each with the days it rests on.
struct UsualDayView: View {
  @Dependency(\.environment) private var environment
  let usual: UsualDay

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      row("spending.usual.overall", usual.overall, id: "overall")
      row("spending.usual.weekdays", usual.weekdays, id: "weekdays")
      row("spending.usual.weekends", usual.weekends, id: "weekends")
    }
  }

  private func row(_ key: String, _ figure: UsualDay.Figure, id: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(verbatim: SpendingText.t(key, environment))
      Spacer()
      if let amount = figure.amount {
        Text(verbatim: environment.money.rounded(amount)).monospacedDigit()
      } else {
        Label {
          Text(
            verbatim: SpendingText.format(
              "spending.usual.low", environment, figure.daysWithSpending, UsualDay.minimumDays))
        } icon: {
          Image(systemName: "hourglass")
        }
        .foregroundStyle(.secondary)
        .appFont(.caption)
      }
    }
    .appFont(.callout)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("spending.usual.\(id)")
  }
}

// MARK: - Places and habits

private struct HabitsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let period: AnalyticsPeriod
  @State private var byAmount = false
  @State private var settingPlaces = false
  @State private var receiptPlace: UUID?
  @Environment(\.dependencies) private var dependencies

  struct PlacesDisplay: Sendable {
    var places: FavoritePlaces
    var names: AnalyticsNames
  }

  struct ReceiptDisplay: Sendable {
    var history: ReceiptHistory
    var names: AnalyticsNames
    /// The places that have a chart, the most visited first.
    var charted: [UUID]
  }

  struct HabitsDisplay: Sendable {
    var habits: PlaceHabits
    var names: AnalyticsNames
  }

  struct PeopleDisplay: Sendable {
    var people: SpendingOnPeople
    var names: AnalyticsNames
  }

  private var year: DayRange {
    DayRange(period.month.adding(months: -11).firstDay, period.month.lastDay)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SpendingBlock(
        identifier: "spending.places", title: t("spending.places.title"),
        subtitle: t("spending.places.basis"), request: period.period,
        fetch: { snapshot, period async throws -> SpendingOutcome<PlacesDisplay> in
          let places = try await compute.analysis.spending.favoritePlaces(snapshot, period: period)
          guard !places.byVisits.isEmpty else {
            return .empty(reason: t("spending.places.empty"))
          }
          return .ready(
            PlacesDisplay(places: places, names: AnalyticsNames(dataset: snapshot.dataset)))
        },
        accessory: { setPlacesButton }
      ) { display in
        placesList(display)
      }
      SpendingBlock(
        identifier: "spending.receipts", title: t("spending.receipt.title"),
        subtitle: t("spending.receipt.basis"), request: year,
        fetch: { snapshot, range async throws -> SpendingOutcome<ReceiptDisplay> in
          let history = try await compute.analysis.spending.receiptHistory(snapshot, range: range)
          let charted = history.series.filter { !$0.value.isEmpty }.keys.sorted {
            let left = history.points(for: $0).map(\.visits).reduce(0, +)
            let right = history.points(for: $1).map(\.visits).reduce(0, +)
            return left != right ? left > right : $0.uuidString < $1.uuidString
          }
          guard !charted.isEmpty else { return .empty(reason: t("spending.receipt.noChart")) }
          return .ready(
            ReceiptDisplay(
              history: history, names: AnalyticsNames(dataset: snapshot.dataset),
              charted: Array(charted.prefix(8))))
        }
      ) { display in
        receiptChart(display)
      }
      SpendingBlock(
        identifier: "spending.habits", title: t("spending.habits.title"),
        subtitle: t("spending.habits.basis"), request: 0,
        fetch: { snapshot, _ async throws -> SpendingOutcome<HabitsDisplay> in
          let habits = try await compute.analysis.spending.placeHabits(snapshot)
          guard !habits.habits.isEmpty else { return .empty(reason: t("spending.habits.empty")) }
          return .ready(
            HabitsDisplay(habits: habits, names: AnalyticsNames(dataset: snapshot.dataset)))
        }
      ) { display in
        habitsList(display)
      }
      SpendingBlock(
        identifier: "spending.people", title: t("spending.people.title"),
        subtitle: t("spending.people.basis"), request: year,
        fetch: { snapshot, range async throws -> SpendingOutcome<PeopleDisplay> in
          let people = try await compute.analysis.spending.spendingOnPeople(snapshot, range: range)
          guard !people.people.isEmpty else { return .empty(reason: t("spending.people.empty")) }
          return .ready(
            PeopleDisplay(people: people, names: AnalyticsNames(dataset: snapshot.dataset)))
        }
      ) { display in
        peopleList(display)
      }
    }
    .sheet(isPresented: $settingPlaces) {
      PlaceFromNoteSheet().handingOver(dependencies)
    }
  }

  // MARK: Pieces

  private var setPlacesButton: some View {
    Button {
      settingPlaces = true
    } label: {
      Label(t("spending.places.setFromNote"), systemImage: "mappin.and.ellipse")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .accessibilityIdentifier("spending.places.setFromNote")
  }

  @ViewBuilder
  private func placesList(_ display: PlacesDisplay) -> some View {
    let money = environment.money
    let places = byAmount ? display.places.byAmount : display.places.byVisits
    VStack(alignment: .leading, spacing: 8) {
      if let hint = SpendingText.withoutPlaceHint(display.places, environment) {
        Label {
          Text(verbatim: hint).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "info.circle")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("spending.places.hint")
      }
      Picker(selection: $byAmount) {
        Text(verbatim: t("spending.places.byVisits")).tag(false)
        Text(verbatim: t("spending.places.byAmount")).tag(true)
      } label: {
        EmptyView()
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      ForEach(Array(places.prefix(10).enumerated()), id: \.offset) { _, place in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(verbatim: AnalyticsText.name(of: .place(place.placeId), display.names, environment))
            .lineLimit(1)
          Spacer(minLength: 8)
          Text(
            verbatim: SpendingText.counted(
              "spending.places.visits", environment, count: place.purchases)
          )
          .foregroundStyle(.secondary)
          Text(verbatim: money.rounded(place.mySpending)).monospacedDigit()
            .frame(minWidth: 90, alignment: .trailing)
        }
        .appFont(.callout)
        .accessibilityElement(children: .combine)
      }
    }
  }

  @ViewBuilder
  private func receiptChart(_ display: ReceiptDisplay) -> some View {
    let chosen =
      receiptPlace.flatMap { display.charted.contains($0) ? $0 : nil } ?? display.charted[0]
    let points = display.history.points(for: chosen)
    VStack(alignment: .leading, spacing: 8) {
      Picker(selection: Binding(get: { chosen }, set: { receiptPlace = $0 })) {
        ForEach(display.charted, id: \.self) { id in
          Text(verbatim: AnalyticsText.name(of: .place(id), display.names, environment)).tag(id)
        }
      } label: {
        Text(verbatim: t("spending.receipt.place"))
      }
      .pickerStyle(.menu)
      .fixedSize()
      SeriesLineChart(
        series: [
          ChartLineSeries(
            id: chosen.uuidString,
            label: AnalyticsText.name(of: .place(chosen), display.names, environment),
            style: ChartSeriesStyle.series(0, accent: environment.theme.accent),
            points: points.enumerated().map { index, point in
              ChartLinePoint(
                x: index, value: point.average.wholeRubles,
                spokenLabel: environment.dates.monthTitle(point.month),
                valueText: environment.money.rounded(point.average))
            },
            endText: points.last.map { environment.money.rounded($0.average) })
        ],
        xLabels: Dictionary(
          uniqueKeysWithValues: points.enumerated().map {
            ($0.offset, environment.dates.shortMonth($0.element.month))
          })
      )
      .frame(height: 180)
    }
  }

  @ViewBuilder
  private func habitsList(_ display: HabitsDisplay) -> some View {
    let money = environment.money
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(display.habits.habits.prefix(10).enumerated()), id: \.offset) { _, habit in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Label(
              AnalyticsText.name(of: .place(habit.placeId), display.names, environment),
              systemImage: "repeat")
            Spacer()
            Text(verbatim: money.rounded(habit.yearlyCost)).monospacedDigit()
          }
          .appFont(.callout)
          Text(
            verbatim: SpendingText.format(
              "spending.habits.line", environment, money.rounded(habit.weeklyAverage),
              habit.weeksWithVisits, PlaceHabits.weeks)
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  @ViewBuilder
  private func peopleList(_ display: PeopleDisplay) -> some View {
    let money = environment.money
    VStack(alignment: .leading, spacing: 6) {
      ForEach(display.people.people, id: \.personId) { line in
        HStack {
          Label(
            AnalyticsText.name(of: .person(line.personId), display.names, environment),
            systemImage: "person")
          Spacer()
          Text(verbatim: money.rounded(line.amount)).monospacedDigit()
        }
        .appFont(.callout)
        .accessibilityElement(children: .combine)
      }
      Divider()
      HStack {
        Text(verbatim: t("spending.people.total"))
        Spacer()
        Text(verbatim: money.rounded(display.people.total)).monospacedDigit()
      }
      .appFont(.callout.weight(.semibold))
    }
  }

  private func t(_ key: String) -> String { SpendingText.t(key, environment) }
}

// MARK: - Leaks, limits, price in hours

private struct LeaksSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let period: AnalyticsPeriod
  @State private var grouping: LeakGrouping = .place
  @State private var categoryId: UUID?
  @State private var price: AmountE4 = .zero

  struct LeaksDisplay: Sendable {
    var leaks: SpendingLeaks
    var names: AnalyticsNames
  }

  struct EatenDisplay: Sendable {
    var consumption: LimitConsumption
    /// Names of the three largest purchases, by position.
    var titles: [String]
  }

  private struct EatenRequest: Hashable, Sendable {
    var categoryId: UUID?
    var month: MonthKey
  }

  /// The categories of spending the limit card can be about: top level, live, not system.
  private var categories: [CoreKit.Category] {
    (compute.snapshot?.dataset.categories ?? []).filter {
      $0.kind == .expense && $0.parentId == nil && !$0.archived && $0.systemRole == nil
    }.sorted { $0.sort < $1.sort }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SpendingBlock(
        identifier: "spending.leaks", title: t("spending.leaks.title"),
        subtitle: t("spending.leaks.basis"), request: grouping,
        fetch: { snapshot, grouping async throws -> SpendingOutcome<LeaksDisplay> in
          let leaks = try await compute.analysis.spending.leaks(snapshot, grouping: grouping)
          guard !leaks.leaks.isEmpty else { return .empty(reason: t("spending.leaks.empty")) }
          return .ready(
            LeaksDisplay(leaks: leaks, names: AnalyticsNames(dataset: snapshot.dataset)))
        },
        accessory: { groupingPicker }
      ) { display in
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(display.leaks.leaks.prefix(10).enumerated()), id: \.offset) { _, leak in
            Label {
              Text(
                verbatim: SpendingText.leakLine(
                  leak, name: AnalyticsText.name(of: leak.key, display.names, environment),
                  environment)
              )
              .fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(systemName: "drop").accessibilityHidden(true)
            }
            .appFont(.callout.monospacedDigit())
          }
        }
        .accessibilityIdentifier("spending.leaks.lines")
      }
      SpendingBlock(
        identifier: "spending.limit", title: t("spending.limit.title"),
        subtitle: t("spending.limit.basis"),
        request: EatenRequest(categoryId: categoryId ?? categories.first?.id, month: period.month),
        fetch: { snapshot, request async throws -> SpendingOutcome<EatenDisplay> in
          guard let id = request.categoryId else {
            return .empty(reason: t("spending.limit.empty"))
          }
          let eaten = try await compute.analysis.spending.limitConsumption(
            snapshot, categoryId: id, month: request.month)
          guard eaten.spent.raw > 0 else { return .empty(reason: t("spending.limit.empty")) }
          let titles = eaten.largest.map { purchase in
            snapshot.ledger.entry(purchase.transactionId).flatMap {
              OverviewSummary.title(of: $0, tree: snapshot.ledger.tree)
            } ?? "—"
          }
          return .ready(EatenDisplay(consumption: eaten, titles: titles))
        },
        accessory: { categoryPicker }
      ) { display in
        eaten(display)
      }
      SpendingBlock(
        identifier: "spending.hours", title: t("spending.hours.title"),
        subtitle: t("spending.hours.basis"), request: 0,
        fetch: { snapshot, _ async throws -> SpendingOutcome<WorkRate> in
          guard snapshot.dataset.workHours.isEnabled else {
            return .empty(reason: t("spending.hours.off"))
          }
          guard let rate = try await compute.analysis.spending.workRate(snapshot) else {
            return .empty(reason: t("spending.hours.noIncome"))
          }
          return .ready(rate)
        }
      ) { rate in
        hours(rate)
      }
    }
  }

  // MARK: Pieces

  private var groupingPicker: some View {
    Picker(selection: $grouping) {
      ForEach(LeakGrouping.allCases, id: \.self) { value in
        Text(verbatim: SpendingText.name(of: value, environment)).tag(value)
      }
    } label: {
      Text(verbatim: t("spending.leaks.grouping"))
    }
    .pickerStyle(.menu)
    .fixedSize()
    .accessibilityIdentifier("spending.leaks.grouping")
  }

  private var categoryPicker: some View {
    Picker(
      selection: Binding(get: { categoryId ?? categories.first?.id }, set: { categoryId = $0 })
    ) {
      ForEach(categories, id: \.id) { category in
        Text(verbatim: category.name).tag(UUID?.some(category.id))
      }
    } label: {
      Text(verbatim: t("spending.limit.category"))
    }
    .pickerStyle(.menu)
    .fixedSize()
    .accessibilityIdentifier("spending.limit.category")
  }

  @ViewBuilder
  private func eaten(_ display: EatenDisplay) -> some View {
    let money = environment.money
    let consumption = display.consumption
    VStack(alignment: .leading, spacing: 6) {
      Text(
        verbatim: SpendingText.format(
          "spending.limit.spent", environment, money.rounded(consumption.spent))
      )
      .appFont(.callout.weight(.semibold).monospacedDigit())
      ForEach(Array(consumption.largest.enumerated()), id: \.offset) { index, purchase in
        HStack {
          Text(verbatim: display.titles[index]).lineLimit(1)
          Spacer()
          Text(verbatim: money.rounded(purchase.amount)).monospacedDigit()
        }
        .appFont(.callout)
        .accessibilityElement(children: .combine)
      }
      if let others = SpendingText.othersLine(consumption, environment) {
        Text(verbatim: others)
          .appFont(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("spending.limit.others")
      }
    }
  }

  @ViewBuilder
  private func hours(_ rate: WorkRate) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        verbatim: SpendingText.format(
          "spending.hours.rate", environment, environment.money.rounded(rate.hourly))
      )
      .appFont(.callout.monospacedDigit())
      HStack(spacing: 10) {
        Text(verbatim: t("spending.hours.amount"))
        AmountField(amount: $price).frame(width: 140)
        if price.raw > 0 {
          Text(verbatim: SpendingText.hoursLine(rate, price: price, environment))
            .appFont(.callout.weight(.semibold))
            .accessibilityIdentifier("spending.hours.result")
        }
      }
    }
  }

  private func t(_ key: String) -> String { SpendingText.t(key, environment) }
}
