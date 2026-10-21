import AppCore
import Foundation

/// The caption above the entry line: why the line was not saved, or what the ↓ panel asks for
/// before it is.
enum EntryLineMessage: Equatable {
  /// Why the line cannot be saved: the key of the words that say so (table «Entry»).
  case error(String)
  /// A day the calendar does not have: «31.09 — такой даты нет».
  case date(ParsedInput.DateProblem)
  /// A time no clock shows, as typed: «Такого времени нет: 25:00».
  case time(String)
  /// The line did not say the category, or the subcategory: the panel asks for it.
  case gap(EntryGap)
  /// An operation dated ahead became a plan instead of a record: what it became, and its day.
  case planned(OperationAhead.Plan, DateOnly)
  /// An income in «Заработок» was written: «Записано. Распределить 120 000 ₽?» with
  /// «Распределить…».
  case allocate(UUID, String)
  /// «смз» was written with self-employment off: the one offer to count its tax.
  case offerSelfEmployment

  /// The words on screen.
  @MainActor func text(_ environment: AppEnvironment) -> String {
    switch self {
    case .error(let key):
      return environment.language(key, table: "Entry")
    case .date(.noSuchDate(let written)):
      return environment.language.format("entry.error.noSuchDate", table: "Entry", written)
    case .date(.notInYear(_, _, let year)):
      // The year as digits, never grouped: «2026», not «2,026».
      return environment.language.format("entry.error.noLeapDay", table: "Entry", String(year))
    case .time(let written):
      return environment.language.format("entry.error.noSuchTime", table: "Entry", written)
    case .gap(.category):
      return environment.language("entry.gap.category", table: "Entry")
    case .gap(.subcategory):
      return environment.language("entry.gap.subcategory", table: "Entry")
    case .planned(let plan, let day):
      return environment.language.format(
        plan == .payment ? "entry.ahead.planned.payment" : "entry.ahead.planned.income",
        table: "Entry", environment.dates.longDay(day))
    case .allocate(_, let amount):
      return environment.language.format("entry.allocate.offer", table: "Entry", amount)
    case .offerSelfEmployment:
      return environment.language("entry.selfEmployed.offer", table: "Entry")
    }
  }

  /// The key of the button beside a notice that offers something.
  var actionKey: String? {
    switch self {
    case .allocate: "entry.allocate.action"
    case .offerSelfEmployment: "entry.selfEmployed.action"
    default: nil
    }
  }

  /// A notice of what was done, not a question about the line: the next keystroke takes it away.
  var isNotice: Bool {
    switch self {
    case .planned, .allocate, .offerSelfEmployment: true
    default: false
    }
  }

  /// The symbol before a message that is not an error.
  var symbol: String {
    switch self {
    case .planned: "calendar.badge.plus"
    case .allocate: "arrow.triangle.branch"
    case .offerSelfEmployment: "briefcase"
    default: "exclamationmark.circle"
    }
  }

  /// The words beside the picker the panel marks.
  @MainActor static func mark(_ gap: EntryGap, _ environment: AppEnvironment) -> String {
    switch gap {
    case .category: environment.language("entry.gap.mark.category", table: "Entry")
    case .subcategory: environment.language("entry.gap.mark.subcategory", table: "Entry")
    }
  }

  /// An error is red; a question of the panel is not — the line is not wrong, it is short of a
  /// choice, and the panel says which one.
  var isError: Bool {
    switch self {
    case .gap, .planned, .allocate, .offerSelfEmployment: false
    case .error, .date, .time: true
    }
  }
}
