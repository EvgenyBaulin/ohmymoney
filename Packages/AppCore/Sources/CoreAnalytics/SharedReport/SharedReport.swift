import CoreCSV
import CoreKit
import Foundation

/// A report for another person — parents, a partner, an accountant: the operations of a span of
/// days, only on the accounts and in the categories the owner picked, and nothing else of the
/// book. Descriptions and places go only when the owner leaves them on.
///
/// What goes in: every part of a live operation whose day (the day it is shown on, in the zone it
/// was recorded in) is in the span, whose account is one of the picked ones and whose category is
/// one of the picked ones or lies under one. A picked category takes its subcategories with it. An
/// operation without an account, a part without a category and a transfer never go in: none of
/// them can be one of the picked.
///
/// Signs: money that came to the owner — an income, a refund, a reimbursement — is positive,
/// spending is negative, in the line's own currency and in rubles. The totals of a category are in
/// rubles: spending as a positive sum net of its refunds, income as a positive sum.
public struct SharedReport: Hashable, Sendable {
  public struct Request: Hashable, Sendable {
    public var range: DayRange
    public var accountIds: Set<UUID>
    public var categoryIds: Set<UUID>
    /// The descriptions of operations go in.
    public var showsNotes: Bool
    /// The places of operations go in.
    public var showsPlaces: Bool

    public init(
      range: DayRange, accountIds: Set<UUID>, categoryIds: Set<UUID>, showsNotes: Bool = true,
      showsPlaces: Bool = true
    ) {
      self.range = range
      self.accountIds = accountIds
      self.categoryIds = categoryIds
      self.showsNotes = showsNotes
      self.showsPlaces = showsPlaces
    }
  }

  public struct Line: Hashable, Sendable {
    public var day: DateOnly
    public var kind: TransactionKind
    public var account: String
    /// «Дом › Коммуналка» for a subcategory, the name alone for a category.
    public var category: String
    /// Signed, in the currency of the operation.
    public var amount: Money
    /// Signed, in rubles.
    public var amountRub: AmountE4
    public var note: String?
    public var place: String?
  }

  public struct Total: Hashable, Sendable {
    public var category: String
    public var kind: CategoryKind
    /// Positive: spending net of refunds, or income.
    public var amountRub: AmountE4
    public var count: Int
  }

  public var request: Request
  public var preparedOn: DateOnly
  public var lines: [Line]
  /// Spending first, then income; each by the larger sum, then by name.
  public var totals: [Total]
  public var spendingRub: AmountE4
  public var incomeRub: AmountE4

  /// The words of the report's header and of the CSV's columns, in the language of the
  /// interface. The defaults are the keys themselves, so a file made without words still reads.
  public struct Words: Sendable {
    public var columns: [Column: String]
    public var kinds: [TransactionKind: String]
    public var total: String

    public init(
      columns: [Column: String] = [:], kinds: [TransactionKind: String] = [:],
      total: String = "total"
    ) {
      self.columns = columns
      self.kinds = kinds
      self.total = total
    }
  }

  public enum Column: String, CaseIterable, Sendable {
    case date, kind, account, category, amount, currency
    case amountRub = "amount_rub"
    case note, place
  }

  // MARK: Making

  public static func make(
    _ request: Request, dataset: Dataset, preparedOn: DateOnly
  ) -> SharedReport {
    let categories = Dictionary(dataset.categories.map { ($0.id, $0) }) { first, _ in first }
    let accounts = Dictionary(dataset.paymentMethods.map { ($0.id, $0) }) { first, _ in first }
    let places = Dictionary(dataset.places.map { ($0.id, $0) }) { first, _ in first }

    func picked(_ categoryId: UUID?) -> Bool {
      var current = categoryId
      var seen = Set<UUID>()
      while let id = current, seen.insert(id).inserted {
        if request.categoryIds.contains(id) { return true }
        current = categories[id]?.parentId
      }
      return false
    }

    func label(_ categoryId: UUID) -> String {
      guard let category = categories[categoryId] else { return "" }
      if let parent = category.parentId.flatMap({ categories[$0] }) {
        return parent.name + " › " + category.name
      }
      return category.name
    }

    var lines: [(line: Line, at: Date, id: UUID)] = []
    for entry in dataset.entries where !entry.transaction.isDeleted {
      let transaction = entry.transaction
      guard let accountId = transaction.paymentMethodId,
        request.accountIds.contains(accountId)
      else { continue }
      let day = TravelDay.day(of: transaction.occurredAt, zoneId: transaction.timeZoneId)
      guard request.range.contains(day) else { continue }
      let sign: Int64 = transaction.kind == .expense ? -1 : 1
      for part in entry.parts {
        guard let categoryId = part.categoryId, picked(categoryId) else { continue }
        let note = request.showsNotes ? nonEmpty(transaction.note) : nil
        let place =
          request.showsPlaces ? transaction.placeId.flatMap { places[$0]?.name } : nil
        let line = Line(
          day: day, kind: transaction.kind, account: accounts[accountId]?.name ?? "",
          category: label(categoryId),
          amount: Money(
            amount: AmountE4(raw: part.amountE4.raw * sign), currency: transaction.currency),
          amountRub: AmountE4(raw: part.amountRubE4.raw * sign), note: note, place: place)
        lines.append((line, transaction.occurredAt, part.id))
      }
    }
    lines.sort { ($0.line.day, $0.at, $0.id.uuidString) < ($1.line.day, $1.at, $1.id.uuidString) }

    var sums: [String: (kind: CategoryKind, sum: AmountE4, count: Int)] = [:]
    var spending = AmountE4.zero
    var income = AmountE4.zero
    for (line, _, _) in lines {
      let kind = line.kind.categoryKind
      // Spending is shown positive: an expense adds, a refund or a reimbursement takes off.
      let value = kind == .expense ? -line.amountRub : line.amountRub
      var sum = sums[line.category] ?? (kind, .zero, 0)
      sum.sum += value
      sum.count += 1
      sums[line.category] = sum
      if kind == .expense { spending += value } else { income += value }
    }
    let totals = sums.map {
      Total(category: $0.key, kind: $0.value.kind, amountRub: $0.value.sum, count: $0.value.count)
    }
    .sorted { lhs, rhs in
      if lhs.kind != rhs.kind { return lhs.kind == .expense }
      if lhs.amountRub != rhs.amountRub { return lhs.amountRub > rhs.amountRub }
      return lhs.category < rhs.category
    }
    return SharedReport(
      request: request, preparedOn: preparedOn, lines: lines.map(\.line), totals: totals,
      spendingRub: spending, incomeRub: income)
  }

  private static func nonEmpty(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    return text
  }

  // MARK: CSV

  /// The columns the file has: the description and the place only when they go in.
  public var columns: [Column] {
    Column.allCases.filter { column in
      switch column {
      case .note: request.showsNotes
      case .place: request.showsPlaces
      default: true
      }
    }
  }

  /// The report as one CSV file `pandas.read_csv` reads with no parameters: a line per part,
  /// then a line per category total (kind — the word of a total, no date, no account) in
  /// rubles. Amounts are decimal strings with a point.
  public func csv(_ words: Words = Words()) -> Data {
    let columns = columns
    var writer = CSVWriter(columns: columns.map { words.columns[$0] ?? $0.rawValue })
    for line in lines {
      writer.append(
        columns.map { column in
          switch column {
          case .date: line.day.iso
          case .kind: words.kinds[line.kind] ?? line.kind.rawValue
          case .account: line.account
          case .category: line.category
          case .amount: CSVValue.string(amount: line.amount.amount)
          case .currency: line.amount.currency.code
          case .amountRub: CSVValue.string(amount: line.amountRub)
          case .note: line.note ?? ""
          case .place: line.place ?? ""
          }
        })
    }
    for total in totals {
      writer.append(
        columns.map { column in
          switch column {
          case .kind: words.total
          case .category: total.category
          case .amountRub: CSVValue.string(amount: total.amountRub)
          case .currency: CurrencyCode.rub.code
          case .amount: CSVValue.string(amount: total.amountRub)
          default: ""
          }
        })
    }
    return writer.data()
  }

  // MARK: Pages

  /// The lines of each page of a printed report: the first page holds fewer, under the header
  /// and the totals. An empty report is still one page, with the header.
  public static func pages(
    lineCount: Int, firstPage: Int, perPage: Int
  ) -> [Range<Int>] {
    let first = max(0, firstPage)
    let rest = max(1, perPage)
    var pages = [0..<min(first, lineCount)]
    var start = min(first, lineCount)
    while start < lineCount {
      let end = min(lineCount, start + rest)
      pages.append(start..<end)
      start = end
    }
    return pages
  }
}
