import CoreKit
import Foundation

/// The «For whom» section: my expenses by «for whom» value and by person, with their share
/// of my expenses and how they moved month by month.
public struct ForWhomReport: Hashable, Sendable {
  public struct Month: Hashable, Sendable {
    public var month: MonthKey
    public var amounts: [ForWhom: AmountE4]
  }

  public var values: [BreakdownNode]
  /// By person — whom the part was for, or who owes it. A part that names nobody is my own
  /// spending, not a person's, and has no line here; it stays in the base of the shares, so a
  /// share is still a share of all my expenses.
  public var people: [BreakdownNode]
  public var months: [Month]

  public init(ledger: Ledger, period: Period) {
    let rows = ledger.rows(in: period.range).filter { !$0.contribution.isZero }
    values = Tabulation.oneLevel(rows.map { (.forWhom($0.forWhom), $0.contribution) })
    people = Tabulation.oneLevel(
      rows.map { ($0.personId.map(ReportKey.person) ?? .noPerson, $0.contribution) }
    ).filter { $0.key != .noPerson }
    months = period.months.map { month in
      var amounts: [ForWhom: AmountE4] = [:]
      for row in ledger.rows(in: ledger.slice(of: month, in: period))
      where !row.contribution.isZero {
        amounts[row.forWhom, default: .zero] += row.contribution
      }
      return Month(month: month, amounts: amounts)
    }
  }
}

/// The «Places» section.
public struct PlacesReport: Hashable, Sendable {
  public struct Place: Hashable, Sendable {
    public var placeId: UUID
    /// My expenses at the place in the period.
    public var mySpending: AmountE4
    /// Expense operations at the place in the period.
    public var purchases: Int
    /// Σ of the whole receipts of those operations, less what refunds took back from them, ÷
    /// their number; `nil` without purchases. A jacket of 10,000 with 4,000 of it returned was
    /// a check of 6,000.
    public var averageReceipt: AmountE4?
    /// The first day any operation happened at the place, over the whole history.
    public var firstDay: DateOnly
    /// That first day falls in the period.
    public var isNew: Bool
  }

  /// Every place with an operation in the period, by my spending, largest first.
  public var places: [Place]

  public var byPurchases: [Place] {
    places.sorted { left, right in
      left.purchases != right.purchases
        ? left.purchases > right.purchases : left.placeId.uuidString < right.placeId.uuidString
    }
  }

  public var newPlaces: [Place] { places.filter(\.isNew) }

  public init(ledger: Ledger, period: Period) {
    var firstDays: [UUID: DateOnly] = [:]
    for row in ledger.rows {
      guard let placeId = row.placeId, firstDays[placeId] == nil else { continue }
      firstDays[placeId] = row.day
    }
    var spending: [UUID: AmountE4] = [:]
    var receipts: [UUID: AmountE4] = [:]
    var purchases: [UUID: Set<UUID>] = [:]
    for row in ledger.rows(in: period.range) {
      // A refund taken back from a live purchase belongs to the purchase's day, which already
      // counts it: on its own day it is no visit to the place.
      guard let placeId = row.placeId, row.refundOfPartId == nil else { continue }
      spending[placeId, default: .zero] += row.contribution
      if row.kind == .expense {
        receipts[placeId, default: .zero] += row.amountRubE4 - row.refundedRubE4
        purchases[placeId, default: []].insert(row.transactionId)
      }
    }
    places = spending.keys.compactMap { placeId in
      guard let firstDay = firstDays[placeId] else { return nil }
      let count = purchases[placeId]?.count ?? 0
      return Place(
        placeId: placeId,
        mySpending: spending[placeId] ?? .zero,
        purchases: count,
        averageReceipt: count == 0
          ? nil : AmountE4.rounded((receipts[placeId] ?? .zero).decimal / Decimal(count)),
        firstDay: firstDay,
        isNew: period.range.contains(firstDay))
    }.sorted { left, right in
      left.mySpending != right.mySpending
        ? left.mySpending > right.mySpending : left.placeId.uuidString < right.placeId.uuidString
    }
  }
}

/// The «Events» section: every event that falls in the period or has operations in it,
/// with the whole event's figures — an event is judged as a whole, not cut by months.
public struct EventsReport: Hashable, Sendable {
  public struct Item: Hashable, Sendable {
    public var eventId: UUID
    /// My expenses on the event, over all its operations.
    public var total: AmountE4
    public var byCategory: [BreakdownNode]
    public var budget: AmountE4?
    /// Budget minus total; negative when over budget.
    public var budgetLeft: AmountE4? { budget.map { $0 - total } }
    /// The same event of the previous year (same `series_id`) and what it cost — `nil` when
    /// that event has no operation at all: nothing was recorded, which is not «0 spent».
    public var lastYearEventId: UUID?
    public var lastYearTotal: AmountE4?
  }

  public var events: [Item]

  public init(ledger: Ledger, period: Period) {
    var totals: [UUID: AmountE4] = [:]
    var rowsByEvent: [UUID: [LedgerRow]] = [:]
    var inPeriod: Set<UUID> = []
    for row in ledger.rows {
      guard let eventId = row.eventId else { continue }
      totals[eventId, default: .zero] += row.contribution
      rowsByEvent[eventId, default: []].append(row)
      // A refund taken back from a live purchase is the purchase's, on the purchase's day: it
      // brings no event into a period the event has nothing else in.
      if period.range.contains(row.day), row.refundOfPartId == nil { inPeriod.insert(eventId) }
    }
    let events = ledger.dataset.events
    self.events = events.filter { event in
      inPeriod.contains(event.id)
        || !DayRange(event.startDate, event.endDate).clamped(to: period.range).isEmpty
    }
    .sorted { left, right in
      left.startDate != right.startDate
        ? left.startDate < right.startDate : left.id.uuidString < right.id.uuidString
    }
    .map { event in
      let lastYear = event.seriesId.flatMap { series in
        events.first {
          $0.seriesId == series && $0.id != event.id
            && $0.startDate.year == event.startDate.year - 1
        }
      }
      let rows = (rowsByEvent[event.id] ?? []).filter { !$0.contribution.isZero }
      return Item(
        eventId: event.id,
        total: totals[event.id] ?? .zero,
        byCategory: Tabulation.oneLevel(
          rows.map { (ReportGrouping.category.outerKey(of: $0), $0.contribution) }),
        budget: event.budgetE4,
        lastYearEventId: lastYear?.id,
        lastYearTotal: lastYear.flatMap { totals[$0.id] })
    }
  }
}

/// The «Payment methods» section.
///
/// Next to my spending with each method stands its turnover: the whole receipts of expense
/// operations, parts paid for others included, minus refunds, by date — what the bank pays
/// cashback on. A refund taken back from a live purchase counts like my spending does: the
/// purchase comes in cheaper on its own day and on its own method, and the refund adds nothing
/// on its day, whatever method it came back to; a refund of no purchase lowers the turnover of
/// its own day and method. Cashback is income in the cashback category (and its subcategories)
/// that came to that method, by the month it is for. The share is cashback ÷ turnover, and
/// there is none when the turnover is not positive. Next to it stands the cashback the cards'
/// rules promise for the purchases of the period (`CashbackReport`) — only an expectation.
public struct PaymentMethodsReport: Hashable, Sendable {
  public struct Method: Hashable, Sendable {
    /// `.paymentMethod(id)` or `.noPaymentMethod`.
    public var key: ReportKey
    public var mySpending: AmountE4
    public var turnover: AmountE4
    /// Received: income in the cashback category.
    public var cashback: AmountE4
    /// Expected by the rules of the account's cards, in rubles; never income.
    public var expectedCashback: AmountE4 = .zero
    /// Basis points of the turnover.
    public var cashbackShare: Int? { Shares.ratio(cashback, of: turnover) }
  }

  public var methods: [Method]
  public var cashback: AmountE4 { AmountE4.sum(methods.map(\.cashback)) }

  public init(ledger: Ledger, period: Period) {
    func key(_ row: LedgerRow) -> ReportKey {
      row.paymentMethodId.map(ReportKey.paymentMethod) ?? .noPaymentMethod
    }
    var spending: [ReportKey: AmountE4] = [:]
    var turnover: [ReportKey: AmountE4] = [:]
    var cashback: [ReportKey: AmountE4] = [:]
    for row in ledger.rows(in: period.range) {
      spending[key(row), default: .zero] += row.contribution
      switch row.kind {
      case .expense: turnover[key(row), default: .zero] += row.amountRubE4 - row.refundedRubE4
      case .refund:
        guard row.refundOfPartId == nil else { continue }
        turnover[key(row), default: .zero] += -row.amountRubE4
      case .income, .reimbursement: break
      }
    }
    if let cashbackId = ledger.dataset.settings.cashbackCategoryId {
      let categories = Set([cashbackId] + ledger.tree.children(of: cashbackId).map(\.id))
      for row in ledger.incomeRows(in: period) {
        guard let categoryId = row.categoryId, categories.contains(categoryId) else { continue }
        cashback[key(row), default: .zero] += row.amountRubE4
      }
    }
    var expected: [ReportKey: AmountE4] = [:]
    for cell in CashbackReport(ledger: ledger, period: period).cells {
      let key = cell.holder.accountId.map(ReportKey.paymentMethod) ?? .noPaymentMethod
      expected[key, default: .zero] += cell.expectedRub
    }
    let keys = Set(spending.keys).union(turnover.keys).union(cashback.keys)
    methods = keys.map { key in
      Method(
        key: key, mySpending: spending[key] ?? .zero, turnover: turnover[key] ?? .zero,
        cashback: cashback[key] ?? .zero, expectedCashback: expected[key] ?? .zero)
    }
    .filter { !$0.mySpending.isZero || !$0.turnover.isZero || !$0.cashback.isZero }
    .sorted { left, right in
      if left.key.isRemainder != right.key.isRemainder { return right.key.isRemainder }
      if left.mySpending != right.mySpending { return left.mySpending > right.mySpending }
      return left.key.description < right.key.description
    }
  }
}
