import AppCore
import Foundation

/// The operations and transfers of each day, as the lists show them: the grouping is pure, apart
/// from the store, so it can be exercised without a window.
extension TransactionsStore {
  public struct DayGroup: Identifiable, Sendable {
    public let day: DateOnly
    /// Everything of the day in one line-up, newest first (`DayItem.newestFirst`): operations
    /// of every kind and the transfers between the owner's own accounts side by side. The rows
    /// tell the kinds apart by their symbols; nothing heads a kind.
    let items: [DayItem]
    /// What the day comes to — the same function the selection and the delete confirmation
    /// use, so selecting the whole day shows exactly the numbers of its header. Transfers are
    /// in none of it: money moved between the owner's own accounts is neither earned nor spent.
    /// A refund taken back from a purchase counts on the purchase's day, as the purchase
    /// made cheaper, and adds nothing on its own day.
    public let totals: RowTotals

    /// `refunds` are the refunds of the whole ledger: a purchase listed here shows what a
    /// refund made on a later day took back, and a refund listed here whose purchase is on
    /// another day adds nothing — the same numbers as Overview and the selection. `items` are
    /// put in time order here, whatever order they come in.
    init(
      day: DateOnly, items: [DayItem], debts: [UUID: Debt] = [:], refunds: RefundIndex = .empty
    ) {
      let items = items.sorted(by: DayItem.newestFirst)
      self.day = day
      self.items = items
      self.totals = RowTotals(entries: items.compactMap(\.entry), debts: debts, refunds: refunds)
    }

    public var id: String { day.iso }
    /// The operations of the day, newest first.
    public var entries: [TransactionEntry] { items.compactMap(\.entry) }
    /// Spending and refunds of spending, newest first.
    public var expenses: [TransactionEntry] {
      entries.filter { !Self.isListedWithIncome($0.transaction.kind) }
    }
    /// Income, and the money people gave back, newest first. A reimbursement is on this side
    /// because money came in, but it is not income: the row says so and `totals` never adds
    /// it to income.
    public var income: [TransactionEntry] {
      entries.filter { Self.isListedWithIncome($0.transaction.kind) }
    }
    /// Money moved that day between the owner's own accounts, newest first.
    public var transfers: [Transfer] { items.compactMap(\.movedBetweenAccounts) }
    /// Everything of the day a list can select: the operations, then the transfers. A set to
    /// the list — the order only keeps the value the same on every read.
    public var selectableIds: [UUID] { entries.map(\.id) + transfers.map(\.id) }

    /// Which side of a day an operation is on in the table of Transactions, which still lists
    /// income and spending apart.
    nonisolated static func isListedWithIncome(_ kind: TransactionKind) -> Bool {
      kind == .income || kind == .reimbursement
    }
  }

  /// Pure grouping, isolated from the store so it can be exercised without a UI. Operations and
  /// transfers go on the day they were made, in one line-up by time; a day of transfers alone
  /// is a day too.
  /// `refunds` — the ledger's (`Ledger.refundIndex`) — count a refund taken back from a
  /// purchase in the purchase's day, never twice.
  nonisolated static func group(
    _ entries: [TransactionEntry], calendar: CalendarContext, debts: [UUID: Debt] = [:],
    transfers: [Transfer] = [], refunds: RefundIndex = .empty
  )
    -> [DayGroup]
  {
    let byDay = Dictionary(grouping: entries) { calendar.day(of: $0.transaction.occurredAt) }
    let transfersByDay = Dictionary(grouping: transfers) { calendar.day(of: $0.occurredAt) }
    let days = Set(byDay.keys).union(transfersByDay.keys)
    return days.sorted(by: >).map { day in
      let operations = (byDay[day] ?? []).map(DayItem.operation)
      let items = operations + (transfersByDay[day] ?? []).map(DayItem.transfer)
      return DayGroup(day: day, items: items, debts: debts, refunds: refunds)
    }
  }

  /// Transfers alone, newest first; of two made at the same moment, the later written first —
  /// the order of the table of Transactions, which lists them apart.
  nonisolated static func newestFirst(_ left: Transfer, _ right: Transfer) -> Bool {
    if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
    if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
    return left.id.uuidString > right.id.uuidString
  }
}
