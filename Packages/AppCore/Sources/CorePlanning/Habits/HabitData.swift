import CoreAnalytics
import CoreKit
import Foundation

/// What the habits keep in the database, read with the data: the badges earned, the days marked
/// «трат не было» and the settings.
public struct HabitData: Hashable, Sendable {
  public var badges: [HabitBadge]
  public var noSpendDays: [NoSpendDay]
  public var settings: HabitSettings

  public init(
    badges: [HabitBadge] = [], noSpendDays: [NoSpendDay] = [],
    settings: HabitSettings = HabitSettings()
  ) {
    self.badges = badges
    self.noSpendDays = noSpendDays
    self.settings = settings
  }

  public static let empty = HabitData()

  /// The days marked, as a set.
  public var markedDays: Set<DateOnly> { Set(noSpendDays.map(\.day)) }

  /// The keys of the badges written.
  public var badgeKeys: Set<String> { Set(badges.map(\.key)) }
}

extension Dataset {
  public static let habitsKey = "planning.habits"

  /// The badges, the days without spending and the settings of the habits.
  public var habits: HabitData {
    get { extras.value(Self.habitsKey) ?? .empty }
    set { extras.set(newValue, for: Self.habitsKey) }
  }
}
