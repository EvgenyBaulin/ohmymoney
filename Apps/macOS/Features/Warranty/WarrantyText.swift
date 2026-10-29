import AppCore
import Foundation

/// Words for warranties and return terms: the lines of «Стоит посмотреть», the hint under the entry
/// line, the quick choices of the fields and the rows of the list. The core hands over days and
/// ids; the sentences are the catalog's (`Warranty`, and `Overview` for the lines of the card).
@MainActor
enum WarrantyText {
  nonisolated static let table = "Warranty"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func f(_ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...) -> String {
    String(
      format: t(key, environment), locale: environment.language.locale, arguments: arguments)
  }

  /// Every key of the catalog the screens use, so a test finds each in both languages.
  nonisolated static let keys = [
    "warranty.title", "warranty.subtitle", "warranty.search", "warranty.empty",
    "warranty.empty.hint", "warranty.nothingFound", "warranty.section.running",
    "warranty.section.ended", "warranty.field.until", "warranty.field.place",
    "warranty.field.place.prompt", "warranty.field.return", "warranty.pick", "warranty.clear",
    "warranty.preset.years", "warranty.preset.days", "warranty.line.until",
    "warranty.line.return", "warranty.row.until", "warranty.row.return", "warranty.row.place",
    "warranty.left", "warranty.today", "warranty.over", "warranty.untitled", "warranty.open",
    "warranty.button",
  ]

  /// The keys of the lines of «Стоит посмотреть» about warranties (table `Overview`).
  nonisolated static let noteKeys = [
    "look.warranty.returnEnds", "look.warranty.returnToday", "look.warranty.ends",
    "look.warranty.endsToday", "look.warranty.place",
  ]

  /// «+2 года», «+14 дней»: a quick choice next to a field. Presets are years and days; another
  /// unit is told in days.
  static func preset(_ term: TermReading, _ environment: AppEnvironment) -> String {
    switch term.unit {
    case .year:
      return environment.language.format("warranty.preset.years", table: table, counts: term.count)
    case .day:
      return environment.language.format("warranty.preset.days", table: table, counts: term.count)
    case .week:
      return environment.language.format(
        "warranty.preset.days", table: table, counts: term.count * 7)
    case .month:
      return environment.language.format(
        "warranty.preset.days", table: table, counts: term.count * 30)
    }
  }

  /// What the purchase is called: its note, or «Покупка 29 октября».
  static func name(_ title: String?, occurredAt: Date, _ environment: AppEnvironment) -> String {
    if let title { return title }
    let day = environment.calendar.day(of: occurredAt)
    return f("warranty.untitled", environment, environment.dates.dayAndMonth(day))
  }

  // MARK: Lines of «Стоит посмотреть»

  static func note(
    _ reminder: WarrantyReminder, names: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    func f(_ key: String, _ arguments: CVarArg...) -> String {
      String(
        format: environment.language(key, table: "Overview"),
        locale: environment.language.locale, arguments: arguments)
    }
    let day = { (day: DateOnly) in environment.dates.dayAndMonth(day) }
    switch reminder {
    case .returnEnds(let id, let title, let until, let left):
      let name = title ?? names[id] ?? "—"
      return left == 0 ? f("look.warranty.returnToday", name) : f("look.warranty.returnEnds", name, day(until))
    case .warrantyEnds(let id, let title, let until, let left, let place):
      let name = title ?? names[id] ?? "—"
      let base =
        left == 0 ? f("look.warranty.endsToday", name) : f("look.warranty.ends", name, day(until))
      guard let place, !place.isEmpty else { return base }
      return base + f("look.warranty.place", place)
    }
  }

  /// The symbol of a line: what it is about, and an exclamation on the last day.
  nonisolated static func symbol(_ reminder: WarrantyReminder) -> String {
    switch reminder {
    case .returnEnds(_, _, _, let left):
      left == 0 ? "exclamationmark.circle" : "arrow.uturn.backward.circle"
    case .warrantyEnds(_, _, _, let left, _):
      left == 0 ? "exclamationmark.circle" : "checkmark.shield"
    }
  }

  // MARK: Under the entry line

  /// «Гарантия до 29 октября 2028 · Вернуть можно до 12 ноября 2026», or `nil` for a line without
  /// a term.
  static func hint(
    warranty: DateOnly?, returnUntil: DateOnly?, _ environment: AppEnvironment
  ) -> String? {
    var parts: [String] = []
    if let warranty {
      parts.append(f("warranty.line.until", environment, environment.dates.longDay(warranty)))
    }
    if let returnUntil {
      parts.append(f("warranty.line.return", environment, environment.dates.longDay(returnUntil)))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: Rows of the list

  /// «Осталось 12 дней», «сегодня последний день», «срок вышел».
  static func left(_ days: Int, _ environment: AppEnvironment) -> String {
    if days < 0 { return t("warranty.over", environment) }
    if days == 0 { return t("warranty.today", environment) }
    return environment.language.format("warranty.left", table: table, counts: days)
  }
}
