import CoreKit
import Foundation
import GRDB

// The badges and the days without spending (`Schema/0020_habits.sql`), mapped by hand like every
// other record (`RowMapping`). Both tables are keyed by what they are about.

/// A row without a period or a day of earning says nothing and fails the read of that row
/// (`UnreadableValue`); the repository reads rows one by one and leaves it out, untouched.
extension HabitBadge: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = HabitStorage.badgesTable

  public init(row: Row) throws {
    guard let kind: String = row["kind"], !kind.isEmpty else {
      throw UnreadableValue(column: "kind")
    }
    guard let period: String = row["period"], !period.isEmpty else {
      throw UnreadableValue(column: "period")
    }
    guard let earnedOn = RowMapping.day(row, "earned_on") else {
      throw UnreadableValue(column: "earned_on")
    }
    self.init(
      kindText: kind, period: period, earnedOn: earnedOn,
      earnedAt: RowMapping.readableInstant(row, "earned_at") ?? Date(timeIntervalSince1970: 0))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["key"] = key
    container["kind"] = kindText
    container["period"] = period
    container["earned_on"] = earnedOn.iso
    container["earned_at"] = StoredInstant.databaseValue(earnedAt)
  }
}

extension NoSpendDay: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = HabitStorage.noSpendTable

  public init(row: Row) throws {
    guard let day = RowMapping.day(row, "day") else { throw UnreadableValue(column: "day") }
    self.init(
      day: day,
      markedAt: RowMapping.readableInstant(row, "marked_at") ?? Date(timeIntervalSince1970: 0))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["day"] = day.iso
    container["marked_at"] = StoredInstant.databaseValue(markedAt)
  }
}
