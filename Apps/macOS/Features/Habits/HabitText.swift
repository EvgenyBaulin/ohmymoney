import AppCore
import Foundation

/// Words of the habits — the lines of «Стоит посмотреть», the wizard of the days missed, the
/// badges, the first month, the lessons, the mode of a beginner and the settings (table
/// `Habits`). Each line says what it is about in words and a symbol, never in colour alone.
@MainActor
enum HabitText {
  nonisolated static let table = "Habits"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func f(_ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...) -> String {
    String(
      format: t(key, environment), locale: environment.language.locale, arguments: arguments)
  }

  /// Every key the screens use, so a test finds each in both languages.
  nonisolated static let keys = [
    "look.habit.missed", "look.habit.evening", "look.habit.eveningRemind", "look.habit.streak",
    "habit.action.restoreMissed", "habit.action.noSpend",
    "missed.title", "missed.subtitle", "missed.step.balances", "missed.step.days",
    "missed.balances.hint", "missed.balances.expected", "missed.balances.actual",
    "missed.balances.missing", "missed.balances.more", "missed.balances.none",
    "missed.balances.noAccounts", "missed.days.hint", "missed.days.left", "missed.days.done",
    "missed.days.add", "missed.days.allUnknown", "missed.days.category", "missed.days.note",
    "missed.days.remove", "missed.next", "missed.back", "missed.save", "missed.cancel",
    "missed.saved", "missed.notSaved", "missed.changed", "missed.problem.category",
    "missed.problem.amount", "missed.problem.left",
    "badges.title", "badges.none", "badges.streakNow", "badges.kind.entry7", "badges.kind.entry30",
    "badges.kind.entry100", "badges.kind.countMonth", "badges.kind.count3", "badges.kind.count12",
    "badges.earnedOn",
    "month.title", "month.progress", "month.show", "month.hide", "month.dayOf",
    "lessons.title", "lessons.subtitle", "lessons.cards", "lessons.menu", "lessons.close",
    "beginner.caption", "beginner.unlock.entryDays", "beginner.unlock.month",
    "beginner.unlock.firstCount", "beginner.openNow",
    "settings.habits.title", "settings.habits.missedAfter", "settings.habits.missedAfterHint",
    "settings.habits.evening", "settings.habits.eveningHour", "settings.habits.eveningHint",
    "settings.habits.beginner", "settings.habits.beginnerHint", "settings.habits.firstMonth",
    "goal.why.title", "goal.why.prompt", "goal.why.hint", "goal.why.reminder", "goal.why.lowered",
    "goal.why.exceeded",
  ]

  // MARK: Lines of «Стоит посмотреть»

  static func note(_ note: HabitNote, _ environment: AppEnvironment) -> String {
    switch note {
    case .missedDays(let gap):
      return environment.format("look.habit.missed", table: table, counts: gap.count)
    case .evening(let check):
      let base = t(check.remind ? "look.habit.eveningRemind" : "look.habit.evening", environment)
      guard let streak = check.streakDays, streak > 1 else { return base }
      return base + " · " + environment.format("look.habit.streak", table: table, counts: streak)
    }
  }

  nonisolated static func symbol(_ note: HabitNote) -> String {
    switch note {
    case .missedDays: "calendar.badge.exclamationmark"
    case .evening: "moon.stars"
    }
  }

  nonisolated static func actions(_ note: HabitNote) -> [WorthALookNoteText.Action] {
    switch note {
    // «Готово» puts the gap away until a new day of entry starts another.
    case .missedDays: [.restoreMissed, .done]
    case .evening: [.noSpend, .done]
    }
  }

  // MARK: Badges

  nonisolated static func symbol(_ kind: HabitBadgeKind?) -> String {
    switch kind {
    case .entry7: "flame"
    case .entry30: "flame.fill"
    case .entry100: "star.circle.fill"
    case .countMonth: "checkmark.seal"
    case .count3: "checkmark.seal.fill"
    case .count12: "rosette"
    case nil: "questionmark.circle"
    }
  }

  /// The name of a badge; a kind of a newer build is told as nothing (`nil`).
  static func name(_ badge: HabitBadge, _ environment: AppEnvironment) -> String? {
    badge.kind.map { t("badges.kind.\($0.rawValue)", environment) }
  }

  // MARK: The mode of a beginner

  static func unlock(_ unlock: BeginnerUnlock, _ environment: AppEnvironment) -> String {
    switch unlock {
    case .entryDays(let needed, let have):
      return environment.format("beginner.unlock.entryDays", table: table, counts: needed, have)
    case .monthOfEntries(let left):
      return environment.format("beginner.unlock.month", table: table, counts: left)
    case .firstCount:
      return t("beginner.unlock.firstCount", environment)
    }
  }
}
