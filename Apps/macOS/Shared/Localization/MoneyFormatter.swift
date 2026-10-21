import AppCore
import Foundation

/// Formats amounts for the interface. Totals, reports and charts are rounded to whole
/// rubles, half up; operation lists show the exact amount.
///
/// The numbers are written the same way in every language — a comma between the thousands,
/// a point before the fraction, «1,234.50 ₽» (`NumberText`) — so a figure read in one
/// language is the figure typed in the other. Only the words around a number follow the
/// language: «млн» or «M», and the space before «%» that Russian writes.
///
/// With `hidesAmounts` («Скрыть суммы», `AmountPrivacy`) every figure of money — exact, rounded,
/// signed, on an axis — is written as `mask`; counts, percents, rates and plain numbers are not
/// money and stay as they are: a share or a change in percent does not tell how much there is,
/// and a plain number is what the entry line is given back to edit.
///
/// `currencyStyle` (Settings → Appearance → «Валюта») names the currency after the number —
/// «1,250 ₽», «1,250 RUB», «1,250 руб.» — in every amount written here; `symbol(for:)` stays the
/// sign itself, for the unit beside a field where an amount is typed.
public struct MoneyFormatter: Sendable {
  private let locale: Locale
  /// The figures of money are hidden behind `mask`.
  public let hidesAmounts: Bool
  /// How an amount names its currency.
  public let currencyStyle: CurrencyStyle
  /// The custom currencies (USDT, points…): their symbols and names are the owner's.
  public let catalog: CurrencyCatalog

  /// What stands in place of a hidden amount, its sign and its currency included: one width
  /// everywhere, so neither the length of a figure nor its sign is left to read.
  public static let mask = "•••"

  public init(
    locale: Locale, hidesAmounts: Bool = false, currencyStyle: CurrencyStyle = .symbol,
    catalog: CurrencyCatalog = .empty
  ) {
    self.locale = locale
    self.hidesAmounts = hidesAmounts
    self.currencyStyle = currencyStyle
    self.catalog = catalog
  }

  private var isRussian: Bool { locale.language.languageCode?.identifier == "ru" }

  /// The exact amount of a list: a whole amount without a fraction, anything else
  /// with at least the two digits of kopecks and up to the four of E4 — «250 ₽», «1,234.50 ₽»,
  /// «4.625 ₽».
  public func exact(_ amount: AmountE4, currency: CurrencyCode = .rub) -> String {
    if hidesAmounts { return Self.mask }
    return "\(NumberText.amount(amount))\u{00A0}\(unit(for: currency))"
  }

  /// Rounded to whole units, half away from zero — the form used by totals and charts.
  public func rounded(_ amount: AmountE4, currency: CurrencyCode = .rub) -> String {
    if hidesAmounts { return Self.mask }
    return wholeText(DecimalMath.round(amount.decimal, scale: 0), currency)
  }

  /// Whole rubles a chart plots, as the same words as `rounded`: «12,400 ₽». The value is
  /// rounded already (`AmountE4.wholeRubles`), so nothing here rounds again, and it is written
  /// from the number itself: the largest whole rubles have no E4 to go back to.
  public func rubles(_ whole: Int64) -> String {
    if hidesAmounts { return Self.mask }
    return "\(NumberText.integer(whole))\u{00A0}\(unit(for: .rub))"
  }

  /// Whole rubles of a chart with their sign, as `signedRounded` writes a difference:
  /// «+3,400 ₽», «−1,200 ₽», «0 ₽».
  public func signedRubles(_ whole: Int64) -> String {
    if hidesAmounts { return Self.mask }
    let value = Decimal(whole)
    return Self.sign(of: value) + wholeText(value < 0 ? -value : value, .rub)
  }

  /// A figure rounded to whole units already, its thousands grouped.
  private func wholeText(_ whole: Decimal, _ currency: CurrencyCode) -> String {
    "\(NumberText.decimal(whole, fractionDigits: 0...0))\u{00A0}\(unit(for: currency))"
  }

  /// A label of a money axis: whole rubles below a million, from a million the compact form
  /// with one decimal and the word of the language — «1.2 млн ₽», «1.2M ₽». The figure is
  /// rounded half away from zero like every other amount, and the unit is chosen by the rounded
  /// figure: 999 950 000 is «1 млрд ₽», not «1,000 млн ₽».
  public func axis(_ whole: Int64) -> String {
    if hidesAmounts { return Self.mask }
    guard whole.magnitude >= 1_000_000 else { return rubles(whole) }
    let inMillions = DecimalMath.round(Decimal(whole) / 1_000_000, scale: 1)
    let billions = inMillions >= 1_000 || inMillions <= -1_000
    let scaled =
      billions ? DecimalMath.round(Decimal(whole) / 1_000_000_000, scale: 1) : inMillions
    let number = NumberText.decimal(scaled, fractionDigits: 0...1)
    let suffix =
      isRussian ? (billions ? "\u{00A0}млрд" : "\u{00A0}млн") : (billions ? "B" : "M")
    return "\(number)\(suffix)\u{00A0}\(unit(for: .rub))"
  }

  /// A whole number with its thousands grouped: «1,250» — counts on a chart.
  public func count(_ value: Int64) -> String {
    NumberText.integer(value)
  }

  /// A rate of exchange or of interest, up to four decimals: «83.125», «81.4321», «12.5».
  public func rate(_ value: Decimal) -> String {
    NumberText.decimal(value, fractionDigits: 0...4)
  }

  /// A plain number in the one way numbers are written, rounded to at most
  /// `fractionDigits.upperBound` digits: a share of a debt, «0.5».
  public func number(_ value: Decimal, fractionDigits: ClosedRange<Int> = 0...4) -> String {
    NumberText.decimal(value, fractionDigits: fractionDigits)
  }

  /// A difference in whole units with its sign: «+3,400 ₽», «−1,200 ₽», «0 ₽». The sign is
  /// that of the rounded amount, so −0.40 ₽ reads «0 ₽» rather than «−0 ₽». The minus is the
  /// typographic one (U+2212), as in the rest of the interface.
  public func signedRounded(_ amount: AmountE4, currency: CurrencyCode = .rub) -> String {
    if hidesAmounts { return Self.mask }
    let whole = DecimalMath.round(amount.decimal, scale: 0)
    return Self.sign(of: whole) + rounded(amount.magnitude, currency: currency)
  }

  /// Basis points as a percent, rounded half away from zero to `fractionDigits`: 3 333 bp
  /// is «33.3 %» in Russian and «33.3%» in English. A share of a card, of a report line.
  public func percent(basisPoints: Int, fractionDigits: Int = 1) -> String {
    percentText(Self.percent(of: basisPoints, fractionDigits: fractionDigits), fractionDigits)
  }

  /// A cashback percent exactly as kept, up to its four decimals: «1.5 %», «10 %» in Russian,
  /// «1.5%» in English.
  public func percent(_ percent: CashbackPercent) -> String {
    let number = NumberText.decimal(percent.decimal, fractionDigits: 0...4)
    return isRussian ? "\(number)\u{00A0}%" : "\(number)%"
  }

  /// A change in basis points with its sign: «+8.3 %», «−53.4 %», «0.0 %». As with money,
  /// the sign is that of the rounded figure.
  public func signedPercent(basisPoints: Int, fractionDigits: Int = 1) -> String {
    let value = Self.percent(of: basisPoints, fractionDigits: fractionDigits)
    return Self.sign(of: value) + percentText(value < 0 ? -value : value, fractionDigits)
  }

  /// A change against an earlier figure, as the cards say it: which way it went, the
  /// difference in whole rubles and — only when there was something to compare with — in
  /// percent. With nothing the period before, there is no percent at all: the card says
  /// «no data last month» and shows the rubles alone.
  public func change(_ change: Change) -> ChangeText {
    let whole = DecimalMath.round(change.delta.decimal, scale: 0)
    return ChangeText(
      direction: whole > 0 ? .up : whole < 0 ? .down : .flat,
      delta: signedRounded(change.delta),
      percent: change.basisPoints.map { signedPercent(basisPoints: $0) })
  }

  private static func percent(of basisPoints: Int, fractionDigits: Int) -> Decimal {
    DecimalMath.round(Decimal(basisPoints) / 100, scale: fractionDigits)
  }

  private static func sign(of value: Decimal) -> String {
    value > 0 ? "+" : value < 0 ? NumberText.minus : ""
  }

  /// The number is rounded already; the language only decides the space before «%»: Russian
  /// writes one, English does not.
  private func percentText(_ percent: Decimal, _ fractionDigits: Int) -> String {
    let digits = max(0, fractionDigits)
    let number = NumberText.decimal(percent, fractionDigits: digits...digits)
    return isRussian ? "\(number)\u{00A0}%" : "\(number)%"
  }

  /// The sign of a currency — «₽», «$» —, whatever the style: the unit beside a field where an
  /// amount is typed, and the list of currencies in Settings.
  /// A custom currency's sign is the owner's, its code when it has none.
  public func symbol(for currency: CurrencyCode) -> String {
    catalog.symbol(currency) ?? CurrencyStyle.symbol(for: currency)
  }

  /// What follows the number of an amount, in the style chosen: «₽», «RUB» or «руб.». A custom
  /// currency is written by the owner's symbol (its code when it has none), by its code, or by
  /// the owner's name — in Russian; English writes the code for a name, as for every currency.
  public func unit(for currency: CurrencyCode) -> String {
    guard catalog.isCustom(currency) else {
      return currencyStyle.unit(for: currency, russian: isRussian)
    }
    switch currencyStyle {
    case .symbol: return catalog.symbol(currency) ?? currency.code
    case .code: return currency.code
    case .name:
      let language = isRussian ? "ru" : "en"
      return isRussian ? catalog.name(currency, language: language) ?? currency.code : currency.code
    }
  }
}

/// Which way a figure moved against the period it is compared with. Told by a symbol and by
/// the sign of the number, never by colour: more spending is not always bad.
public enum ChangeDirection: Sendable {
  case up, down, flat
}

/// The words of a change: the difference in rubles, and the percent when there is a base.
public struct ChangeText: Hashable, Sendable {
  public var direction: ChangeDirection
  /// «+3,400 ₽».
  public var delta: String
  /// «+8.3 %»; `nil` when the earlier figure was zero.
  public var percent: String?
}

/// Dates and times shown in the interface follow the chosen interface language.
public struct DateFormatting: Sendable {
  private let locale: Locale
  private let calendar: CalendarContext

  public init(locale: Locale, calendar: CalendarContext) {
    self.locale = locale
    self.calendar = calendar
  }

  public func dayTitle(_ day: DateOnly, today: DateOnly, language: AppLanguageStrings) -> String {
    if day == today { return language.today }
    if day == calendar.adding(days: -1, to: today) { return language.yesterday }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
    return formatter.string(from: calendar.startOfDay(day)).capitalizedFirst
  }

  public func time(_ instant: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("HH:mm")
    return formatter.string(from: instant)
  }

  /// A day with its month and year: «18 сентября 2026 г.», «September 18, 2026».
  public func longDay(_ day: DateOnly) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("d MMMM y")
    return formatter.string(from: calendar.startOfDay(day))
  }

  /// A span of days, as short as the language allows: «1–18 авг.», «Aug 1 – 18».
  public func span(_ range: DayRange) -> String {
    let formatter = DateIntervalFormatter()
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.locale = locale
    gregorian.timeZone = calendar.timeZone
    formatter.calendar = gregorian
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.dateTemplate = "d MMM"
    return formatter.string(
      from: calendar.startOfDay(range.start), to: calendar.startOfDay(range.end))
  }

  /// A day and a time: «17 сент., 14:32».
  public func moment(_ instant: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
    return formatter.string(from: instant)
  }

  /// A day with its month: «18 сентября», «September 18».
  public func dayAndMonth(_ day: DateOnly) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("d MMMM")
    return formatter.string(from: calendar.startOfDay(day))
  }

  /// A month as a title: «Сентябрь 2026», «September 2026». Built from the standalone name,
  /// so Russian gets the nominative and no «г.».
  public func monthTitle(_ month: MonthKey) -> String {
    let names = symbols.standaloneMonthSymbols ?? []
    let name = month.month - 1 < names.count ? names[month.month - 1] : month.iso
    return "\(name.capitalizedFirst) \(month.year)"
  }

  /// The key of a month in the prepositional case in Common — `month.in.9`: «в сентябре»,
  /// «in September». No formatter gives that case; the catalog does.
  public static func monthInKey(_ month: MonthKey) -> String { "month.in.\(month.month)" }

  /// A month as «только в сентябре» needs it: `words` are the words of `monthInKey` in the
  /// language of the interface, and the year follows them when it is not `thisYear` — «в
  /// сентябре 2027», «in September 2027».
  public func monthIn(_ month: MonthKey, thisYear: Int, words: String) -> String {
    month.year == thisYear ? words : "\(words) \(month.year)"
  }

  /// A month on an axis: «сент.», «Sep»; with its year when a chart spans two: «сент. 26».
  public func shortMonth(_ month: MonthKey, withYear: Bool = false) -> String {
    let names = symbols.shortStandaloneMonthSymbols ?? []
    let name = month.month - 1 < names.count ? names[month.month - 1] : month.iso
    return withYear ? "\(name) \(String(format: "%02d", month.year % 100))" : name
  }

  /// A month with its full year, short: «окт. 2025», «Oct 2025» — the ends of twelve months.
  public func shortMonthAndYear(_ month: MonthKey) -> String {
    let names = symbols.shortStandaloneMonthSymbols ?? []
    let name = month.month - 1 < names.count ? names[month.month - 1] : month.iso
    return "\(name) \(month.year)"
  }

  /// A day of the week on an axis, 1 = Monday … 7 = Sunday: «Пн», «Mon».
  public func shortWeekday(_ weekday: Int) -> String {
    weekdayName(weekday, from: symbols.shortStandaloneWeekdaySymbols ?? [])
  }

  /// The same day in full, for VoiceOver: «понедельник», «Monday».
  public func weekday(_ weekday: Int) -> String {
    weekdayName(weekday, from: symbols.standaloneWeekdaySymbols ?? [])
  }

  /// The system lists weekdays from Sunday; the app counts them from Monday.
  private func weekdayName(_ weekday: Int, from names: [String]) -> String {
    let index = weekday % 7
    return index < names.count ? names[index] : "\(weekday)"
  }

  /// The names of months and weekdays in the language of the interface.
  private var symbols: DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    return formatter
  }
}

/// The two day names the list needs, passed in so formatting stays free of the UI layer.
public struct AppLanguageStrings: Sendable {
  public let today: String
  public let yesterday: String

  public init(today: String, yesterday: String) {
    self.today = today
    self.yesterday = yesterday
  }
}

extension String {
  fileprivate var capitalizedFirst: String {
    guard let first else { return self }
    return String(first).uppercased() + dropFirst()
  }
}
