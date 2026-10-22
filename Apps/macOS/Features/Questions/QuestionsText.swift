import AppCore
import Foundation

/// The words of the question line, the answer card, the command palette and the saved views.
/// One lookup helper of one table, so every key can be checked against its catalogue.
@MainActor
enum QuestionsText {
  static let table = "Questions"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  /// A string with one count in it: «1,250 операций».
  static func count(_ key: String, _ environment: AppEnvironment, _ count: Int) -> String {
    environment.language.format(key, table: table, counts: count)
  }

  // MARK: Periods

  /// «Сентябрь 2026», «2026», «окт. 2025 – сент. 2026», «1 сентября – 18 сентября».
  static func title(of period: Period, _ environment: AppEnvironment) -> String {
    switch period.kind {
    case .month(let month): return environment.dates.monthTitle(month)
    case .year(let year): return String(year)
    case .twelveMonths(let last):
      return "\(environment.dates.shortMonthAndYear(last.adding(months: -11))) – "
        + environment.dates.shortMonthAndYear(last)
    case .days:
      let range = period.range
      if range.start == range.end { return environment.dates.longDay(range.start) }
      return "\(environment.dates.dayAndMonth(range.start)) – "
        + environment.dates.dayAndMonth(range.end)
    }
  }

  /// The words of a period on a link or in a menu. The ones the answer offers when the
  /// question named none have words of their own; the rest are named by their days.
  static func title(
    of period: RelativePeriod, today: DateOnly, _ environment: AppEnvironment
  ) -> String {
    switch period {
    case .thisMonth: return t("questions.period.thisMonth", environment)
    case .lastMonth: return t("questions.period.lastMonth", environment)
    case .thisYear: return t("questions.period.thisYear", environment)
    case .lastYear: return t("questions.period.lastYear", environment)
    case .lastDays(30): return t("questions.period.last30", environment)
    case .thisWeek: return t("questions.period.thisWeek", environment)
    case .lastWeek: return t("questions.period.lastWeek", environment)
    case .today: return t("questions.period.today", environment)
    case .yesterday: return t("questions.period.yesterday", environment)
    default: return title(of: period.period(today: today), environment)
    }
  }

  /// The periods a question can be moved to from the card.
  static let choosablePeriods: [RelativePeriod] = [
    .thisMonth, .lastMonth, .lastDays(30), .thisYear, .lastYear,
  ]

  // MARK: What a term stands for

  /// «категория «Такси»», «место «Пятёрочка»», «слово «такси» в описаниях».
  static func label(of subject: QuestionSubject, _ environment: AppEnvironment) -> String {
    switch subject {
    case .category(_, let name): return format("questions.subject.category", environment, name)
    case .subcategory(_, let name, _):
      return format("questions.subject.subcategory", environment, name)
    case .place(_, let name): return format("questions.subject.place", environment, name)
    case .person(_, let name): return format("questions.subject.person", environment, name)
    case .event(_, let name): return format("questions.subject.event", environment, name)
    case .paymentMethod(_, let name):
      return format("questions.subject.paymentMethod", environment, name)
    case .text(let text): return format("questions.subject.text", environment, text)
    }
  }

  static func symbol(of subject: QuestionSubject) -> String {
    switch subject {
    case .category, .subcategory: "tag"
    case .place: "mappin.and.ellipse"
    case .person: "person"
    case .event: "calendar"
    case .paymentMethod: "creditcard"
    case .text: "text.magnifyingglass"
    }
  }

  static func name(
    of intent: QuestionIntent, measure: QuestionMeasure, _ environment: AppEnvironment
  )
    -> String
  {
    let key: String
    switch (intent, measure) {
    case (.howMuch, .spending): key = "questions.intent.howMuch.spending"
    case (.howMuch, .income): key = "questions.intent.howMuch.income"
    case (.compare, .spending): key = "questions.intent.compare.spending"
    case (.compare, .income): key = "questions.intent.compare.income"
    case (.whatGrew, .spending): key = "questions.intent.whatGrew.spending"
    case (.whatGrew, .income): key = "questions.intent.whatGrew.income"
    case (.biggest, .spending): key = "questions.intent.biggest.spending"
    case (.biggest, .income): key = "questions.intent.biggest.income"
    }
    return t(key, environment)
  }

  // MARK: Palette

  /// The title of a line of the palette: the key of the entry, with the name of the thing it
  /// opens in it when it has one.
  static func title(of entry: PaletteEntry, _ environment: AppEnvironment) -> String {
    let text = t(entry.titleKey, environment)
    guard let argument = entry.argument else { return text }
    return String(format: text, locale: environment.language.locale, argument)
  }

  static func symbol(of entry: PaletteEntry) -> String {
    switch entry.kind {
    case .command: "command"
    case .screen: "rectangle.on.rectangle"
    case .account: "building.columns"
    case .debt: "creditcard"
    case .goal: "target"
    case .category: "tag"
    case .person: "person"
    }
  }

  static func kindName(_ kind: PaletteKind, _ environment: AppEnvironment) -> String {
    t("questions.palette.kind.\(kind.rawValue)", environment)
  }
}
