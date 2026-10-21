import CoreCSV
import CoreKit
import Foundation

/// Reads the application's own CSV export back into the rows the model learns from.
///
/// Six of the eighteen files are enough: the operations, their parts, and the categories so
/// that a system category can be told from an ordinary one. It reads and never writes.
///
/// It asks the questions the application asks (`LedgerTraining` in `CoreInsights`): the day
/// of an operation in the owner's calendar — the export writes every moment in UTC, and a
/// coffee at half past midnight in Moscow is the day before there — and the amount in whole
/// rubles rounded half away from zero, as `wholeRubles` rounds it.
public struct CSVExportReader: Sendable {
  private let transactions: [[String: String]]
  private let parts: [[String: String]]
  private let categories: [[String: String]]
  private let calendar: CalendarContext

  /// `calendar` is the owner's: the one the application reads days in.
  public init(folder: URL, calendar: CalendarContext) throws {
    self.calendar = calendar
    func rows(_ name: String) throws -> [[String: String]] {
      try CSVReader.dictionaries(from: try Data(contentsOf: folder.appendingPathComponent(name)))
    }
    transactions = try rows(ExportTables.transactions.fileName)
    parts = try rows(ExportTables.transactionParts.fileName)
    categories = try rows(ExportTables.categories.fileName)
  }

  public func examples() -> [CategoryExample] {
    CategoryTraining.examples(from: rows())
  }

  public func rows() -> [CategoryTraining.Row] {
    var systemRole: [String: SystemRole] = [:]
    var parentOf: [String: String] = [:]
    for category in categories {
      guard let id = category["id"], !id.isEmpty else { continue }
      if let role = category["system_role"], let value = SystemRole(rawValue: role) {
        systemRole[id] = value
      }
      if let parent = category["parent_id"], !parent.isEmpty { parentOf[id] = parent }
    }
    var byId: [String: [String: String]] = [:]
    for transaction in transactions {
      guard let id = transaction["id"] else { continue }
      byId[id] = transaction
    }

    return parts.compactMap { part in
      guard let partId = uuid(part["id"]), let transaction = byId[part["transaction_id"] ?? ""]
      else { return nil }
      let categoryId = part["category_id"] ?? ""
      let role = systemRole[categoryId] ?? parentOf[categoryId].flatMap { systemRole[$0] }
      guard let moment = CSVValue.instant(transaction["occurred_at"] ?? "") else { return nil }
      let day = calendar.day(of: moment)
      return CategoryTraining.Row(
        partId: partId, categoryId: uuid(categoryId), systemRole: role,
        categorySource: CategorySource(rawValue: part["category_source"] ?? "") ?? .manual,
        externalId: nonEmpty(transaction["external_id"]),
        isDeleted: nonEmpty(transaction["deleted_at"]) != nil,
        query: CategoryQuery(
          day: day, weekday: weekday(of: day),
          kind: (transaction["kind"] ?? "") == "income" ? .income : .expense,
          text: nonEmpty(part["note"]) ?? nonEmpty(transaction["note"]) ?? "",
          placeId: uuid(transaction["place_id"]),
          paymentMethodId: uuid(transaction["payment_method_id"]),
          forWhom: nonEmpty(part["for_whom"]) ?? "me",
          forPersonId: uuid(part["for_person_id"]),
          amountWhole: whole(part["amount_rub"] ?? part["amount"])))
    }
  }

  private func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
  }

  private func uuid(_ text: String?) -> UUID? {
    guard let text = nonEmpty(text) else { return nil }
    return UUID(uuidString: text.uppercased())
  }

  /// The export writes an amount as a decimal string with a point; the model sees it in
  /// whole rubles, rounded half away from zero, and only to find which bucket it falls in.
  private func whole(_ text: String?) -> Int64 {
    guard let text = nonEmpty(text),
      let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    else { return 0 }
    return (try? DecimalMath.int64(rounding: value)) ?? 0
  }

  /// The day of the week without a calendar: the model must see the same weekday for a date
  /// wherever this runs. 1 is Monday.
  private func weekday(of day: DateOnly) -> Int {
    let number = Recency.dayNumber(of: day)
    // 1970-01-01 was a Thursday, the fourth day of the week.
    return ((number % 7) + 7 + 3) % 7 + 1
  }
}
