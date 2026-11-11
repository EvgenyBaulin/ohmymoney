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
  @Environment(\.windowWidth) private var windowWidth
  @State private var withoutOneOff = false

  /// Two cards in a row from about 900 pt of window, as in the frame (568 + 16 + 568).
  private var isWide: Bool { windowWidth == 0 || windowWidth >= 900 }

  private struct WeekendRequest: Hashable, Sendable {
    var range: DayRange
    var withoutOneOff: Bool
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
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
      let pair =
        isWide
        ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
      pair {
        SpendingBlock(
          identifier: "spending.usualDay", title: t("spending.usual.title"),
          subtitle: t("spending.usual.basis"), request: 0,
          fetch: { snapshot, _ in .ready(try await compute.analysis.spending.usualDay(snapshot)) }
        ) { usual in
          UsualDayView(usual: usual)
        }
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
    let whole = (price.weekend + price.weekdays).raw
    VStack(alignment: .leading, spacing: 12) {
      shareRow(
        SpendingText.t("spending.weekend.weekdays", environment), price.weekdays,
        of: whole, id: "spending.weekend.weekdays")
      shareRow(
        SpendingText.t("spending.weekend.weekend", environment), price.weekend, of: whole,
        id: "spending.weekend.figure")
      if let share = price.weekendShare {
        Text(
          verbatim: SpendingText.format(
            "spending.weekend.share", environment,
            money.percent(basisPoints: share, fractionDigits: 0))
        )
        .appFont(AnalyticsCardType.subtitle)
        .foregroundStyle(.secondary)
      }
      Text(verbatim: SpendingText.windowLine(price.window, environment))
        .appFont(AnalyticsCardType.subtitle)
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

  /// A name of 150, a bar of the rest in which this part fills its share of the whole, and the
  /// amount at the right in 100: the rows of «Цена выходных» (61:61993).
  private func shareRow(
    _ name: String, _ amount: AmountE4, of whole: Int64, id: String
  )
    -> some View
  {
    HStack(spacing: 10) {
      Text(verbatim: name).frame(width: 150, alignment: .leading)
      WeekendShareBar(part: amount.raw, whole: whole)
      Text(verbatim: environment.money.rounded(amount))
        .monospacedDigit()
        .frame(width: 100, alignment: .trailing)
        .accessibilityIdentifier(id)
    }
    .appFont(AnalyticsCardType.row)
    .accessibilityElement(children: .combine)
  }
}

/// The bar of 12 of a weekend row: the part of the whole this row stands for in the accent,
/// the rest on the neutral track.
struct WeekendShareBar: View {
  @Environment(\.appTheme) private var theme
  /// The part and the whole in the same units; only their ratio reaches the screen.
  let part: Int64
  let whole: Int64

  /// 0...1 of the track, from whole thousandths so no money passes through floating point.
  private var share: CGFloat {
    guard whole > 0 else { return 0 }
    let thousandths = min(1000, max(0, part.multipliedReportingOverflow(by: 1000).partialValue / whole))
    return CGFloat(thousandths) / 1000
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Rectangle().fill(theme.fillNeutral)
        Rectangle().fill(theme.accentDefault)
          .frame(width: proxy.size.width * share)
      }
      .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .frame(height: 12)
    .accessibilityHidden(true)
  }
}

/// The usual day: overall, on weekdays and on weekends, each with the days it rests on.
struct UsualDayView: View {
  @Dependency(\.environment) private var environment
  let usual: UsualDay

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      row("spending.usual.overall", usual.overall, id: "overall")
      row("spending.usual.weekdays", usual.weekdays, id: "weekdays")
      row("spending.usual.weekends", usual.weekends, id: "weekends")
      if let weekdays = usual.weekdays.amount, let weekends = usual.weekends.amount {
        Text(
          verbatim: SpendingText.format(
            "spending.usual.split", environment, environment.money.rounded(weekdays),
            usual.weekdays.daysWithSpending, environment.money.rounded(weekends),
            usual.weekends.daysWithSpending)
        )
        .appFont(AnalyticsCardType.subtitle)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("spending.usual.split")
      }
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
    .appFont(AnalyticsCardType.row)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("spending.usual.\(id)")
  }
}

// MARK: - Places and habits

private struct HabitsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let period: AnalyticsPeriod
  @Environment(\.windowWidth) private var windowWidth
  @State private var byAmount = true
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

  /// Two cards in a row from about 900 pt of window (568 + 16 + 568 in the frame).
  private var isWide: Bool { windowWidth == 0 || windowWidth >= 900 }

  private var year: DayRange {
    DayRange(period.month.adding(months: -11).firstDay, period.month.lastDay)
  }

  var body: some View {
    let layout =
      isWide
      ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
    VStack(alignment: .leading, spacing: 16) {
      layout {
        SpendingBlock(
          identifier: "spending.places", title: t("spending.places.title"),
          subtitle: t("spending.places.basis"), request: period.period,
          fetch: { snapshot, period async throws -> SpendingOutcome<PlacesDisplay> in
            let places = try await compute.analysis.spending.favoritePlaces(
              snapshot, period: period)
            guard !places.byVisits.isEmpty else {
              return .empty(reason: t("spending.places.empty"))
            }
            return .ready(
              PlacesDisplay(places: places, names: AnalyticsNames(dataset: snapshot.dataset)))
          }
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
      }
      layout {
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
            let people = try await compute.analysis.spending.spendingOnPeople(
              snapshot, range: range)
            guard !people.people.isEmpty else { return .empty(reason: t("spending.people.empty")) }
            return .ready(
              PeopleDisplay(people: people, names: AnalyticsNames(dataset: snapshot.dataset)))
          }
        ) { display in
          peopleList(display)
        }
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
    let places = byAmount ? display.places.byAmount : display.places.byVisits
    VStack(alignment: .leading, spacing: 12) {
      Picker(selection: $byAmount) {
        Text(verbatim: t("spending.places.byAmount")).tag(true)
        Text(verbatim: t("spending.places.byVisits")).tag(false)
      } label: {
        EmptyView()
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      TrackBarsChart(
        rows: places.prefix(10).map { place in
          let amount = environment.money.rounded(place.mySpending)
          let visits = SpendingText.counted(
            "spending.places.visits", environment, count: place.purchases)
          return TrackRow(
            id: place.placeId.uuidString,
            label: AnalyticsText.name(of: .place(place.placeId), display.names, environment),
            marker: nil, tint: .accent,
            value: byAmount ? place.mySpending.wholeRubles : Int64(place.purchases),
            previous: nil, amount: amount, note: visits, spokenValue: "\(amount), \(visits)")
        }, layout: .half)
      if let hint = SpendingText.withoutPlaceHint(display.places, environment) {
        Text(verbatim: hint)
          .appFont(AnalyticsCardType.subtitle)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("spending.places.hint")
      }
      setPlacesButton
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
      MonthBarsChart(
        bars: points.map { point in
          MonthBar(
            id: point.month.iso, value: point.average.wholeRubles, isHighlighted: false,
            spokenLabel:
              "\(environment.dates.monthTitle(point.month)), \(environment.money.rounded(point.average))"
          )
        }, height: 90, allAccent: true)
      if let last = points.last {
        Text(
          verbatim: SpendingText.format(
            "spending.receipt.average", environment, environment.money.rounded(last.average))
        )
        .appFont(AnalyticsCardType.subtitle)
        .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func habitsList(_ display: HabitsDisplay) -> some View {
    let money = environment.money
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(display.habits.habits.prefix(10).enumerated()), id: \.offset) { _, habit in
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: AnalyticsText.name(of: .place(habit.placeId), display.names, environment))
            .appFont(.system(size: 13, weight: .medium))
          Text(
            verbatim: SpendingText.format(
              "spending.habits.line", environment, money.rounded(habit.weeklyAverage),
              habit.weeksWithVisits, PlaceHabits.weeks)
          )
          .appFont(AnalyticsCardType.subtitle.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  @ViewBuilder
  private func peopleList(_ display: PeopleDisplay) -> some View {
    let money = environment.money
    let whole = display.people.total.raw
    VStack(alignment: .leading, spacing: 12) {
      ForEach(display.people.people, id: \.personId) { line in
        HStack(spacing: 10) {
          Text(verbatim: AnalyticsText.name(of: .person(line.personId), display.names, environment))
            .lineLimit(1)
            .frame(width: 150, alignment: .leading)
          WeekendShareBar(part: line.amount.raw, whole: whole)
          Text(verbatim: money.rounded(line.amount)).monospacedDigit()
            .frame(width: 100, alignment: .trailing)
        }
        .appFont(AnalyticsCardType.row)
        .accessibilityElement(children: .combine)
      }
      HStack {
        Text(verbatim: t("spending.people.total"))
        Spacer()
        Text(verbatim: money.rounded(display.people.total)).monospacedDigit()
      }
      .appFont(AnalyticsCardType.row)
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
    /// The spending holds purchases of a covered hidden account, counted among the others.
    var partHidden = false
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

  @Environment(\.windowWidth) private var windowWidth

  /// «Утечки» and «Что съело лимит» side by side from about 900 pt (568 + 16 + 568).
  private var isWide: Bool { windowWidth == 0 || windowWidth >= 900 }

  var body: some View {
    let pair =
      isWide
      ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
    VStack(alignment: .leading, spacing: 16) {
      pair {
        SpendingBlock(
          identifier: "spending.leaks", title: t("spending.leaks.title"),
          subtitle: t("spending.leaks.basis"), request: grouping,
          fetch: { snapshot, grouping async throws -> SpendingOutcome<LeaksDisplay> in
            let leaks = try await compute.analysis.spending.leaks(snapshot, grouping: grouping)
            guard !leaks.leaks.isEmpty else { return .empty(reason: t("spending.leaks.empty")) }
            return .ready(
              LeaksDisplay(leaks: leaks, names: AnalyticsNames(dataset: snapshot.dataset)))
          }
        ) { display in
          VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(display.leaks.leaks.prefix(10).enumerated()), id: \.offset) { _, leak in
              leakRow(leak, display.names)
            }
          }
          .accessibilityIdentifier("spending.leaks.lines")
        }
        .prelude { groupingPicker }
        SpendingBlock(
          identifier: "spending.limit", title: t("spending.limit.title"),
          subtitle: t("spending.limit.basis"),
          request: EatenRequest(
            categoryId: categoryId ?? categories.first?.id, month: period.month),
          fetch: { snapshot, request async throws -> SpendingOutcome<EatenDisplay> in
            guard let id = request.categoryId else {
              return .empty(reason: t("spending.limit.empty"))
            }
            let whole = try await compute.analysis.spending.limitConsumption(
              snapshot, categoryId: id, month: request.month)
            guard whole.spent.raw > 0 else { return .empty(reason: t("spending.limit.empty")) }
            let (eaten, partHidden) = whole.covering(
              HiddenOperations(snapshot: snapshot), in: snapshot.ledger)
            let titles = eaten.largest.map { purchase in
              snapshot.ledger.entry(purchase.transactionId).flatMap {
                OverviewSummary.title(of: $0, tree: snapshot.ledger.tree)
              } ?? "—"
            }
            return .ready(EatenDisplay(consumption: eaten, titles: titles, partHidden: partHidden))
          }
        ) { display in
          eaten(display)
        }
        .prelude { categoryRow }
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
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize()
    .accessibilityIdentifier("spending.leaks.grouping")
  }

  /// «Категория» at the left, its menu at the right, as the frame draws the head of the card.
  private var categoryRow: some View {
    HStack {
      Text(verbatim: t("spending.limit.category")).appFont(AnalyticsCardType.row)
      Spacer(minLength: 12)
      Picker(
        selection: Binding(get: { categoryId ?? categories.first?.id }, set: { categoryId = $0 })
      ) {
        ForEach(categories, id: \.id) { category in
          Text(verbatim: category.name).tag(UUID?.some(category.id))
        }
      } label: {
        Text(verbatim: t("spending.limit.category"))
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize()
      .accessibilityIdentifier("spending.limit.category")
    }
  }

  /// A leak as the frame draws it: the name over a grey line of what is known of it.
  private func leakRow(_ leak: SpendingLeaks.Leak, _ names: AnalyticsNames) -> some View {
    let name = AnalyticsText.name(of: leak.key, names, environment)
    let full = SpendingText.leakLine(leak, name: name, environment)
    let detail =
      full.hasPrefix(name)
      ? String(full.dropFirst(name.count)).trimmingCharacters(in: .whitespaces) : full
    return VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: name).appFont(.system(size: 13, weight: .medium))
      Text(verbatim: detail)
        .appFont(AnalyticsCardType.subtitle.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func eaten(_ display: EatenDisplay) -> some View {
    let money = environment.money
    let consumption = display.consumption
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: t("spending.limit.spentLabel"))
        if display.partHidden { PartHiddenNote() }
        Spacer(minLength: 8)
        Text(verbatim: money.rounded(consumption.spent)).monospacedDigit()
      }
      .appFont(AnalyticsCardType.row)
      .accessibilityElement(children: .combine)
      ForEach(Array(consumption.largest.enumerated()), id: \.offset) { index, purchase in
        HStack {
          Text(verbatim: display.titles[index]).lineLimit(1)
          Spacer()
          Text(verbatim: money.rounded(purchase.amount)).monospacedDigit()
        }
        .appFont(AnalyticsCardType.row)
        .accessibilityElement(children: .combine)
      }
      if let others = SpendingText.othersLine(consumption, environment) {
        Text(verbatim: others)
          .appFont(AnalyticsCardType.subtitle.monospacedDigit())
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

extension LimitConsumption {
  /// The card as it is shown while the hidden accounts are covered: a purchase of a hidden
  /// account is not named among the largest, it is counted with the others, and what was spent
  /// stays the whole figure. `partHidden` — a purchase of a hidden account was among the largest;
  /// the others are a count and a sum, which name nobody.
  func covering(
    _ hidden: HiddenOperations, in ledger: Ledger
  ) -> (LimitConsumption, partHidden: Bool) {
    guard !hidden.isEmpty else { return (self, false) }
    var copy = self
    var partHidden = false
    var kept: [Purchase] = []
    for purchase in largest {
      if hidden.hides(operation: purchase.transactionId, in: ledger) {
        partHidden = true
        copy.othersCount += 1
        copy.othersTotal += purchase.amount
        copy.othersLargest = max(copy.othersLargest ?? purchase.amount, purchase.amount)
      } else {
        kept.append(purchase)
      }
    }
    copy.largest = kept
    return (copy, partHidden)
  }
}
