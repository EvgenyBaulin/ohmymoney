import AppCore
import Foundation

/// The words of the Analytics window: names of the lines, titles of periods, labels of the
/// axes and the figures on the charts, in the language of the moment. The model
/// holds keys, days and whole rubles; these turn them into what the charts draw — a lookup,
/// never a calculation, so it runs in `body` and a language switch redraws the axes at once.
/// Apart from the views, so a test reads them in both languages.
@MainActor
enum AnalyticsText {
  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: "Analytics")
  }

  /// A card's line under its account in «Оборот и кэшбэк»: the card's name, or «Без карты» for
  /// the account's own line.
  static func cardLine(
    _ cardId: UUID?, _ names: AnalyticsNames, _ environment: AppEnvironment
  ) -> String {
    guard let cardId else { return t("analytics.cashback.noCard", environment) }
    return names[cardId]?.text ?? "—"
  }

  /// A choice of «Кэшбэк по месяцам»: «Все счета», an account, or «Т-Банк › Black».
  static func cashbackChoice(
    _ choice: CashbackMonthsModel.Choice, model: CashbackMonthsModel, _ names: AnalyticsNames,
    _ environment: AppEnvironment
  ) -> String {
    switch choice {
    case .all: return t("analytics.cashback.allHolders", environment)
    case .account(let id): return names[id]?.text ?? "—"
    case .card(let id):
      let card = names[id]?.text ?? "—"
      guard let account = model.cardAccounts[id].flatMap({ names[$0]?.text }) else {
        return card
      }
      return account + AccountLabels.separator + card
    }
  }

  // MARK: - Lines of the cashback tables

  /// A line of a grid of figures: each cell as shown, and the whole line as VoiceOver hears it
  /// once — the first cell, then every figure after the header of its column in lower case:
  /// «Сентябрь 2026, ожидаемый кэшбэк 118 ₽, полученный кэшбэк 25 ₽, разница −93 ₽». A modifier
  /// on a `GridRow` reaches each cell on its own, so the first cell says the line and the others
  /// are silent.
  struct GridLine: Hashable, Sendable {
    var first: String
    var figures: [String]
    var spoken: String
  }

  /// The line of `first` and `figures`, each figure under the header of the key given with it.
  /// A figure shown as «—» or left empty is not said.
  static func gridLine(
    _ first: String, _ figures: [(header: String, text: String)], _ environment: AppEnvironment
  ) -> GridLine {
    let locale = environment.language.locale
    let said = figures.filter { !$0.text.isEmpty && $0.text != "—" }.map {
      t($0.header, environment).lowercased(with: locale) + " " + $0.text
    }
    return GridLine(
      first: first, figures: figures.map(\.text), spoken: ([first] + said).joined(separator: ", "))
  }

  /// A month of «Кэшбэк по месяцам»: expected, received and the difference with its sign.
  static func cashbackMonthLine(
    _ row: CashbackMonthsModel.Month, _ environment: AppEnvironment
  ) -> GridLine {
    let money = environment.money
    return gridLine(
      environment.dates.monthTitle(row.month),
      [
        ("analytics.column.cashbackExpected", money.rubles(row.expected)),
        ("analytics.column.cashback", money.rubles(row.received)),
        ("analytics.column.cashbackDifference", money.signedRubles(row.difference)),
      ], environment)
  }

  /// An account of «Оборот и кэшбэк»: my spending, the turnover, the cashback expected and
  /// received, and the actual share — «—» when there was no turnover.
  static func methodLine(
    _ row: MethodRow, _ names: AnalyticsNames, _ environment: AppEnvironment
  ) -> GridLine {
    let money = environment.money
    return gridLine(
      name(of: row.key, names, environment),
      [
        ("analytics.column.mySpending", money.rubles(row.mySpending)),
        ("analytics.column.turnover", money.rubles(row.turnover)),
        ("analytics.column.cashbackExpected", expectedCashback(row.expectedCashback, environment)),
        ("analytics.column.cashback", money.rubles(row.cashback)),
        (
          "analytics.column.cashbackShare",
          row.cashbackShare.map { money.percent(basisPoints: $0, fractionDigits: 1) } ?? "—"
        ),
      ], environment)
  }

  /// A card's line under its account — or the account's own, «Без карты»: the same figures but
  /// the share, which a card has not of its own.
  static func cardMethodLine(
    _ card: CardMethodRow, _ names: AnalyticsNames, _ environment: AppEnvironment
  ) -> GridLine {
    let money = environment.money
    return gridLine(
      cardLine(card.cardId, names, environment),
      [
        ("analytics.column.mySpending", money.rubles(card.mySpending)),
        ("analytics.column.turnover", money.rubles(card.turnover)),
        ("analytics.column.cashbackExpected", expectedCashback(card.expected, environment)),
        ("analytics.column.cashback", money.rubles(card.received)),
      ], environment)
  }

  /// An expectation, never income: «≈» before a figure that is not zero.
  static func expectedCashback(_ value: Int64, _ environment: AppEnvironment) -> String {
    let text = environment.money.rubles(value)
    return value == 0 ? text : "≈\u{00A0}" + text
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  )
    -> String
  {
    String(
      format: t(key, environment), locale: environment.language.locale, arguments: arguments)
  }

  /// A string with one count in it, the count grouped like every number: «1,250 покупок».
  static func format(_ key: String, _ environment: AppEnvironment, count: Int) -> String {
    environment.language.format(key, table: "Analytics", counts: count)
  }

  // MARK: - Names

  /// The name of a scheduled payment, «(архив)» when it is no longer active. Not a
  /// `ReportKey`: the switches over that enum are exhaustive in the CSV and the reports too,
  /// and a payment has nothing to say there.
  static func name(
    ofPayment id: UUID, _ names: AnalyticsNames, _ environment: AppEnvironment
  ) -> String {
    // A charge carries its payment as text (`sched:<id>:<due>`), with no foreign key, so a
    // payment deleted from the plan leaves charges nothing points back at. The bar is still
    // true — the money moved — and it says what it is instead of showing a dash.
    guard let name = names[id] else { return t("analytics.none.payment", environment) }
    return name.archived ? environment.format("common.archivedName", name.text) : name.text
  }

  /// The name of a line: a dictionary entry as it is now, with «(архив)» when it is
  /// archived; the lines without one in words of the interface.
  static func name(
    of key: ReportKey, _ names: AnalyticsNames, _ environment: AppEnvironment
  ) -> String {
    func named(_ id: UUID) -> String {
      guard let name = names[id] else { return "—" }
      return name.archived ? environment.format("common.archivedName", name.text) : name.text
    }
    switch key {
    case .category(let id), .person(let id), .place(let id), .event(let id),
      .paymentMethod(let id):
      return named(id)
    case .uncategorized: return environment.language("category.uncategorized")
    case .noSubcategory: return t("analytics.none.subcategory", environment)
    case .forWhom(let value): return environment.label(for: value)
    case .noPerson: return t("analytics.none.person", environment)
    case .noPlace: return t("analytics.none.place", environment)
    case .noEvent: return t("analytics.none.event", environment)
    case .noPaymentMethod: return t("analytics.none.paymentMethod", environment)
    case .month(let month): return environment.dates.monthTitle(month)
    case .quality(let quality): return environment.language(Palette.qualityKey(quality))
    case .income: return t("analytics.series.income", environment)
    case .expenses: return t("analytics.series.expenses", environment)
    case .net: return environment.language("common.net")
    case .total: return environment.language("common.total")
    case .average: return t("analytics.average.title", environment)
    }
  }

  // MARK: - Anomalies

  /// The numbers the rule is made of, in words. Every line says what happened and what it
  /// is measured against — a verdict without its reasoning is not worth showing. The names
  /// come from the freshest snapshot while the anomaly may come from an earlier run, so a
  /// name deleted meanwhile falls back to the words of its own kind.
  static func anomalyDetail(
    _ anomaly: Anomaly, names: AnalyticsNames, _ environment: AppEnvironment
  ) -> String {
    func named(_ id: UUID?, else missing: @autoclosure () -> String) -> String {
      guard let id, let name = names[id] else { return missing() }
      return name.archived ? environment.format("common.archivedName", name.text) : name.text
    }
    let category = named(anomaly.categoryId, else: environment.language("category.uncategorized"))
    let person = named(anomaly.personId, else: t("analytics.none.person", environment))
    let event = named(anomaly.eventId, else: t("analytics.none.event", environment))
    let money = environment.money
    let amount = money.rounded(anomaly.amount)
    let reference = money.rounded(anomaly.reference)
    let key = "analytics.anomaly.\(anomaly.rule.rawValue).detail"
    switch anomaly.rule {
    case .largeExpense:
      return format(key, environment, amount, category, reference)
    case .possibleDuplicate:
      return format(key, environment, amount, category)
    case .subscriptionPriceRise:
      return format(key, environment, amount, reference)
    case .categorySpike:
      return format(key, environment, amount, category, reference)
    case .badSpendingRise:
      return format(key, environment, amount, reference)
    case .slowReimbursement:
      // The days are a plural of their own: «ждут 31 день», «32 дня», «35 дней».
      let days = format(
        "analytics.anomaly.slowReimbursement.days", environment, count: anomaly.days ?? 0)
      return format(key, environment, amount, person, days)
    case .eventOverBudget:
      return format(key, environment, amount, event, reference)
    }
  }

  // MARK: - Periods

  /// «Сентябрь 2026», «2026», «окт. 2025 – сент. 2026».
  static func title(of period: AnalyticsPeriod, _ environment: AppEnvironment) -> String {
    switch period.kind {
    case .month:
      return environment.dates.monthTitle(period.month)
    case .year:
      return String(period.month.year)
    case .twelveMonths:
      let first = period.month.adding(months: -11)
      return "\(environment.dates.shortMonthAndYear(first)) – "
        + environment.dates.shortMonthAndYear(period.month)
    }
  }

  /// The line above the cards of a section. The forecast is the current month whatever the
  /// toolbar shows, «Качество модели» the whole history up to today; the others follow the
  /// period of the toolbar (`header`).
  static func sectionHeader(
    _ section: AnalyticsSection, title: String, model: AnalyticsModel?,
    _ environment: AppEnvironment
  ) -> String {
    let today = model?.request.today ?? environment.today
    switch section {
    case .forecast:
      return format(
        "analytics.period.currentMonth", environment,
        environment.dates.monthTitle(today.monthKey), environment.dates.dayAndMonth(today))
    case .modelQuality:
      return format(
        "analytics.period.wholeHistory", environment, environment.dates.dayAndMonth(today))
    default:
      break
    }
    guard section.plannedFor == nil, let model else { return title }
    return header(model.header, title: title, environment)
  }

  /// The line above a section: «Сентябрь 2026 · неполный, по 18 сентября · сравнение с 1–18
  /// авг.»; a completed period says what it is compared with, a future one only its title.
  static func header(
    _ header: AnalyticsHeader, title: String, _ environment: AppEnvironment
  ) -> String {
    guard header.hasStarted else { return title }
    var parts = [title]
    if !header.isComplete {
      parts.append(
        format(
          "analytics.period.incompleteThrough", environment,
          environment.dates.dayAndMonth(header.through)))
    }
    if !header.comparedWith.isEmpty {
      parts.append(
        format(
          "analytics.period.comparedWith", environment,
          environment.dates.span(header.comparedWith)))
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Figures

  /// «12,400 ₽ · 26 %»; a line without a share — a negative one — has its amount alone.
  static func amountAndShare(
    _ value: Int64, share: Int?, _ environment: AppEnvironment
  ) -> String {
    let amount = environment.money.rubles(value)
    guard let share else { return amount }
    return "\(amount) · \(environment.money.percent(basisPoints: share, fractionDigits: 0))"
  }

  /// Bars of a ranked chart from the lines of a model. A line with children opens when its
  /// key is in `expanded`; its children follow it, thinner and indented.
  static func bars(
    _ values: [RankedValue], names: AnalyticsNames, expanded: Set<ReportKey> = [],
    counts: Bool = false, _ environment: AppEnvironment
  ) -> [RankedBar] {
    var bars: [RankedBar] = []
    for value in values {
      let isOpen = expanded.contains(value.key)
      bars.append(
        bar(
          value, id: value.key.description, names: names, counts: counts,
          expandable: !value.children.isEmpty, expanded: isOpen, environment))
      guard isOpen else { continue }
      for child in value.children {
        var line = bar(
          child, id: "\(value.key.description)/\(child.key.description)", names: names,
          counts: counts, expandable: false, expanded: false, environment)
        line.isChild = true
        bars.append(line)
      }
    }
    return bars
  }

  private static func bar(
    _ value: RankedValue, id: String, names: AnalyticsNames, counts: Bool, expandable: Bool,
    expanded: Bool, _ environment: AppEnvironment
  ) -> RankedBar {
    let caption =
      counts
      ? format("analytics.purchases", environment, count: Int(clamping: value.value))
      : amountAndShare(value.value, share: value.share, environment)
    return RankedBar(
      id: id, label: name(of: value.key, names, environment), value: value.value,
      caption: caption, spokenValue: caption, isExpandable: expandable, isExpanded: expanded)
  }

  /// The words of a bucket of «по дням / неделям / месяцам»: under the column and in full.
  /// A week is the span of its days inside the period: «1–6 сент.», «7–13 сент.».
  static func bucketLabels(
    _ bucket: TimeBucket, step: TimeSeries.Step, spansYears: Bool, _ environment: AppEnvironment
  ) -> (axis: String, spoken: String) {
    let dates = environment.dates
    switch step {
    case .day:
      return (String(bucket.start.day), dates.longDay(bucket.start))
    case .week:
      let span = dates.span(DayRange(bucket.start, bucket.end))
      return (span, span)
    case .month:
      return (
        dates.shortMonth(bucket.start.monthKey, withYear: spansYears),
        dates.monthTitle(bucket.start.monthKey)
      )
    }
  }

  static func columns(
    _ series: TimeSeriesModel, _ environment: AppEnvironment
  ) -> [ChartColumn] {
    let spansYears = Set(series.buckets.map(\.start.year)).count > 1
    return series.buckets.map { bucket in
      let labels = bucketLabels(bucket, step: series.step, spansYears: spansYears, environment)
      return ChartColumn(
        id: bucket.start.iso, axisLabel: labels.axis, spokenLabel: labels.spoken,
        value: bucket.value, valueText: environment.money.rubles(bucket.value))
    }
  }

  /// The labelled columns of «по дням / неделям / месяцам» and their words, by column id.
  /// A period longer than a month — a year, twelve months — is labelled by months, as the
  /// running total is: the first column of each month by the month's name; every 37th day
  /// with no month, or a year of week spans, would name no date or crowd each other. A month:
  /// its days — the 1st, every fifth and the last — or every week and the month itself with
  /// their own words.
  static func columnTicks(
    _ series: TimeSeriesModel, _ environment: AppEnvironment
  ) -> [String: String] {
    let buckets = series.buckets
    guard let first = buckets.first, let last = buckets.last else { return [:] }
    let month = first.start.monthKey
    guard month == last.start.monthKey else {
      let spansYears = first.start.year != last.start.year
      var seen: Set<MonthKey> = []
      let firsts = buckets.filter { seen.insert($0.start.monthKey).inserted }
      return Dictionary(
        uniqueKeysWithValues: ChartAxis.thinned(firsts, limit: 12).map {
          ($0.start.iso, environment.dates.shortMonth($0.start.monthKey, withYear: spansYears))
        })
    }
    guard series.step == .day else {
      return Dictionary(
        uniqueKeysWithValues: columns(series, environment).map { ($0.id, $0.axisLabel) })
    }
    let days = Set(dayTicks(count: month.dayCount))
    return Dictionary(
      uniqueKeysWithValues: buckets.filter { days.contains($0.start.day) }.map {
        ($0.start.iso, String($0.start.day))
      })
  }

  /// The seven days from Monday; a day the period has not reached counts nothing.
  static func weekdayColumns(
    _ model: WeekdayModel, _ environment: AppEnvironment
  ) -> [ChartColumn] {
    model.days.map { day in
      let value = day.average ?? 0
      return ChartColumn(
        id: String(day.weekday), axisLabel: environment.dates.shortWeekday(day.weekday),
        spokenLabel: environment.dates.weekday(day.weekday), value: value,
        valueText: day.average.map { environment.money.rubles($0) } ?? "—")
    }
  }

  /// The ticks of a running total over a span: its days for a month or less; for a longer
  /// span the first day of each month, by its name — a year has no room for 365 numbers.
  static func spanTicks(_ span: DayRange, _ environment: AppEnvironment) -> [Int: String] {
    guard span.dayCount > 31 else {
      return Dictionary(
        uniqueKeysWithValues: dayTicks(count: span.dayCount).map { ($0, String($0)) })
    }
    let spansYears = span.start.year != span.end.year
    let firsts = span.days.enumerated().filter { $0.element.day == 1 }
    return Dictionary(
      uniqueKeysWithValues: ChartAxis.thinned(firsts, limit: 12).map { offset, day in
        (offset + 1, environment.dates.shortMonth(day.monthKey, withYear: spansYears))
      })
  }

  /// A few days of a month to write on its axis: the 1st, then every fifth, and the last.
  static func dayTicks(count: Int) -> [Int] {
    guard count > 0 else { return [] }
    var ticks = [1]
    ticks += stride(from: 5, through: count, by: 5).filter { $0 < count - 1 }
    if count > 1 { ticks.append(count) }
    return ticks
  }

  /// The segments of a quality: the symbol and the words of `Palette`.
  static func qualityStyle(_ quality: Quality, _ environment: AppEnvironment) -> SegmentStyle {
    let tint: ChartTint =
      switch quality {
      case .good: .green
      case .neutral: .secondary
      case .bad: .orange
      }
    return SegmentStyle(
      id: quality.rawValue, label: environment.language(Palette.qualityKey(quality)),
      systemImage: Palette.qualitySymbol(quality), tint: tint)
  }

  /// The segments of «paid for others»: returned in green, the shortfall in purple, written
  /// off in orange, waiting in secondary grey — each with its own symbol and words. The
  /// shortfall stands next to the waiting money, so it is never a second grey.
  static func othersStyle(_ kind: OthersSegment, _ environment: AppEnvironment) -> SegmentStyle {
    switch kind {
    case .returned:
      SegmentStyle(
        id: kind.rawValue, label: t("analytics.others.returned", environment),
        systemImage: Palette.reimbursementSymbol(.returned), tint: .green)
    case .shortfall:
      SegmentStyle(
        id: kind.rawValue, label: t("analytics.others.shortfall", environment),
        systemImage: "minus.circle", tint: .purple)
    case .writtenOff:
      SegmentStyle(
        id: kind.rawValue, label: t("analytics.others.writtenOff", environment),
        systemImage: Palette.reimbursementSymbol(.writtenOff), tint: .orange)
    case .waiting:
      SegmentStyle(
        id: kind.rawValue, label: t("analytics.others.waiting", environment),
        systemImage: Palette.reimbursementSymbol(.expected), tint: .secondary)
    }
  }

  /// Income is green and expenses are the accent — unless the owner chose green for the
  /// accent, in which case green steps aside: the two are drawn in one chart and must not
  /// come out the same colour (`ChartSeriesStyle.free`).
  static func incomeStyle(_ environment: AppEnvironment) -> SegmentStyle {
    SegmentStyle(
      id: "income", label: t("analytics.series.income", environment),
      systemImage: Palette.kindSymbol(.income),
      tint: ChartSeriesStyle.free(.green, accent: environment.theme.accent))
  }

  static func expensesStyle(_ environment: AppEnvironment) -> SegmentStyle {
    SegmentStyle(
      id: "expenses", label: t("analytics.series.expenses", environment),
      systemImage: Palette.kindSymbol(.expense), tint: .accent)
  }

  /// The name of a line of «for whom» month by month.
  static func name(of key: DynamicsKey, _ environment: AppEnvironment) -> String {
    switch key {
    case .value(let value): environment.label(for: value)
    case .others: t("analytics.series.others", environment)
    }
  }

  /// The lines of «for whom» month by month: each told apart by its value, never by its
  /// words — two values named alike in the Settings stay two lines — and named at its end;
  /// the amounts are on the points, in the hover callout and for VoiceOver.
  static func dynamicsLines(
    _ model: DynamicsModel, _ environment: AppEnvironment
  ) -> [ChartLineSeries] {
    model.series.map { line in
      let label = name(of: line.key, environment)
      return ChartLineSeries(
        id: line.key.id, label: label,
        style: ChartSeriesStyle.series(line.styleIndex, accent: environment.theme.accent),
        points: line.points.enumerated().map { index, value in
          ChartLinePoint(
            x: index,
            value: value,
            spokenLabel: environment.dates.monthTitle(model.months[index]),
            valueText: environment.money.rubles(value))
        },
        endText: label)
    }
  }

  /// The change of spending or income under the comparison chart: «+1,200 ₽ · +8 %»; with
  /// nothing in the period before, the difference and which period had nothing — the month,
  /// the year or the twelve months before, never «last month» for a year.
  static func changeWords(
    _ change: Change, period: Period, _ environment: AppEnvironment
  ) -> String {
    let text = environment.money.change(change)
    if let percent = text.percent { return "\(text.delta) · \(percent)" }
    let before: String
    switch period.kind {
    case .month: before = "month"
    case .year: before = "year"
    case .twelveMonths: before = "twelveMonths"
    case .days: before = "period"
    }
    return format("analytics.change.noBase.\(before)", environment, text.delta)
  }
}
