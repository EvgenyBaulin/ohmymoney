import CoreKit
import Foundation

/// A time of day, coarse enough to be a habit: the coffee in the morning, the cafe in the evening.
public enum DayPart: Int, Hashable, Sendable, CaseIterable {
  case night
  case morning
  case day
  case evening

  /// 05:00–10:59 morning, 11:00–16:59 day, 17:00–22:59 evening, the rest night.
  public init(hour: Int) {
    switch hour {
    case 5..<11: self = .morning
    case 11..<17: self = .day
    case 17..<23: self = .evening
    default: self = .night
    }
  }
}

/// Something the owner wrote some time ago, named by its text («Кофе»), to learn habits from.
public struct HabitEvent: Hashable, Sendable {
  public var label: String
  public var occurredAt: Date
  public var timeZoneId: String?

  public init(label: String, occurredAt: Date, timeZoneId: String? = nil) {
    self.label = label
    self.occurredAt = occurredAt
    self.timeZoneId = timeZoneId
  }
}

/// The chips of the templates sorted by the habits of the moment: what
/// the owner usually writes at this time of day and on this day of the week comes first.
/// Nothing new is shown — the same chips, the needed one nearer.
public enum HabitOrdering {
  /// The history older than this is not a habit any more.
  public static let memoryDays = 180

  /// What a template is called in the history: its text up to the amount, the blank or a dash,
  /// without case, «ё» as «е». «Кофе 250» and «кофе» are one habit.
  public static func label(of text: String) -> String {
    var words: [String] = []
    for token in text.split(separator: " ", omittingEmptySubsequences: true) {
      if token.contains(where: { $0 >= "0" && $0 <= "9" }) || token.hasPrefix("?") { break }
      if ["—", "–", "-", ":"].contains(String(token)) { break }
      words.append(String(token))
    }
    return NameKey.fold(words.joined(separator: " "))
  }

  /// How well each template fits `now`: an event of the same part of the day and the same
  /// weekday counts 3, the same part of the day 2, the same weekday 1, any other 0.
  public static func scores(
    for templates: [Template], history: [HabitEvent], now: Date, calendar: CalendarContext
  ) -> [UUID: Int] {
    let today = calendar.day(of: now)
    let part = DayPart(hour: calendar.timeOfDay(now).hour)
    let weekday = calendar.weekdayIndex(today)
    let oldest = calendar.adding(days: -memoryDays, to: today)
    var weights: [String: Int] = [:]
    for event in history where event.occurredAt <= now {
      let eventPart = DayPart(
        hour: calendar.timeOfDay(event.occurredAt, recordedIn: event.timeZoneId).hour)
      let eventDay = calendar.day(of: event.occurredAt, recordedIn: event.timeZoneId)
      guard eventDay >= oldest else { continue }
      let samePart = eventPart == part
      let sameWeekday = calendar.weekdayIndex(eventDay) == weekday
      weights[label(of: event.label), default: 0] +=
        (samePart ? 2 : 0) + (sameWeekday ? 1 : 0)
    }
    return Dictionary(
      templates.map { ($0.id, weights[label(of: $0.text)] ?? 0) },
      uniquingKeysWith: { first, _ in first })
  }

  /// The templates as the chips show them: pinned first (the owner's choice stays), then by
  /// how well they fit the moment, then by use, then by text. Archived ones are left out.
  public static func ordered(
    _ templates: [Template], history: [HabitEvent], now: Date, calendar: CalendarContext
  ) -> [Template] {
    let live = templates.filter { !$0.archived }
    let score = scores(for: live, history: history, now: now, calendar: calendar)
    return live.sorted { left, right in
      if left.pinned != right.pinned { return left.pinned }
      let leftScore = score[left.id] ?? 0
      let rightScore = score[right.id] ?? 0
      if leftScore != rightScore { return leftScore > rightScore }
      if left.useCount != right.useCount { return left.useCount > right.useCount }
      return NameKey.fold(left.text) < NameKey.fold(right.text)
    }
  }
}
