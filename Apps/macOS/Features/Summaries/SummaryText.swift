import AppCore
import Foundation

/// The names a summary refers to by id: categories and places, as they are written today.
struct SummaryNames: Sendable {
  var categories: [UUID: String] = [:]
  var places: [UUID: String] = [:]

  init(categories: [UUID: String] = [:], places: [UUID: String] = [:]) {
    self.categories = categories
    self.places = places
  }

  init(dataset: Dataset) {
    categories = Dictionary(
      dataset.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    places = Dictionary(
      dataset.places.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }
}

/// Puts the lines of the cards of «Итоги» into words: the core names a line by a key and hands
/// over its values, this finds the sentence in the catalog `Summaries` and fills it in.
///
/// Money is written by `money`; the PDF with amounts of an owner who hides them builds its own
/// formatter that does not mask, while a card on the screen uses the one of the interface.
@MainActor
struct SummaryText {
  let language: AppLanguage
  let money: MoneyFormatter
  let dates: DateFormatting
  let names: SummaryNames

  static let table = "Summaries"

  /// Keys whose weekday stands as a name («Самый дорогой день — среда»), not as «в среду».
  private static let nominativeWeekday: Set<String> = ["summaries.line.dearestDayOnly", "summaries.line.dearestDay"]
  /// Keys whose month stands as a name («Лучший месяц — март»), not as «сентября».
  private static let nominativeMonth: Set<String> = ["summaries.line.bestMonth"]

  /// The words of the interface: its language, its money, its dates.
  init(environment: AppEnvironment, names: SummaryNames, money: MoneyFormatter? = nil) {
    language = environment.language
    self.money = money ?? environment.money
    dates = environment.dates
    self.names = names
  }

  init(language: AppLanguage, money: MoneyFormatter, dates: DateFormatting, names: SummaryNames) {
    self.language = language
    self.money = money
    self.dates = dates
    self.names = names
  }

  func text(_ line: SummaryLine) -> String {
    let format = language(line.key, table: Self.table)
    let values = line.args.map { argument($0, in: line.key) }
    return String(format: format, locale: language.locale, arguments: values)
  }

  func title(_ card: SummaryCard) -> String { text(card.title) }

  func lines(_ card: SummaryCard) -> [String] { card.lines.map(text) }

  private func argument(_ value: SummaryArg, in key: String) -> CVarArg {
    switch value {
    case .money(let amount):
      return money.rounded(amount)
    case .percent(let percent):
      return money.percent(basisPoints: percent * 100, fractionDigits: 0)
    case .count(let count):
      return NumberText.integer(Int64(count))
    case .tenths(let tenths):
      let separator = language.locale.decimalSeparator ?? "."
      return "\(tenths / 10)\(separator)\(tenths % 10)"
    case .weekday(let weekday):
      if Self.nominativeWeekday.contains(key) { let name = dates.weekday(weekday)
        return name.prefix(1).uppercased() + name.dropFirst() }
      return language("summaries.weekday.in.\(weekday)", table: Self.table)
    case .month(let month):
      if Self.nominativeMonth.contains(key) { return dates.monthTitle(month) }
      return "\(language("summaries.month.of.\(month.month)", table: Self.table)) \(month.year)"
    case .year(let year):
      return String(year)
    case .day(let day):
      return dates.dayAndMonth(day)
    case .category(let id):
      return names.categories[id] ?? language("summaries.unknown", table: Self.table)
    case .place(let id):
      return names.places[id] ?? language("summaries.unknown", table: Self.table)
    case .timeOfDay(let bucket):
      return language("summaries.time.\(bucket.rawValue)", table: Self.table)
    case .name(let text):
      return text
    }
  }
}
