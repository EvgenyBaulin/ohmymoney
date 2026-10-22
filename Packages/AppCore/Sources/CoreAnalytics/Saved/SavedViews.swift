import CoreKit
import Foundation

/// The period of a saved filter or report: either the words («last month», which means
/// November in December) or the days it meant when it was saved. The owner picks when saving;
/// the words are the default.
public enum SavedPeriod: Hashable, Sendable, Codable {
  case floating(RelativePeriod)
  case fixed(start: DateOnly, end: DateOnly)

  /// What is saved for a period chosen on `today`. A period that moves with the calendar is
  /// kept as the words unless the owner asked for the days; a period that is already days
  /// (a named month, a year) cannot float and stays fixed.
  public static func saving(
    _ period: RelativePeriod, floating: Bool = true, today: DateOnly
  ) -> SavedPeriod {
    if floating, period.isFloating { return .floating(period) }
    let span = period.resolved(today: today)
    return .fixed(start: span.start, end: span.end)
  }

  public var isFloating: Bool {
    if case .floating = self { return true }
    return false
  }

  /// The days of the period on `today`. A whole month, year or twelve months stays what it
  /// is, so the income of «October» is still taken by the month it is for.
  public func resolved(today: DateOnly) -> Period {
    let span: (start: DateOnly, end: DateOnly)
    switch self {
    case .floating(let period): span = period.resolved(today: today)
    case .fixed(let start, let end): span = (start, end)
    }
    return Period.covering(DayRange(span.start, span.end))
  }

  // MARK: Codable

  private enum CodingKeys: String, CodingKey { case mode, period, start, end }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .mode) {
    case "floating": self = .floating(try container.decode(RelativePeriod.self, forKey: .period))
    case "fixed":
      self = .fixed(
        start: try container.decode(DateOnly.self, forKey: .start),
        end: try container.decode(DateOnly.self, forKey: .end))
    default: throw CoreError.invalidDate
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .floating(let period):
      try container.encode("floating", forKey: .mode)
      try container.encode(period, forKey: .period)
    case .fixed(let start, let end):
      try container.encode("fixed", forKey: .mode)
      try container.encode(start, forKey: .start)
      try container.encode(end, forKey: .end)
    }
  }
}

/// A filter of «Операции» kept under a name: «Кафе за квартал». It stores the criteria and,
/// when the owner chose so, the columns; the period is a `SavedPeriod`.
public struct SavedFilter: Hashable, Sendable, Codable, Identifiable {
  public var id: UUID
  public var name: String
  public var period: SavedPeriod?
  public var kind: TransactionKind?
  public var categoryId: UUID?
  public var subcategoryId: UUID?
  public var quality: Quality?
  public var forWhom: ForWhom?
  public var personId: UUID?
  public var placeId: UUID?
  public var eventId: UUID?
  public var paymentMethodId: UUID?
  public var cardId: UUID?
  public var reimbursementStatus: ReimbursementStatus?
  public var text: String
  /// The keys of the columns of the table, in order, when the filter has its own; `nil` is
  /// «the columns as set».
  public var columns: [String]?

  public init(
    id: UUID = UUID(), name: String, filter: EntryFilter, period: SavedPeriod?,
    columns: [String]? = nil
  ) {
    self.id = id
    self.name = name
    self.period = period
    self.kind = filter.kind
    self.categoryId = filter.categoryId
    self.subcategoryId = filter.subcategoryId
    self.quality = filter.quality
    self.forWhom = filter.forWhom
    self.personId = filter.personId
    self.placeId = filter.placeId
    self.eventId = filter.eventId
    self.paymentMethodId = filter.paymentMethodId
    self.cardId = filter.cardId
    self.reimbursementStatus = filter.reimbursementStatus
    self.text = filter.text
    self.columns = columns
  }

  /// The filter as it applies on `today`: a floating period is worked out now.
  public func entryFilter(today: DateOnly) -> EntryFilter {
    EntryFilter(
      period: period?.resolved(today: today), kind: kind, categoryId: categoryId,
      subcategoryId: subcategoryId, quality: quality, forWhom: forWhom, personId: personId,
      placeId: placeId, eventId: eventId, paymentMethodId: paymentMethodId,
      reimbursementStatus: reimbursementStatus, text: text, cardId: cardId)
  }
}

/// A report kept under a name: which table, grouped by what, for which period. Opening it
/// builds the table again for the period of today, with one call.
public struct SavedReport: Hashable, Sendable, Codable, Identifiable {
  public var id: UUID
  public var name: String
  public var kind: ReportTable.Kind
  public var grouping: ReportGrouping
  public var period: SavedPeriod

  public init(
    id: UUID = UUID(), name: String, kind: ReportTable.Kind,
    grouping: ReportGrouping = .category, period: SavedPeriod
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.grouping = grouping
    self.period = period
  }

  /// The table, rebuilt from the ledger for the period as it is now.
  public func table(using builder: ReportBuilder) -> ReportTable {
    builder.table(kind, period: period.resolved(today: builder.today), grouping: grouping)
  }
}

/// One saved filter or report as a row of storage: a kind, a name and the JSON of the
/// content. The table is created by the storage layer; this is its shape.
public struct SavedViewRecord: Hashable, Sendable, Codable {
  public static let tableName = "saved_views"
  public static let filterKind = "filter"
  public static let reportKind = "report"

  public var id: UUID
  public var kind: String
  public var name: String
  /// The JSON of a `SavedFilter` or a `SavedReport`, keys sorted, so equal content is equal
  /// text.
  public var payload: String
  public var sortOrder: Int

  public init(id: UUID, kind: String, name: String, payload: String, sortOrder: Int) {
    self.id = id
    self.kind = kind
    self.name = name
    self.payload = payload
    self.sortOrder = sortOrder
  }
}

/// All the saved filters and reports. The menu «Отчёты» shows them; a name is unique inside
/// its kind, a second one with the same name (the case and «ё» not counting) gets « 2».
public struct SavedViewsBook: Hashable, Sendable {
  public private(set) var filters: [SavedFilter]
  public private(set) var reports: [SavedReport]

  public init(filters: [SavedFilter] = [], reports: [SavedReport] = []) {
    self.filters = filters
    self.reports = reports
  }

  @discardableResult
  public mutating func add(_ filter: SavedFilter) -> SavedFilter {
    var filter = filter
    filter.name = Self.unique(filter.name, among: filters.map(\.name))
    filters.append(filter)
    return filter
  }

  @discardableResult
  public mutating func add(_ report: SavedReport) -> SavedReport {
    var report = report
    report.name = Self.unique(report.name, among: reports.map(\.name))
    reports.append(report)
    return report
  }

  public mutating func rename(_ id: UUID, to name: String) {
    if let index = filters.firstIndex(where: { $0.id == id }) {
      let others = filters.filter { $0.id != id }.map(\.name)
      filters[index].name = Self.unique(name, among: others)
    } else if let index = reports.firstIndex(where: { $0.id == id }) {
      let others = reports.filter { $0.id != id }.map(\.name)
      reports[index].name = Self.unique(name, among: others)
    }
  }

  public mutating func remove(_ id: UUID) {
    filters.removeAll { $0.id == id }
    reports.removeAll { $0.id == id }
  }

  public mutating func moveFilter(from source: Int, to destination: Int) {
    guard filters.indices.contains(source), filters.indices.contains(destination) else { return }
    filters.insert(filters.remove(at: source), at: destination)
  }

  public mutating func moveReport(from source: Int, to destination: Int) {
    guard reports.indices.contains(source), reports.indices.contains(destination) else { return }
    reports.insert(reports.remove(at: source), at: destination)
  }

  private static func unique(_ name: String, among others: [String]) -> String {
    let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let taken = Set(others.map(NameKey.fold))
    guard taken.contains(NameKey.fold(base)) else { return base }
    var number = 2
    while taken.contains(NameKey.fold("\(base) \(number)")) { number += 1 }
    return "\(base) \(number)"
  }

  // MARK: Storage form

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public var records: [SavedViewRecord] {
    var rows: [SavedViewRecord] = []
    for (index, filter) in filters.enumerated() {
      guard let data = try? Self.encoder.encode(filter) else { continue }
      rows.append(
        SavedViewRecord(
          id: filter.id, kind: SavedViewRecord.filterKind, name: filter.name,
          payload: String(decoding: data, as: UTF8.self), sortOrder: index))
    }
    for (index, report) in reports.enumerated() {
      guard let data = try? Self.encoder.encode(report) else { continue }
      rows.append(
        SavedViewRecord(
          id: report.id, kind: SavedViewRecord.reportKind, name: report.name,
          payload: String(decoding: data, as: UTF8.self), sortOrder: index))
    }
    return rows
  }

  /// Reads rows back; a row that does not decode (written by a later version) is left out
  /// instead of failing the rest.
  public init(records: [SavedViewRecord]) {
    let decoder = JSONDecoder()
    var filters: [(Int, SavedFilter)] = []
    var reports: [(Int, SavedReport)] = []
    for record in records {
      let data = Data(record.payload.utf8)
      switch record.kind {
      case SavedViewRecord.filterKind:
        if let value = try? decoder.decode(SavedFilter.self, from: data) {
          filters.append((record.sortOrder, value))
        }
      case SavedViewRecord.reportKind:
        if let value = try? decoder.decode(SavedReport.self, from: data) {
          reports.append((record.sortOrder, value))
        }
      default: break
      }
    }
    self.filters = filters.sorted { $0.0 < $1.0 }.map(\.1)
    self.reports = reports.sorted { $0.0 < $1.0 }.map(\.1)
  }
}
