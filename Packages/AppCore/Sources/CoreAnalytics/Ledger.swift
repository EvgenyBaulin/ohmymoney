import CoreAccounting
import CoreCSV
import CoreKit
import Foundation

/// One part of one live operation, with everything the analytics ask about it already
/// worked out. Overview, Analytics, Reports and the Transactions filter all read these rows,
/// so they cannot disagree on a rule.
public struct LedgerRow: Hashable, Sendable {
  public var transactionId: UUID
  public var partId: UUID
  /// Position of the part inside its operation; 0 is the first part.
  public var partIndex: Int
  public var kind: TransactionKind

  /// The day of the operation, in the calendar the ledger was built with.
  public var day: DateOnly
  /// The moment of the operation. The day is what almost everything counts by; «возможный
  /// дубль» is the one rule that asks how far apart two operations of the same day are.
  public var occurredAt: Date
  public var dayNumber: Int
  /// 1 = Monday … 7 = Sunday.
  public var weekday: Int
  /// The month the money belongs to: `period_month ?? month of the date` for income, the
  /// month of the date for everything else.
  public var month: MonthKey

  public var currency: CurrencyCode
  /// The part in the operation's own currency.
  public var amountE4: AmountE4
  /// The part in rubles.
  public var amountRubE4: AmountE4
  /// Its signed contribution to my expenses (`MyExpensesRule.contribution`): the amount
  /// for my spending, minus the amount for a refund, zero for everything else.
  ///
  /// A refund taken back from a purchase counts in the purchase: the purchase part comes in
  /// cheaper by what its refunds took back (`refundedRubE4`) — on its own day, in its own
  /// month, in its own category — and the refund part contributes nothing.
  public var contribution: AmountE4
  /// On a refund part: the purchase part it takes back from, when that purchase is live.
  public var refundOfPartId: UUID?
  /// On a purchase part: what its refunds took back, in the operation's currency and in rubles.
  public var refundedE4: AmountE4
  public var refundedRubE4: AmountE4

  public var categoryId: UUID?
  /// The top-level category the part is filed under.
  public var rootCategoryId: UUID?
  public var systemRole: SystemRole?
  /// The stored quality, or the one `QualityResolver` gives when none is stored. `nil` for
  /// income and reimbursements, which have no quality.
  public var quality: Quality?

  public var forWhom: ForWhom
  public var forPersonId: UUID?
  public var placeId: UUID?
  public var paymentMethodId: UUID?
  public var eventId: UUID?
  public var goalId: UUID?

  public var reimbursable: Bool
  public var reimbursementStatus: ReimbursementStatus?
  public var debtorPersonId: UUID?

  public var isGoalContribution: Bool
  public var debtId: UUID?
  public var creditDebtId: UUID?
  /// What the operation was written for by the app itself, from its `external_id`.
  public var link: OperationLink?
  /// The card that paid, a card of `paymentMethodId`; `nil` — the account itself. The money is
  /// the account's: a card only says what paid.
  public var cardId: UUID? = nil

  /// The person the part is about: whom it was for, or who owes it.
  public var personId: UUID? { forPersonId ?? debtorPersonId }
  public var isFirstPart: Bool { partIndex == 0 }
}

/// The flat, sorted list of every part of every live operation, built once per
/// `Dataset` off the main thread and shared by every section of every window.
public struct Ledger: Sendable {
  public let dataset: Dataset
  public let calendar: CalendarContext
  public let tree: CategoryTree
  /// Sorted by day, then by the moment of the operation, then by part.
  public let rows: [LedgerRow]
  /// The first day with a live operation of any kind.
  public let firstDay: DateOnly?

  private let rowsByMonth: [MonthKey: [Int]]
  /// Where the row of each part is in `rows`.
  private let rowIndexByPart: [UUID: Int]
  private let entriesById: [UUID: TransactionEntry]
  private let searchKeys: [UUID: String]
  /// Σ of the live reimbursement links of each part, in rubles.
  private let returnedByPart: [UUID: AmountE4]
  /// Σ of the rubles of the live shortfalls and remainders written off of each part.
  private let companionsByPart: [String: (shortfall: AmountE4, writtenOff: AmountE4)]
  /// Which refunds take back from which purchase parts, over the live operations.
  public let refundIndex: RefundIndex

  public init(dataset: Dataset, calendar: CalendarContext) {
    self.dataset = dataset
    self.calendar = calendar
    let tree = CategoryTree(dataset.categories)
    self.tree = tree
    let history = ManualQualityHistory(entries: dataset.entries)
    let debts = dataset.debtsById
    let refunds = RefundIndex(entries: dataset.entries, debts: debts)
    self.refundIndex = refunds

    // The day of an operation is the day in the zone it was recorded in; one calendar per zone.
    var zoneCalendars: [String: CalendarContext] = [:]
    func dayOf(_ transaction: Transaction) -> DateOnly {
      guard let id = transaction.timeZoneId, let zone = TimeZone(identifier: id),
        zone != calendar.timeZone
      else { return calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId) }
      let zoned = zoneCalendars[id] ?? CalendarContext(timeZone: zone)
      zoneCalendars[id] = zoned
      return zoned.day(of: transaction.occurredAt)
    }
    let alive = dataset.entries
      .filter { !$0.transaction.isDeleted }
      .map { (entry: $0, day: dayOf($0.transaction)) }
      .sorted { left, right in
        if left.day != right.day { return left.day < right.day }
        if left.entry.transaction.occurredAt != right.entry.transaction.occurredAt {
          return left.entry.transaction.occurredAt < right.entry.transaction.occurredAt
        }
        return left.entry.id.uuidString < right.entry.id.uuidString
      }

    let names = SearchNames(dataset: dataset)
    var rows: [LedgerRow] = []
    rows.reserveCapacity(alive.count * 2)
    var entriesById: [UUID: TransactionEntry] = [:]
    var searchKeys: [UUID: String] = [:]
    var partOwners: Set<UUID> = []
    var companions: [String: (shortfall: AmountE4, writtenOff: AmountE4)] = [:]
    for (stored, day) in alive {
      // What an income stored before its kind lost those fields — a place, an event, a person —
      // is kept in the database, and read as if it were not there.
      let entry = KindFields.masked(stored)
      let transaction = entry.transaction
      entriesById[entry.id] = stored
      switch OperationLink(externalId: transaction.externalId) {
      case .shortfall(_, let part):
        companions[part.lowercased(), default: (.zero, .zero)].shortfall += transaction.amountRubE4
      case .remainderWriteOff(let part, _):
        companions[part.lowercased(), default: (.zero, .zero)].writtenOff +=
          transaction.amountRubE4
      default:
        break
      }
      searchKeys[entry.id] = names.key(for: entry, tree: tree)
      let debt = transaction.debtId.flatMap { debts[$0] }
      let creditDebt = transaction.creditDebtId.flatMap { debts[$0] }
      let month =
        transaction.kind == .income ? (transaction.periodMonth ?? day.monthKey) : day.monthKey
      let dayNumber = day.dayNumber
      for (index, part) in entry.parts.enumerated() {
        partOwners.insert(part.id)
        let quality: Quality? =
          transaction.kind.hasQuality
          ? (part.quality
            ?? QualityResolver.resolve(
              part: part, in: transaction, categories: tree, history: history
            ).quality)
          : nil
        rows.append(
          LedgerRow(
            transactionId: transaction.id,
            partId: part.id,
            partIndex: index,
            kind: transaction.kind,
            day: day,
            occurredAt: transaction.occurredAt,
            dayNumber: dayNumber,
            weekday: day.weekday,
            month: month,
            currency: transaction.currency,
            amountE4: part.amountE4,
            amountRubE4: part.amountRubE4,
            contribution: refunds.isLinked(refundPart: part.id)
              ? .zero
              : MyExpensesRule.contribution(
                part: part, in: transaction, debt: debt, creditDebt: creditDebt)
                + refunds.movedContribution(part: part.id),
            refundOfPartId: refunds.purchasePart(ofRefundPart: part.id),
            refundedE4: refunds.refunded(part: part.id),
            refundedRubE4: refunds.refundedRub(part: part.id),
            categoryId: part.categoryId,
            rootCategoryId: tree.root(of: part.categoryId)?.id ?? part.categoryId,
            systemRole: tree.systemRole(of: part.categoryId),
            quality: quality,
            forWhom: part.forWhom,
            forPersonId: part.forPersonId,
            placeId: transaction.placeId,
            paymentMethodId: transaction.paymentMethodId,
            eventId: part.eventId,
            goalId: part.goalId,
            reimbursable: part.reimbursable,
            // Only a purchase is waited for: a part of it paid for somebody else without a
            // stored status is still expected. Other kinds keep what is stored.
            reimbursementStatus: part.reimbursable && transaction.kind == .expense
              ? (part.reimbursementStatus ?? .expected) : part.reimbursementStatus,
            debtorPersonId: part.debtorPersonId,
            isGoalContribution: QualityResolver.isGoalContribution(
              goalId: part.goalId, categoryId: part.categoryId, categories: tree),
            debtId: transaction.debtId,
            creditDebtId: transaction.creditDebtId,
            link: OperationLink(externalId: transaction.externalId),
            cardId: transaction.cardId))
      }
    }

    var rowsByMonth: [MonthKey: [Int]] = [:]
    var rowIndexByPart: [UUID: Int] = [:]
    rowIndexByPart.reserveCapacity(rows.count)
    for (index, row) in rows.enumerated() {
      rowsByMonth[row.month, default: []].append(index)
      rowIndexByPart[row.partId] = index
    }

    // A link counts only while both the reimbursement and the operation of the part it
    // closes are alive: deleting either takes the money out of «returned».
    var returnedByPart: [UUID: AmountE4] = [:]
    for link in dataset.links {
      guard let reimbursement = entriesById[link.reimbursementTxId],
        reimbursement.transaction.kind == .reimbursement, partOwners.contains(link.partId)
      else { continue }
      returnedByPart[link.partId, default: .zero] += link.amountE4
    }

    self.rows = rows
    self.firstDay = alive.first?.day
    self.rowsByMonth = rowsByMonth
    self.rowIndexByPart = rowIndexByPart
    self.entriesById = entriesById
    self.searchKeys = searchKeys
    self.returnedByPart = returnedByPart
    self.companionsByPart = companions
  }

  // MARK: - Lookups

  public var debtsById: [UUID: Debt] { dataset.debtsById }

  public func entry(_ id: UUID) -> TransactionEntry? { entriesById[id] }

  /// The live operations, in no particular order.
  public var entries: Dictionary<UUID, TransactionEntry>.Values { entriesById.values }

  /// The row of one part of a live operation: its quality as the rules give it, its status.
  /// The Transactions table reads a part's cells from here, so they say what the filter and
  /// the figures say.
  public func row(ofPart partId: UUID) -> LedgerRow? {
    rowIndexByPart[partId].map { rows[$0] }
  }

  /// Lower-cased text of the operation that the search box matches against.
  public func searchKey(of transactionId: UUID) -> String? { searchKeys[transactionId] }

  /// What people gave back for this part, through live reimbursements, in rubles.
  public func returned(forPart partId: UUID) -> AmountE4 { returnedByPart[partId] ?? .zero }

  /// What is still owed on a part paid for somebody else, in rubles: the part less what came
  /// back for it. Money back may cover only some of a part, which keeps waiting for the rest.
  public func remaining(ofPart row: LedgerRow) -> AmountE4 {
    max(.zero, row.amountRubE4 - returned(forPart: row.partId))
  }

  /// What refunds took back from a purchase part, in its currency.
  public func refunded(forPart partId: UUID) -> AmountE4 { refundIndex.refunded(part: partId) }

  /// The rubles of the live operations the app wrote for a part paid for somebody else: the
  /// shortfalls money back left of it, and what was left of it and written off.
  public func companionsRub(forPart partId: UUID) -> (shortfall: AmountE4, writtenOff: AmountE4) {
    companionsByPart[partId.uuidString.lowercased()] ?? (.zero, .zero)
  }

  /// Rows whose day falls in the span, by date.
  public func rows(in range: DayRange) -> ArraySlice<LedgerRow> {
    guard !range.isEmpty else { return rows[rows.startIndex..<rows.startIndex] }
    let lower = firstIndex { $0.dayNumber >= range.start.dayNumber }
    let upper = firstIndex { $0.dayNumber > range.end.dayNumber }
    return rows[lower..<upper]
  }

  /// Rows whose money belongs to one of these months: income by the month it is for,
  /// everything else by the month of the date.
  public func rows(attributedTo months: some Sequence<MonthKey>) -> [LedgerRow] {
    var indices: [Int] = []
    for month in months { indices.append(contentsOf: rowsByMonth[month] ?? []) }
    return indices.sorted().map { rows[$0] }
  }

  /// The totals of the day header, of a selection and of the delete dialog — the
  /// `RowTotals` of `CoreAccounting` over these operations, with the refunds of the whole
  /// ledger counted in their purchases.
  public func rowTotals(of transactionIds: some Sequence<UUID>) -> RowTotals {
    RowTotals(
      entries: transactionIds.compactMap { entriesById[$0] }, debts: dataset.debtsById,
      refunds: refundIndex)
  }

  private func firstIndex(where predicate: (LedgerRow) -> Bool) -> Int {
    var low = rows.startIndex
    var high = rows.endIndex
    while low < high {
      let middle = (low + high) / 2
      if predicate(rows[middle]) { high = middle } else { low = middle + 1 }
    }
    return low
  }

  // MARK: - Common sums

  /// My expenses for the days of the span, by date.
  public func expenses(in range: DayRange) -> AmountE4 {
    AmountE4.sum(rows(in: range).lazy.map(\.contribution))
  }

  /// Income that belongs to the months of `months`, optionally only what arrived on or
  /// before `notAfter` — the cut-off Overview uses for «month to date».
  public func income(attributedTo months: [MonthKey], notAfter: DateOnly? = nil) -> AmountE4 {
    AmountE4.sum(
      rows(attributedTo: months).lazy
        .filter { row in row.kind == .income && (notAfter.map { row.day <= $0 } ?? true) }
        .map(\.amountRubE4))
  }

  /// Income of a period: by the month it is for when the period is made of whole months,
  /// by date otherwise.
  public func income(in period: Period) -> AmountE4 {
    if period.isWholeMonths { return income(attributedTo: period.months) }
    return income(byDateIn: period.range)
  }

  /// Income that arrived on the days of the span, whatever month it is for.
  func income(byDateIn range: DayRange) -> AmountE4 {
    AmountE4.sum(rows(in: range).lazy.filter { $0.kind == .income }.map(\.amountRubE4))
  }

  /// Income rows of a period, with the same rule as `income(in:)`.
  public func incomeRows(in period: Period) -> [LedgerRow] {
    if period.isWholeMonths {
      return rows(attributedTo: period.months).filter { $0.kind == .income }
    }
    return rows(in: period.range).filter { $0.kind == .income }
  }
}

/// Names the search box can find an operation by. Built once per ledger.
private struct SearchNames {
  let categories: [UUID: String]
  let people: [UUID: String]
  let places: [UUID: String]
  let methods: [UUID: String]
  let events: [UUID: String]
  let cards: [UUID: String]

  init(dataset: Dataset) {
    func index<T>(
      _ items: [T], _ id: KeyPath<T, UUID>, _ name: KeyPath<T, String>
    ) -> [UUID: String] {
      Dictionary(
        items.map { ($0[keyPath: id], $0[keyPath: name]) }, uniquingKeysWith: { a, _ in a })
    }
    categories = index(dataset.categories, \.id, \.name)
    people = index(dataset.people, \.id, \.name)
    places = index(dataset.places, \.id, \.name)
    methods = index(dataset.paymentMethods, \.id, \.name)
    events = index(dataset.events, \.id, \.name)
    cards = index(dataset.cards, \.id, \.name)
  }

  /// Description, part notes, place, payment method and card, categories with their parents,
  /// people, events and the amount as typed in a CSV («1234.5»), joined and folded as names are
  /// (`NameKey.fold`: lower case, «ё» as «е»).
  func key(for entry: TransactionEntry, tree: CategoryTree) -> String {
    let transaction = entry.transaction
    var fields: [String] = []
    if let note = transaction.note { fields.append(note) }
    if let id = transaction.placeId, let name = places[id] { fields.append(name) }
    if let id = transaction.paymentMethodId, let name = methods[id] { fields.append(name) }
    if let id = transaction.cardId, let name = cards[id] { fields.append(name) }
    fields.append(CSVValue.string(amount: transaction.amountE4))
    if let expression = transaction.amountExpr { fields.append(expression) }
    for part in entry.parts {
      if let note = part.note { fields.append(note) }
      if let id = part.categoryId {
        if let name = categories[id] { fields.append(name) }
        if let parent = tree.parent(of: id), let name = categories[parent.id] {
          fields.append(name)
        }
      }
      for id in [part.forPersonId, part.debtorPersonId].compactMap({ $0 }) {
        if let name = people[id] { fields.append(name) }
      }
      if let id = part.eventId, let name = events[id] { fields.append(name) }
    }
    // The case and «ё» against «е» do not count, as names are compared everywhere.
    return NameKey.fold(fields.joined(separator: "\n"))
  }
}
