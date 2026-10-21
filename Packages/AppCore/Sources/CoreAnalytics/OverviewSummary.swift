import CoreAccounting
import CoreKit
import Foundation

/// The figures of the Overview cards, for one «today».
///
/// «Month to date» is the 1st through today: expenses by date, income that belongs to this
/// month and arrived by today. It is compared with the same span of the previous month —
/// the 1st through the same day number, clipped to that month's length — with income that
/// belongs to the previous month and arrived by the end of that span.
public struct OverviewSummary: Hashable, Sendable {
  public var today: DateOnly
  public var span: DayRange
  public var previousSpan: DayRange

  public var expenses: Change
  public var income: Change
  public var net: AmountE4 { income.current - expenses.current }

  /// Top five top-level categories of my expenses this month; shares are of all top-level
  /// categories, so the five need not add up to 100 %. «Uncategorized» is one of them when
  /// it is that large: unlike a table, the card ranks by amount alone.
  public var topCategories: [BreakdownNode]
  /// Every top-level category of my expenses this month with money in it, largest first,
  /// «Сверка» left out: the first `topCount` with money spent are `topCategories`, and the
  /// shares of all of them are taken of the money spent in the positive ones.
  public var categories: [BreakdownNode]
  /// Good, neutral and bad spending this month, always in that order, with shares.
  public var qualities: [BreakdownNode]
  /// Bad spending this month against the same span of the previous month.
  public var bad: Change

  /// Parts paid for other people that are still expected back: what is left of each, since
  /// money back may cover only some of a part.
  public var owedToMe: AmountE4
  public var owedCount: Int

  public static let topCount = 5

  public init(ledger: Ledger, today: DateOnly) {
    self.today = today
    let span = Period.monthToDate(today: today).range
    let previousSpan = Period.sameSpanOfPreviousMonth(today: today).range
    self.span = span
    self.previousSpan = previousSpan

    expenses = Change(
      current: ledger.expenses(in: span), previous: ledger.expenses(in: previousSpan))
    income = Change(
      current: ledger.income(attributedTo: [today.monthKey], notAfter: today),
      previous: ledger.income(
        attributedTo: [previousSpan.start.monthKey], notAfter: previousSpan.end))

    let rows = ledger.rows(in: span).filter { !$0.contribution.isZero }
    // The tables put «Uncategorized» last; here it would then drop out of the five however
    // large it were, and the card would hide the largest bucket behind smaller ones.
    // The difference of a reconciliation is no purchase: «Сверка» and what a count wrote
    // elsewhere stay out of the top, and out of the shares of it.
    let counts = ledger.dataset.planning.settings.limitlessCategoryIds
    let spending = rows.filter { !Self.isCountDifference($0, countCategories: counts) }
    categories = Tabulation.oneLevel(
      spending.map { (ReportGrouping.category.outerKey(of: $0), $0.contribution) }
    )
    .sorted(by: Tabulation.largestFirst)
    topCategories = Array(categories.filter { $0.amount.raw > 0 }.prefix(Self.topCount))
    qualities = Self.qualities(of: rows)

    let previousBad = ledger.rows(in: previousSpan).filter { $0.quality == .bad }
    bad = Change(
      current: AmountE4.sum(rows.filter { $0.quality == .bad }.map(\.contribution)),
      previous: AmountE4.sum(previousBad.map(\.contribution)))

    let owed = OwedParts(ledger)
    owedToMe = owed.total
    owedCount = owed.parts.count
  }

  /// The moment the owner last wrote something down: the latest `createdAt` of the live
  /// operations and of the transfers. It is the moment of writing — a purchase of last week
  /// typed now is written now, and an edit or ⌘Z of an old one moves nothing, since
  /// `createdAt` outlives both. The lines the app writes to keep the books right (a surplus,
  /// a shortfall, a reconciliation difference, a written-off remainder) are not the owner's
  /// writing and do not count.
  ///
  /// A function of the data rather than a figure of the summary: the summary compares equal
  /// for the same money whenever it was written, and the moment of writing is no money.
  public static func lastRecordedAt(_ dataset: Dataset) -> Date? {
    var latest: Date?
    func consider(_ moment: Date) {
      if latest.map({ moment > $0 }) ?? true { latest = moment }
    }
    for entry in dataset.entries where !entry.transaction.isDeleted {
      if OperationLink(externalId: entry.transaction.externalId)?.isBookkeeping == true {
        continue
      }
      consider(entry.transaction.createdAt)
    }
    for transfer in dataset.transfers {
      consider(transfer.createdAt)
    }
    return latest
  }

  /// The newest operation the owner wrote — by the rule of `lastRecordedAt`: the latest
  /// `createdAt` of the live operations, the lines the app writes to keep the books right left
  /// out. A transfer is no operation: `nil` when the last thing written was one, or nothing was.
  public static func lastOperation(in dataset: Dataset) -> TransactionEntry? {
    guard let moment = lastRecordedAt(dataset) else { return nil }
    return dataset.entries.last {
      !$0.transaction.isDeleted && $0.transaction.createdAt == moment
        && OperationLink(externalId: $0.transaction.externalId)?.isBookkeeping != true
    }
  }

  /// What an operation is called on a tile: its note, else the name of the category of its
  /// first part; `nil` with neither.
  public static func title(of entry: TransactionEntry, tree: CategoryTree) -> String? {
    if let note = entry.transaction.note?.trimmingCharacters(in: .whitespaces), !note.isEmpty {
      return note
    }
    return tree.category(entry.parts.first?.categoryId)?.name
  }

  /// A part of a reconciliation's difference: written by a count (its link says so), or filed
  /// under the category a count writes to — «Сверка» or anything under it.
  public static func isCountDifference(_ row: LedgerRow, countCategories: Set<UUID>) -> Bool {
    switch row.link {
    case .reconciliation, .reconciledBalance: return true
    default: break
    }
    guard !countCategories.isEmpty else { return false }
    if let id = row.categoryId, countCategories.contains(id) { return true }
    if let root = row.rootCategoryId, countCategories.contains(root) { return true }
    return false
  }

  /// Good → neutral → bad, zero lines included so the bar keeps its order.
  static func qualities(of rows: some Sequence<LedgerRow>) -> [BreakdownNode] {
    var sums: [Quality: AmountE4] = [:]
    for row in rows {
      guard let quality = row.quality, !row.contribution.isZero else { continue }
      sums[quality, default: .zero] += row.contribution
    }
    let amounts = Quality.allCases.map { sums[$0] ?? .zero }
    let shares = Shares.basisPoints(amounts)
    return Quality.allCases.enumerated().map { index, quality in
      BreakdownNode(key: .quality(quality), amount: amounts[index], share: shares[index])
    }
  }
}

/// The parts I paid for somebody else that are still expected back, each with what is left of
/// it — money back may cover a part only in part. The one rule of «Мне должны» on Overview: the
/// summary's figure, the card's line about what came back and the breakdown of the card all
/// read it.
public struct OwedParts: Hashable, Sendable {
  public struct Part: Hashable, Sendable {
    public var partId: UUID
    public var transactionId: UUID
    public var day: DateOnly
    /// Who owes it; `nil` for a part without a person.
    public var personId: UUID?
    /// What is left of it, in rubles.
    public var remainingRub: AmountE4
    /// What already came back for it, in rubles.
    public var returnedRub: AmountE4
  }

  /// In the order of the ledger.
  public var parts: [Part]

  public init(_ ledger: Ledger) {
    var parts: [Part] = []
    for row in ledger.rows
    where row.kind == .expense && row.reimbursable && row.reimbursementStatus == .expected {
      let remaining = ledger.remaining(ofPart: row)
      guard remaining.raw > 0 else { continue }
      parts.append(
        Part(
          partId: row.partId, transactionId: row.transactionId, day: row.day,
          personId: row.debtorPersonId, remainingRub: remaining,
          returnedRub: ledger.returned(forPart: row.partId)))
    }
    self.parts = parts
  }

  public var total: AmountE4 { AmountE4.sum(parts.map(\.remainingRub)) }

  /// What is owed by each person, the largest first, the parts without a person last.
  public var byPerson: [(personId: UUID?, amount: AmountE4, count: Int)] {
    var order: [UUID?] = []
    var sums: [UUID?: (AmountE4, Int)] = [:]
    for part in parts {
      if sums[part.personId] == nil { order.append(part.personId) }
      let (amount, count) = sums[part.personId] ?? (.zero, 0)
      sums[part.personId] = (amount + part.remainingRub, count + 1)
    }
    return order.map { (personId: $0, amount: sums[$0]?.0 ?? .zero, count: sums[$0]?.1 ?? 0) }
      .sorted { left, right in
        if (left.personId == nil) != (right.personId == nil) { return right.personId == nil }
        if left.amount != right.amount { return left.amount > right.amount }
        return left.personId?.uuidString ?? "" < right.personId?.uuidString ?? ""
      }
  }
}
