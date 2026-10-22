import AppCore
import CoreKit
import Foundation
import GRDB

// The month limits, the articles of events, the owner's templates of events, the extras of
// subscriptions, the saved views and the owner's statement profiles
// (`Schema/0014_import_year_questions_subscriptions.sql`), mapped by hand like every other record
// (`RowMapping`). A template and a profile carry moments the core types do not know, so the
// repositories write those two with their own statements; the other records can be saved as they are.

extension LimitMonthException: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "budget_month_exceptions"

  public init(row: Row) throws {
    guard let month = RowMapping.month(row, "month") else { throw UnreadableValue(column: "month") }
    self.init(
      id: try RowMapping.uuid(row, "id"), budgetId: try RowMapping.uuid(row, "budget_id"),
      month: month, amountE4: try RowMapping.amount(row, "amount_e4"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["budget_id"] = budgetId.uuidString
    container["month"] = month.iso
    container["amount_e4"] = amountE4.raw
  }
}

extension EventBudgetItem: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "event_budget_items"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), eventId: try RowMapping.uuid(row, "event_id"),
      title: row["title"] ?? "", plannedE4: try RowMapping.amount(row, "planned_e4"),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["event_id"] = eventId.uuidString
    container["title"] = title
    container["planned_e4"] = plannedE4.raw
    container["sort"] = sort
  }
}

/// Read only: the repository writes a template with its moments. A row whose `lines` this build
/// can not read (a newer one wrote it) fails the read of that row; the repository reads rows one
/// by one and leaves such a template out, untouched in the database.
extension EventTemplate: @retroactive FetchableRecord {
  public init(row: Row) throws {
    guard let id: String = row["id"], !id.isEmpty else { throw UnreadableValue(column: "id") }
    let text: String = row["lines"] ?? "[]"
    guard let lines = try? JSONDecoder().decode([EventTemplateLine].self, from: Data(text.utf8))
    else { throw UnreadableValue(column: "lines") }
    self.init(
      id: id, name: row["name"] ?? "", isBuiltIn: false,
      eventKind: EventKind(rawValue: row["event_kind"] ?? "other") ?? .other,
      totalE4: try RowMapping.amount(row, "total_e4"), lines: lines)
  }

  /// The stored form of the articles: the JSON of the lines, keys sorted so equal content is
  /// equal text.
  static func linesJSON(_ lines: [EventTemplateLine]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(lines)) ?? Data("[]".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}

extension SubscriptionTerms: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "subscription_terms"

  public init(row: Row) throws {
    var tolerance: Int? = try RowMapping.optionalInteger(row, "tolerance_percent")
    if let value = tolerance, !(1...100).contains(value) { tolerance = nil }
    self.init(
      paymentId: try RowMapping.uuid(row, "payment_id"),
      yearlyPlanE4: try RowMapping.optionalAmount(row, "yearly_plan_e4"),
      monthlyPlanE4: try RowMapping.optionalAmount(row, "monthly_plan_e4"),
      floating: try RowMapping.flag(row, "floating", fallback: false),
      tolerancePercent: tolerance,
      serviceType: (row["service_type"] as String?).flatMap(ServiceType.init(rawValue:)),
      needed: try RowMapping.flag(row, "needed", fallback: false),
      yearlyReminderOff: try RowMapping.flag(row, "yearly_reminder_off", fallback: false),
      ownerUses: try RowMapping.flag(row, "owner_uses", fallback: true))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["payment_id"] = paymentId.uuidString
    container["yearly_plan_e4"] = yearlyPlanE4?.raw
    container["monthly_plan_e4"] = monthlyPlanE4?.raw
    container["floating"] = floating
    container["tolerance_percent"] = tolerancePercent
    container["service_type"] = serviceType?.rawValue
    container["needed"] = needed
    container["yearly_reminder_off"] = yearlyReminderOff
    container["owner_uses"] = ownerUses
  }
}

extension UsageMark: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "subscription_usage"

  public init(row: Row) throws {
    guard let day = RowMapping.day(row, "day") else { throw UnreadableValue(column: "day") }
    self.init(
      id: try RowMapping.uuid(row, "id"), paymentId: try RowMapping.uuid(row, "payment_id"),
      day: day)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_id"] = paymentId.uuidString
    container["day"] = day.iso
  }
}

extension SubscriptionUser: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "subscription_users"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), paymentId: try RowMapping.uuid(row, "payment_id"),
      personId: try RowMapping.uuid(row, "person_id"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_id"] = paymentId.uuidString
    container["person_id"] = personId.uuidString
  }
}

extension KeepGroup: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "subscription_keep_groups"

  public init(row: Row) throws {
    guard let type = (row["type"] as String?).flatMap(ServiceType.init(rawValue:)) else {
      throw UnreadableValue(column: "type")
    }
    let text: String = row["payment_ids"] ?? "[]"
    guard let ids = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else {
      throw UnreadableValue(column: "payment_ids")
    }
    self.init(
      id: try RowMapping.uuid(row, "id"), type: type,
      paymentIds: Set(ids.compactMap(UUID.init(uuidString:))))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["type"] = type.rawValue
    container["payment_ids"] = Self.idsJSON(paymentIds)
  }

  /// The payments' ids as a JSON array, sorted, so equal sets are equal text.
  static func idsJSON(_ ids: Set<UUID>) -> String {
    let data = (try? JSONEncoder().encode(ids.map(\.uuidString).sorted())) ?? Data("[]".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}

extension SavedViewRecord: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "saved_views"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), kind: row["kind"] ?? "", name: row["name"] ?? "",
      payload: row["payload"] ?? "",
      sortOrder: try RowMapping.optionalInteger(row, "sort_order") ?? 0)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["kind"] = kind
    container["name"] = name
    container["payload"] = payload
    container["sort_order"] = sortOrder
  }
}
