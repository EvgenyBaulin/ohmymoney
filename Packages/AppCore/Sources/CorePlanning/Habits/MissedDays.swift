import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// «Вы не вводили 4 дня»: the owner typed nothing by hand, and marked no day «трат не было», for
/// whole days. The days to restore run from the day after the last day of entry through today:
/// the balance counted now holds today's spending too.
public struct MissedDays: Hashable, Sendable, Identifiable {
  /// The last day of entry.
  public var lastActive: DateOnly
  public var today: DateOnly

  public init(lastActive: DateOnly, today: DateOnly) {
    self.lastActive = lastActive
    self.today = today
  }

  /// Whole days without entry: those between the last day of entry and today.
  public var count: Int { max(0, lastActive.days(to: today) - 1) }

  /// The days the spending is laid out over: after the last day of entry, through today.
  public var days: [DateOnly] {
    let total = lastActive.days(to: today)
    guard total >= 1 else { return [] }
    return (1...total).map { lastActive.adding(days: $0) }
  }

  /// One line for one gap: put away, it stays away until the next day of entry starts another.
  public var id: String { "habits.missed:\(lastActive.iso)" }
}

/// One currency of one account the wizard asks about: what the app counts on it now.
public struct MissedDaysBalance: Hashable, Sendable, Identifiable {
  public var account: PaymentMethod
  public var key: BalanceKey
  /// What the app counts on it now, in the key's currency.
  public var expected: AmountE4

  public init(account: PaymentMethod, key: BalanceKey, expected: AmountE4) {
    self.account = account
    self.key = key
    self.expected = expected
  }

  public var id: BalanceKey { key }
}

/// One operation the wizard writes: a day, an account and currency, how much, and its category
/// (`nil` until the owner picks one; «Не помню» is a choice too).
public struct MissedDayLine: Hashable, Sendable, Identifiable {
  public var id: UUID
  public var day: DateOnly
  public var key: BalanceKey
  public var amountE4: AmountE4
  public var categoryId: UUID?
  public var note: String

  public init(
    id: UUID = UUID(), day: DateOnly, key: BalanceKey, amountE4: AmountE4,
    categoryId: UUID? = nil, note: String = ""
  ) {
    self.id = id
    self.day = day
    self.key = key
    self.amountE4 = amountE4
    self.categoryId = categoryId
    self.note = note
  }
}

/// The wizard of the days missed: first the balances — what is on each account now against what
/// the app counts, so the money not written down is known —, then that money laid out over the
/// days. What it writes adds up to exactly what was missing: after it, the app counts on each
/// account what the owner typed.
public enum MissedDaysWizard {
  /// The balances asked about: the accounts in the summary («Всего») that were counted at least
  /// once, each currency of theirs with a known balance, in the order of the sidebar. An archived
  /// account is in no section. The snapshot given is the one on the screen: with the hidden
  /// accounts covered, they are not in it and not asked about.
  public static func balances(_ snapshot: AccountsSnapshot) -> [MissedDaysBalance] {
    snapshot.sections.filter(\.inSummary).flatMap { section in
      section.accounts.filter { !$0.account.archived }.flatMap { line in
        line.keys.compactMap { key -> MissedDaysBalance? in
          guard key.anchorAt != nil, let balance = key.balance else { return nil }
          return MissedDaysBalance(account: line.account, key: key.key, expected: balance)
        }
      }
    }
  }

  /// What went unwritten on a balance: what the app counts minus what is there. Above zero —
  /// money was spent and not written down; below zero — more is there than counted (an income
  /// not written), which the wizard does not lay out as spending.
  public static func shortfall(expected: AmountE4, actual: AmountE4) -> AmountE4 {
    expected - actual
  }

  /// The money missing on one balance laid out evenly over the days, in whole units of the
  /// currency: every day but the last gets the same whole amount, the last takes the rest, so the
  /// lines add up to the money exactly. Nothing for no money missing or no day.
  public static func spread(
    _ missing: AmountE4, over days: [DateOnly], key: BalanceKey
  ) -> [MissedDayLine] {
    guard missing.raw > 0, !days.isEmpty else { return [] }
    let whole = AmountE4.unitsPerWhole
    let each = AmountE4(raw: (missing.raw / Int64(days.count)) / whole * whole)
    var lines = days.dropLast().map { MissedDayLine(day: $0, key: key, amountE4: each) }
    let given = AmountE4.sum(lines.map(\.amountE4))
    if let last = days.last {
      lines.append(MissedDayLine(day: last, key: key, amountE4: missing - given))
    }
    // An even share of less than one whole unit leaves the early days at zero: they go.
    return lines.filter { $0.amountE4.raw > 0 }
  }

  /// What is left to lay out on a balance: the money missing minus the lines of that balance.
  public static func left(
    _ missing: AmountE4, lines: [MissedDayLine], key: BalanceKey
  ) -> AmountE4 {
    missing - AmountE4.sum(lines.filter { $0.key == key }.map(\.amountE4))
  }

  /// Why the lines can not be written yet; `nil` when they can: every line above zero and with a
  /// category, and on every balance the lines add up to exactly the money missing on it.
  public enum Problem: Hashable, Sendable {
    case noLines
    case lineWithoutCategory
    case lineNotPositive
    /// The lines of a balance do not add up to what is missing on it.
    case notLaidOut(BalanceKey)
  }

  public static func problem(
    lines: [MissedDayLine], missing: [BalanceKey: AmountE4]
  ) -> Problem? {
    guard !lines.isEmpty else { return .noLines }
    if lines.contains(where: { $0.amountE4.raw <= 0 }) { return .lineNotPositive }
    if lines.contains(where: { $0.categoryId == nil }) { return .lineWithoutCategory }
    for key in Set(lines.map(\.key)).union(missing.filter { $0.value.raw > 0 }.keys).sorted() {
      let wanted = missing[key] ?? .zero
      guard left(wanted, lines: lines, key: key).isZero else { return .notLaidOut(key) }
    }
    return nil
  }
}

/// «Сегодня трат не было?» in the evening of a day without entry: one tap marks the day, and it
/// counts in the streak. With `remind` the line also says «Запишите траты за день» — while no
/// notification of the Mac carries that reminder.
public struct EveningCheck: Hashable, Sendable, Identifiable {
  public var day: DateOnly
  /// The streak alive, in days; `nil` without one.
  public var streakDays: Int?
  public var remind: Bool

  public init(day: DateOnly, streakDays: Int?, remind: Bool) {
    self.day = day
    self.streakDays = streakDays
    self.remind = remind
  }

  public var id: String { "habits.evening:\(day.iso)" }
}

/// The reminder of the evening, «Запишите траты за день», as something to deliver at a moment: a
/// notification of the Mac once there is a way to send one, a line of «Стоит посмотреть» until
/// then. Nothing here knows how it is delivered.
public struct HabitNudge: Hashable, Sendable, Identifiable {
  public var day: DateOnly
  /// When it is due: the evening hour of the day.
  public var at: Date
  /// The streak alive, in days; `nil` without one.
  public var streakDays: Int?

  public init(day: DateOnly, at: Date, streakDays: Int?) {
    self.day = day
    self.at = at
    self.streakDays = streakDays
  }

  public var id: String { "habits.nudge:\(day.iso)" }
}

/// A line of «Стоит посмотреть» about the habits.
public enum HabitNote: Hashable, Sendable, Identifiable {
  /// «Вы не вводили 4 дня — восстановить по остаткам?»
  case missedDays(MissedDays)
  /// «Сегодня трат не было?»
  case evening(EveningCheck)

  public var id: String {
    switch self {
    case .missedDays(let gap): gap.id
    case .evening(let check): check.id
    }
  }
}

public enum HabitNotes {
  /// The default hour of the evening the question and the reminder come at.
  public static let defaultEveningHour = 20

  /// The gap of entry to offer the wizard for: the whole days without entry are at least the
  /// setting. `nil` before anything was ever typed — the first month has its own checklist — and
  /// when the gap is shorter.
  public static func missedDays(
    entryDays: Set<DateOnly>, settings: HabitSettings, today: DateOnly
  ) -> MissedDays? {
    guard let last = entryDays.filter({ $0 <= today }).max() else { return nil }
    let gap = MissedDays(lastActive: last, today: today)
    return gap.count >= settings.missedDaysAfter ? gap : nil
  }

  /// The reminder of the evening for today: today has no entry yet and something was typed before.
  /// `nil` otherwise. Due at `hour` of today.
  public static func nudge(
    entryDays: Set<DateOnly>, today: DateOnly, hour: Int, calendar: CalendarContext
  ) -> HabitNudge? {
    guard !entryDays.contains(today), entryDays.contains(where: { $0 < today }) else { return nil }
    let streak = EntryStreaks.current(days: entryDays, today: today)
    return HabitNudge(
      day: today, at: calendar.moment(today, hour: min(max(hour, 0), 23), minute: 0),
      streakDays: streak?.length)
  }

  /// The lines, in order: the gap first; the question of the evening only without a gap — the
  /// wizard covers today too — and only once the evening has come. `remind` adds «Запишите траты
  /// за день» to the question: the reminder is not delivered any other way. A line whose id is in
  /// `dismissed` is left out.
  public static func list(
    entryDays: Set<DateOnly>, settings: HabitSettings, today: DateOnly, now: Date,
    calendar: CalendarContext, eveningHour: Int = defaultEveningHour, eveningEnabled: Bool = true,
    remind: Bool = true, dismissed: Set<String> = []
  ) -> [HabitNote] {
    if let gap = missedDays(entryDays: entryDays, settings: settings, today: today) {
      return dismissed.contains(gap.id) ? [] : [.missedDays(gap)]
    }
    guard eveningEnabled,
      let nudge = nudge(entryDays: entryDays, today: today, hour: eveningHour, calendar: calendar),
      now >= nudge.at
    else { return [] }
    let check = EveningCheck(day: today, streakDays: nudge.streakDays, remind: remind)
    return dismissed.contains(check.id) ? [] : [.evening(check)]
  }
}
