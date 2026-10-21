import CoreAccounting
import CoreKit
import Foundation

/// A first count that may have recorded the whole balance it found as a difference.
///
/// Before 1.2 the setup of the accounts wrote a starting balance of 0 for every field left
/// empty, so the first real count of such an account compared the money against nothing but
/// what moved since — and «Записать разницу» turned the balance itself into «Сверка» income or
/// spending. The same happened to the first reconciliation of one total after a zero one. Such
/// a count is offered to the owner, never changed silently: it may also be a real difference
/// after a zero that really was zero.
public enum FirstCountCandidate: Hashable, Sendable {
  /// A compared count of a sheet of accounts whose pair rested only on zero openings written
  /// before 1.2 (`ZeroOpenings`), made at `at`, on the day `day`. `operationId`: its difference
  /// operation while it is live.
  case count(ReconciledBalance, at: Date, day: DateOnly, operationId: UUID?)
  /// A reconciliation of one total with a difference, whose earlier totals all counted 0 ₽ or
  /// which had none before it. `operationId`: its difference operation while it is live.
  case total(Reconciliation, operationId: UUID?)

  /// The counted balance's id, or the reconciliation's for a total: the id
  /// `reconcile.firstCountKept` remembers.
  public var id: UUID {
    switch self {
    case .count(let balance, _, _, _): balance.id
    case .total(let reconciliation, _): reconciliation.id
    }
  }

  /// The difference as it was found: in the pair's currency, in rubles for a total.
  public var difference: AmountE4 {
    switch self {
    case .count(let balance, _, _, _): balance.differenceE4 ?? .zero
    case .total(let reconciliation, _): reconciliation.differenceE4 ?? .zero
    }
  }

  /// The currency of `difference`.
  public var currency: CurrencyCode {
    switch self {
    case .count(let balance, _, _, _): balance.currency
    case .total: .rub
    }
  }

  /// The pair of a count; `nil` for a total.
  public var key: BalanceKey? {
    guard case .count(let balance, _, _, _) = self else { return nil }
    return balance.key
  }

  /// The day of the reconciliation.
  public var day: DateOnly {
    switch self {
    case .count(_, _, let day, _): day
    case .total(let reconciliation, _): reconciliation.date
    }
  }

  /// The operation that recorded the difference, while it is live.
  public var operationId: UUID? {
    switch self {
    case .count(_, _, _, let operation): operation
    case .total(_, let operation): operation
    }
  }

  /// Day, then moment: the order the candidates are listed in, newest first.
  var order: (DateOnly, Date) {
    switch self {
    case .count(_, let at, let day, _): (day, at)
    case .total(let reconciliation, _):
      (reconciliation.date, reconciliation.reconciledAt ?? .distantPast)
    }
  }
}

/// What the fix of a first count writes, in one step of ⌘Z.
public struct FirstCountFixWrite: Hashable, Sendable {
  /// The count made a starting point.
  public var balances: [ReconciledBalance]
  /// The reconciliation of one total made a starting point.
  public var reconciliations: [Reconciliation]
  /// The difference operation, to the bin.
  public var softDeleted: [UUID]

  public init(
    balances: [ReconciledBalance] = [], reconciliations: [Reconciliation] = [],
    softDeleted: [UUID] = []
  ) {
    self.balances = balances
    self.reconciliations = reconciliations
    self.softDeleted = softDeleted
  }
}

/// The first count is the truth: the balance is what was counted, never income or spending.
/// These are the rules that find the first counts older versions recorded as a difference, fix
/// one when the owner says so, and keep a new count of such a pair a starting point.
public enum FirstCountFix {
  /// The first counts that recorded a difference against zero openings of before 1.2 or
  /// against zero totals, newest first, less those in `kept` — the owner called them a real
  /// difference. A count or a total without a difference is no candidate: there is nothing to
  /// take back. `liveOperations` are the ids of the live operations: a candidate's operation is
  /// named only while it is one of them.
  public static func candidates(
    book: PlanningBook, balances: AccountBalances, liveOperations: Set<UUID>, kept: Set<UUID>
  ) -> [FirstCountCandidate] {
    let reconciliations = Dictionary(
      book.reconciliations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let frozen = ZeroOpenings.frozenCounts(
      balances: balances, reconciliations: book.reconciliations, kept: kept)
    func live(_ id: UUID?) -> UUID? { id.flatMap { liveOperations.contains($0) ? $0 : nil } }
    var found: [FirstCountCandidate] = []
    for key in balances.keys {
      for anchor in balances.anchors(key) where frozen.contains(anchor.balance.id) {
        let balance = anchor.balance
        guard let difference = balance.differenceE4, !difference.isZero,
          let reconciliation = reconciliations[balance.reconciliationId]
        else { continue }
        found.append(
          .count(
            balance, at: anchor.at, day: reconciliation.date,
            operationId: live(balance.transactionId)))
      }
    }
    var onlyZerosBefore = true
    for reconciliation in book.reconciliations where reconciliation.kind == .total {
      defer { onlyZerosBefore = onlyZerosBefore && reconciliation.actualTotalRubE4.isZero }
      guard onlyZerosBefore, let difference = reconciliation.differenceE4, !difference.isZero,
        !kept.contains(reconciliation.id)
      else { continue }
      found.append(.total(reconciliation, operationId: live(reconciliation.transactionId)))
    }
    return found.sorted { left, right in
      left.order != right.order
        ? left.order > right.order : left.id.uuidString > right.id.uuidString
    }
  }

  /// The rows of the sheet a new count of which is its starting point by default: their pair
  /// rests only on zero openings written before 1.2 (`ZeroOpenings.rests`), whatever the books
  /// expect for it now. A zero written in 1.2 — typed in the setup, given to a new account, left
  /// by a merge — is a real count, and its pair compares as usual.
  public static func startingPointKeys(
    _ rows: [ReconcileRow], balances: AccountBalances, reconciliations: [Reconciliation]
  ) -> Set<BalanceKey> {
    let byId = Dictionary(
      reconciliations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return Set(
      rows.map(\.key).filter {
        ZeroOpenings.rests($0, before: nil, balances: balances, reconciliations: byId)
      })
  }

  /// «Это первая сверка — сделать точкой отсчёта»: the count becomes a starting point — no
  /// expected balance, no difference, no operation, no way of keeping one — or the total does,
  /// and its operation goes to the bin (a soft delete: ⌘Z writes the count back with its link,
  /// so the operation must still be there). The balance stays what was counted.
  public static func fix(_ candidate: FirstCountCandidate) -> FirstCountFixWrite {
    let binned = candidate.operationId.map { [$0] } ?? []
    switch candidate {
    case .count(var balance, _, _, _):
      balance.expectedE4 = nil
      balance.differenceE4 = nil
      balance.transactionId = nil
      balance.recordsDifference = nil
      return FirstCountFixWrite(balances: [balance], softDeleted: binned)
    case .total(var reconciliation, _):
      reconciliation.expectedTotalRubE4 = nil
      reconciliation.differenceE4 = nil
      reconciliation.transactionId = nil
      return FirstCountFixWrite(reconciliations: [reconciliation], softDeleted: binned)
    }
  }

  /// «Это настоящая разница»: the text of `reconcile.firstCountKept` with `id` added — one id
  /// per line, sorted, as the settings keep it.
  public static func keeping(_ ids: Set<UUID>, in kept: Set<UUID>) -> String {
    kept.union(ids).map(\.uuidString).sorted().joined(separator: "\n")
  }
}
