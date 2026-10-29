import AppCore
import Foundation

/// Words for the purchase fields of the editor, the questions asked before a purchase is written,
/// the lines of «Стоит посмотреть» and the gift days (table `Purchases2`).
@MainActor
enum PurchaseHookText {
  nonisolated static let table = "Purchases2"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func f(_ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...) -> String {
    String(
      format: t(key, environment), locale: environment.language.locale, arguments: arguments)
  }

  /// Every key the screens use, so a test finds each in both languages.
  nonisolated static let keys = [
    "purchase.discount.title", "purchase.discount.hint",
    "purchase.regret.title", "purchase.regret.no", "purchase.regret.yes", "purchase.regret.skip",
    "purchase.regret.answered.no", "purchase.regret.answered.yes", "purchase.regret.answered.skip",
    "purchase.regret.change", "purchase.refund.title", "purchase.refund.pick",
    "purchase.refund.credited", "purchase.mileage.title",
    "purchase.mileage.prompt", "purchase.pause.title", "purchase.pause.message",
    "purchase.pause.messageNoShare", "purchase.pause.record", "purchase.mileage.question",
    "purchase.mileage.message", "purchase.mileage.messageFirst", "purchase.mileage.prompt.km",
    "purchase.mileage.save", "purchase.mileage.unknown", "look.purchase.wish",
    "look.purchase.refund", "look.purchase.refundLate", "look.purchase.refundDays",
    "look.purchase.birthday", "look.purchase.birthdayBudget", "look.purchase.birthdayToday",
    "look.purchase.birthdayTodayBudget", "look.purchase.regret", "look.purchase.untitled",
    "look.purchase.action.createEvent", "look.purchase.action.openWishes",
    "look.purchase.action.openRefunds", "look.purchase.action.credited",
    "look.purchase.eventName", "person.birthday", "person.birthday.add", "person.birthday.remove",
    "person.birthday.day", "person.birthday.month", "person.birthday.year",
    "person.birthday.yearPrompt", "person.giftBudget", "person.giftBudget.hint",
    "calendar.birthday", "calendar.birthday.mark", "calendar.birthdayBudget", "calendar.birthday.turns",
    "calendar.birthday.createEvent", "calendar.birthday.created", "calendar.birthday.notCreated",
    "planning.birthdays.title", "planning.birthdays.line", "planning.birthdays.lineBudget",
    "planning.birthdays.today",
  ]

  // MARK: Lines of «Стоит посмотреть»

  /// The line of a purchase note.
  static func note(_ note: PurchaseNote, _ environment: AppEnvironment) -> String {
    let money = environment.money
    switch note {
    case .wishReady(_, let name, let price):
      return f("look.purchase.wish", environment, name, money.rounded(price))
    case .refundWaiting(_, let title, let amount, _, let waiting, let late):
      let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? t("look.purchase.untitled", environment)
      let base = f(
        late > 0 ? "look.purchase.refundLate" : "look.purchase.refund", environment, name,
        money.rounded(amount))
      let days = environment.language.format(
        "look.purchase.refundDays", table: table, counts: late > 0 ? late : waiting)
      return base + " · " + days
    case .birthday(let day):
      return birthday(day, environment)
    case .regret(let question):
      let name =
        question.note.flatMap { $0.isEmpty ? nil : $0 } ?? t("look.purchase.untitled", environment)
      return f(
        "look.purchase.regret", environment, name, money.rounded(question.amountRubE4),
        environment.dates.dayAndMonth(question.boughtOn))
    }
  }

  /// «Маше 14 марта, бюджет 5 000 ₽»-style line of a birthday: the name, the day, the budget.
  static func birthday(_ day: GiftDay, _ environment: AppEnvironment) -> String {
    let date = environment.dates.dayAndMonth(day.date)
    let budget = day.budgetE4.map { environment.money.rounded($0) }
    if day.daysLeft == 0 {
      return budget.map { f("look.purchase.birthdayTodayBudget", environment, day.name, $0) }
        ?? f("look.purchase.birthdayToday", environment, day.name)
    }
    return budget.map { f("look.purchase.birthdayBudget", environment, day.name, date, $0) }
      ?? f("look.purchase.birthday", environment, day.name, date)
  }

  nonisolated static func symbol(_ note: PurchaseNote) -> String {
    switch note {
    case .wishReady: "bag"
    case .refundWaiting(_, _, _, _, _, let late): late > 0 ? "exclamationmark.circle" : "hourglass"
    case .birthday: "gift"
    case .regret: "questionmark.bubble"
    }
  }

  /// A refund that is late is told by the symbol and the words, and drawn as an alarm too.
  nonisolated static func isAlarm(_ note: PurchaseNote) -> Bool {
    if case .refundWaiting(_, _, _, _, _, let late) = note { return late > 0 }
    return false
  }

  // MARK: The calendar of gifts

  /// «День рождения Маши, бюджет 5 000 ₽» for the chosen day of the calendar.
  static func calendarLine(_ day: GiftDay, _ environment: AppEnvironment) -> String {
    var line =
      day.budgetE4.map {
        f("calendar.birthdayBudget", environment, day.name, environment.money.rounded($0))
      } ?? f("calendar.birthday", environment, day.name)
    if let age = day.turnsAge, age > 0 {
      line += " · " + environment.language.format("calendar.birthday.turns", table: table, counts: age)
    }
    return line
  }

  /// The line of the nearest birthdays in Planning.
  static func planningLine(_ day: GiftDay, _ environment: AppEnvironment) -> String {
    if day.daysLeft == 0 {
      return f("planning.birthdays.today", environment, day.name)
    }
    let date = environment.dates.dayAndMonth(day.date)
    return day.budgetE4.map {
      f("planning.birthdays.lineBudget", environment, day.name, date, environment.money.rounded($0))
    } ?? f("planning.birthdays.line", environment, day.name, date)
  }
}
