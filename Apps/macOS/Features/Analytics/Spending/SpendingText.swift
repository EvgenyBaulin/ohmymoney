import AppCore
import Foundation

/// The words and small rules of the spending sections of Analytics, apart from the views so a
/// test reads them in both languages.
@MainActor
enum SpendingText {
  static let table = "Spending"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(format: t(key, environment), locale: environment.language.locale, arguments: arguments)
  }

  static func counted(_ key: String, _ environment: AppEnvironment, count: Int) -> String {
    environment.language.format(key, table: table, counts: count)
  }

  static func counted(_ key: String, _ environment: AppEnvironment, counts: Int...) -> String {
    environment.language.counted(key, table: table, counts)
  }

  // MARK: - Names

  static func name(
    of pair: ComparisonPairKind, _ environment: AppEnvironment
  ) -> String {
    t("spending.cmp.pair.\(pair.rawValue)", environment)
  }

  static func name(of dimension: ComparisonDimension, _ environment: AppEnvironment) -> String {
    t("spending.cmp.dimension.\(dimension.rawValue)", environment)
  }

  static func name(of choice: ComparisonChoice, _ environment: AppEnvironment) -> String {
    t("spending.cmp.choice.\(choice.rawValue)", environment)
  }

  static func name(of grouping: LeakGrouping, _ environment: AppEnvironment) -> String {
    t("spending.leaks.grouping.\(grouping.rawValue)", environment)
  }

  /// «Пятница 18:00».
  static func weekdayAndTime(
    _ weekday: Int, _ time: TimeOfDay, _ environment: AppEnvironment
  ) -> String {
    "\(environment.dates.weekday(weekday)) \(clock(time))"
  }

  static func clock(_ time: TimeOfDay) -> String {
    String(format: "%02d:%02d", time.hour, time.minute)
  }

  /// The weekend of the settings in a line: «пятница 18:00 — воскресенье 23:59».
  static func windowLine(_ window: WeekendWindow, _ environment: AppEnvironment) -> String {
    "\(weekdayAndTime(window.startWeekday, window.start, environment)) — "
      + "\(weekdayAndTime(window.endWeekday, window.end, environment))"
  }

  // MARK: - Comparison

  /// The period of a comparison for a heading: a whole month by its title, a whole quarter,
  /// any other span as «1 сент. – 14 сент.».
  static func title(of range: DayRange, _ environment: AppEnvironment) -> String {
    let month = range.start.monthKey
    if range.start.day == 1 && range.end == month.lastDay {
      return environment.dates.shortMonthAndYear(month)
    }
    if range.start.day == 1, (range.start.month - 1) % 3 == 0,
      range.end == month.adding(months: 2).lastDay
    {
      return format(
        "spending.cmp.quarter", environment, (range.start.month - 1) / 3 + 1, range.start.year)
    }
    return
      "\(environment.dates.dayAndMonth(range.start)) – \(environment.dates.dayAndMonth(range.end))"
  }

  /// «в среднем за день, периоды разной длины» — exactly when the app switched to the average
  /// day by itself; «в среднем за день» when the owner chose it; nothing for totals.
  static func measureNote(
    _ comparison: SpendingComparison, _ environment: AppEnvironment
  ) -> String? {
    if comparison.showsDifferentLengthNote {
      return t("spending.cmp.note.differentLength", environment)
    }
    return comparison.measure == .perDay ? t("spending.cmp.note.perDay", environment) : nil
  }

  /// The change of a line: «+12 400 ₽ · +20 %»; with no figure before, only the difference.
  static func change(_ row: ComparisonRow, _ environment: AppEnvironment) -> String {
    let money = environment.money
    let delta = money.signedRounded(row.delta)
    guard let points = row.changeBasisPoints else { return delta }
    return "\(delta) · \(money.signedPercent(basisPoints: points, fractionDigits: 0))"
  }

  /// The symbol of a change, so its direction never rests on a colour or a sign alone.
  static func symbol(of row: ComparisonRow) -> String {
    row.delta.raw > 0 ? "arrow.up.right" : row.delta.raw < 0 ? "arrow.down.right" : "equal"
  }

  /// One line of «Я год назад»: «Такси: на 20 % меньше».
  static func yearAgoLine(
    _ row: ComparisonRow, name: String, _ environment: AppEnvironment
  ) -> String? {
    guard let points = row.changeBasisPoints else { return nil }
    let size = environment.money.percent(basisPoints: abs(points), fractionDigits: 0)
    let key =
      points > 0
      ? "spending.yearAgo.more" : points < 0 ? "spending.yearAgo.less" : "spending.yearAgo.same"
    return format(key, environment, name, size)
  }

  /// «Мало данных: история с марта 2026».
  static func yearAgoNoData(historyStart: MonthKey?, _ environment: AppEnvironment) -> String {
    guard let historyStart else { return t("spending.yearAgo.noHistory", environment) }
    return format(
      "spending.yearAgo.noData", environment, environment.dates.shortMonthAndYear(historyStart))
  }

  // MARK: - Places and habits

  /// «У 12 % операций нет места», or nothing when every operation has one.
  static func withoutPlaceHint(_ places: FavoritePlaces, _ environment: AppEnvironment) -> String? {
    guard let percent = places.withoutPlacePercent, percent > 0 else { return nil }
    return format("spending.places.withoutPlace", environment, percent)
  }

  // MARK: - Leaks and limits

  /// «Кофе до 300 ₽ · 22 раза · 5 900 ₽ в месяц».
  static func leakLine(
    _ leak: SpendingLeaks.Leak, name: String, _ environment: AppEnvironment
  ) -> String {
    leakLine(
      name: name, largest: leak.largest, count: leak.count, perMonth: leak.perMonth, environment)
  }

  static func leakLine(
    name: String, largest: AmountE4, count: Int, perMonth: AmountE4, _ environment: AppEnvironment
  ) -> String {
    let money = environment.money
    return format(
      "spending.leaks.line", environment, name, money.rounded(largest),
      counted("spending.leaks.times", environment, count: count), money.rounded(perMonth))
  }

  /// «и ещё 14 покупок до 500 ₽ — 3 100 ₽».
  static func othersLine(
    _ consumption: LimitConsumption, _ environment: AppEnvironment
  ) -> String? {
    guard consumption.othersCount > 0, let largest = consumption.othersLargest else { return nil }
    let money = environment.money
    return format(
      "spending.limit.others", environment,
      counted("spending.limit.othersCount", environment, count: consumption.othersCount),
      money.rounded(largest), money.rounded(consumption.othersTotal))
  }

  // MARK: - Price in hours

  /// «18 часов вашей работы».
  static func hoursLine(_ rate: WorkRate, price: AmountE4, _ environment: AppEnvironment) -> String
  {
    counted("spending.hours.price", environment, count: rate.wholeHours(for: price))
  }

  // MARK: - Every key

  /// Every key the views read from the Spending catalog; a test holds them to both languages.
  static let keys: [String] = [
      "spending.cmp.baseline", "spending.cmp.basis", "spending.cmp.change", "spending.cmp.choice",
      "spending.cmp.choice.automatic", "spending.cmp.choice.perDay", "spending.cmp.choice.totals",
      "spending.cmp.current", "spending.cmp.custom.baseline", "spending.cmp.custom.current",
      "spending.cmp.dimension", "spending.cmp.dimension.category", "spending.cmp.dimension.person",
      "spending.cmp.dimension.place", "spending.cmp.empty", "spending.cmp.event",
      "spending.cmp.export", "spending.cmp.exportFailed", "spending.cmp.from",
      "spending.cmp.measure.perDay", "spending.cmp.measure.totals", "spending.cmp.noEvent",
      "spending.cmp.note.differentLength", "spending.cmp.note.perDay", "spending.cmp.pair",
      "spending.cmp.pair.custom", "spending.cmp.pair.eventToUsualMonth",
      "spending.cmp.pair.monthToPreviousMonth", "spending.cmp.pair.monthToSameMonthLastYear",
      "spending.cmp.pair.quarterToPreviousQuarter",
      "spending.cmp.pair.quarterToSameQuarterLastYear", "spending.cmp.quarter",
      "spending.cmp.title", "spending.cmp.to", "spending.habits.basis", "spending.habits.empty",
      "spending.habits.line", "spending.habits.title", "spending.heat.basis",
      "spending.heat.busiest", "spending.heat.cell", "spending.heat.empty", "spending.heat.legend",
      "spending.heat.less", "spending.heat.more", "spending.heat.title", "spending.hours.amount",
      "spending.hours.basis", "spending.hours.noIncome", "spending.hours.off",
      "spending.hours.rate", "spending.hours.title", "spending.leaks.basis", "spending.leaks.empty",
      "spending.leaks.grouping", "spending.leaks.grouping.category",
      "spending.leaks.grouping.place", "spending.leaks.line", "spending.leaks.title",
      "spending.limit.basis", "spending.limit.category", "spending.limit.empty",
      "spending.limit.others", "spending.limit.spent", "spending.limit.title", "spending.oneOff",
      "spending.oneOff.hint", "spending.oneOff.mark", "spending.oneOff.splitHint",
      "spending.oneOff.unmark", "spending.people.basis", "spending.people.empty",
      "spending.people.title", "spending.people.total", "spending.places.basis",
      "spending.places.byAmount", "spending.places.byVisits", "spending.places.empty",
      "spending.places.noneToSet", "spending.places.setFromNote",
      "spending.places.setFromNote.rule", "spending.places.setPlaces", "spending.places.title",
      "spending.places.withoutPlace", "spending.receipt.basis", "spending.receipt.noChart",
      "spending.receipt.place", "spending.receipt.title", "spending.settings.hours.enabled",
      "spending.settings.hours.hint", "spending.settings.title", "spending.settings.weekend",
      "spending.settings.weekend.from", "spending.settings.weekend.hint",
      "spending.settings.weekend.reset", "spending.settings.weekend.to",
      "spending.tile.usual.lowData", "spending.tile.usual.weekdays", "spending.tile.usual.weekends",
      "spending.tile.weekend.none", "spending.tile.weekend.previous", "spending.tile.weekend.share",
      "spending.usual.basis", "spending.usual.low", "spending.usual.overall",
      "spending.usual.title", "spending.usual.weekdays", "spending.usual.weekends",
      "spending.weekend.basis", "spending.weekend.empty", "spending.weekend.excludeOneOff",
      "spending.weekend.month", "spending.weekend.share", "spending.weekend.title",
      "spending.weekend.weekdays", "spending.weekend.weekend", "spending.yearAgo.basis",
      "spending.yearAgo.less", "spending.yearAgo.more", "spending.yearAgo.noData",
      "spending.yearAgo.noHistory", "spending.yearAgo.same", "spending.yearAgo.title",
  ]

  /// The keys that carry a number and so need the plural forms of both languages.
  static let countedKeys: [String] = [
      "spending.heat.withoutTime", "spending.hours.price", "spending.leaks.times",
      "spending.limit.othersCount", "spending.places.operations", "spending.places.visits",
      "spending.settings.hours.perMonth",
  ]

  /// The keys of the breakdowns «Почему так» that the core names in this catalog.
  static let breakdownKeys: [String] = [
      "why.usualDay.basis", "why.usualDay.days", "why.usualDay.none", "why.usualDay.overall",
      "why.usualDay.weekdays", "why.usualDay.weekends", "why.weekend.all", "why.weekend.none",
      "why.weekend.previous", "why.weekend.total", "why.weekend.weekdays", "why.weekend.weekend",
      "why.weekend.window",
  ]
}
