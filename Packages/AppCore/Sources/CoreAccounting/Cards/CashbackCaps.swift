import CoreKit
import Foundation

/// The monthly ceilings of cashback: «не больше N в месяц» of a rule, and of a whole account
/// (its cards and categories together). Rubles, by the calendar month of the purchase.
public struct CashbackCaps: Sendable {
  private let byRule: [UUID: AmountE4]
  private let byAccount: [UUID: AmountE4]

  public init(rules: [CashbackRule], accounts: [PaymentMethod]) {
    var byRule: [UUID: AmountE4] = [:]
    for rule in rules { if let cap = rule.monthlyCapE4, !cap.isNegative { byRule[rule.id] = cap } }
    var byAccount: [UUID: AmountE4] = [:]
    for account in accounts {
      if let cap = account.cashbackMonthlyCapE4, !cap.isNegative { byAccount[account.id] = cap }
    }
    self.byRule = byRule
    self.byAccount = byAccount
  }

  public var isEmpty: Bool { byRule.isEmpty && byAccount.isEmpty }
  public func cap(ofRule id: UUID) -> AmountE4? { byRule[id] }
  public func cap(ofAccount id: UUID) -> AmountE4? { byAccount[id] }
}

/// The cashback a month has earned so far under each ceiling, purchase by purchase.
///
/// Purchases are admitted in the order they were made (`occurredAt`, then the operation's id,
/// so two runs never disagree). A purchase earns what its rules promise, but no rule beyond its
/// ceiling and no account beyond its own: what is left over is not expected. A typed figure is
/// the bank's own word — the ceiling is already in it —, so it is kept as typed and counts
/// toward the account's ceiling. A refund of no purchase takes back what it takes back, and
/// frees as much room under the ceilings, never below nothing.
public struct CashbackCapTracker: Sendable {
  private struct Slot: Hashable {
    var month: MonthKey
    var id: UUID
  }

  public let caps: CashbackCaps
  private var byRule: [Slot: Decimal] = [:]
  private var byAccount: [Slot: Decimal] = [:]

  public init(caps: CashbackCaps) {
    self.caps = caps
  }

  /// Rubles the month has earned on an account so far.
  public func earned(account: UUID, month: MonthKey) -> Decimal {
    byAccount[Slot(month: month, id: account)] ?? 0
  }

  /// Rubles a rule has earned in a month so far.
  public func earned(rule: UUID, month: MonthKey) -> Decimal {
    byRule[Slot(month: month, id: rule)] ?? 0
  }

  /// Rubles still to be earned this month under the rule's and the account's ceilings; `nil`
  /// when neither has one.
  public func room(rule: UUID?, account: UUID?, month: MonthKey) -> Decimal? {
    var room: Decimal?
    if let rule, let cap = caps.cap(ofRule: rule) {
      room = max(0, cap.decimal - earned(rule: rule, month: month))
    }
    if let account, let cap = caps.cap(ofAccount: account) {
      let left = max(0, cap.decimal - earned(account: account, month: month))
      room = room.map { min($0, left) } ?? left
    }
    return room
  }

  /// The expectation as the ceilings leave it, and the month's tally moved on.
  public mutating func admit(
    _ expectation: CashbackExpectation, month: MonthKey, account: UUID?
  ) -> CashbackExpectation {
    let rubles = expectation.rubles.decimal
    // A refund: the room comes back, the figure stays.
    guard rubles > 0 else {
      if let account { Self.take(-rubles, from: &byAccount, Slot(month: month, id: account)) }
      let total = expectation.byRule.values.reduce(0, +)
      for (rule, share) in expectation.byRule where total != 0 {
        Self.take(-rubles * share / total, from: &byRule, Slot(month: month, id: rule))
      }
      return expectation
    }
    guard case .rules = expectation.source else {
      if let account { byAccount[Slot(month: month, id: account), default: 0] += rubles }
      return expectation
    }
    let total = expectation.byRule.values.reduce(0, +)
    var allowed: [UUID: Decimal] = [:]
    if total > 0 {
      for (rule, share) in expectation.byRule.sorted(by: { $0.key.uuidString < $1.key.uuidString })
      {
        var part = rubles * share / total
        if let cap = caps.cap(ofRule: rule) {
          part = min(part, max(0, cap.decimal - earned(rule: rule, month: month)))
        }
        allowed[rule] = max(0, part)
      }
    } else {
      allowed = [:]
    }
    var kept = total > 0 ? allowed.values.reduce(0, +) : rubles
    if let account, let cap = caps.cap(ofAccount: account) {
      let left = max(0, cap.decimal - earned(account: account, month: month))
      if kept > left {
        let factor = kept.isZero ? 0 : left / kept
        for key in allowed.keys { allowed[key]! *= factor }
        kept = left
      }
    }
    // To the kopeck, down: a ceiling is never passed by a rounding.
    let keptRubles = DecimalMath.round(kept, scale: 2, mode: .down)
    for (rule, part) in allowed { byRule[Slot(month: month, id: rule), default: 0] += part }
    if let account { byAccount[Slot(month: month, id: account), default: 0] += keptRubles }
    guard keptRubles < rubles else { return expectation }
    var result = expectation
    result.rubles = (try? AmountE4(decimal: keptRubles)) ?? .zero
    let money = expectation.money
    if money.currency == .rub {
      result.money = Money(amount: result.rubles, currency: .rub)
    } else {
      let scaled = DecimalMath.round(
        money.amount.decimal * keptRubles / rubles, scale: 2, mode: .down)
      result.money = Money(
        amount: (try? AmountE4(decimal: scaled)) ?? .zero, currency: money.currency)
    }
    result.byRule = allowed.mapValues { $0 * money.amount.decimal / rubles }
    return result
  }

  private static func take(_ amount: Decimal, from book: inout [Slot: Decimal], _ slot: Slot) {
    book[slot] = max(0, (book[slot] ?? 0) - amount)
  }
}

extension CashbackMath {
  /// The expectations of `entries` with the monthly ceilings applied, by operation id. The
  /// entries are taken in the order they were made, whatever order they come in; give every
  /// purchase of a month from its first day, or the ceiling starts counting late.
  public static func cappedExpectations(
    _ entries: [TransactionEntry], holder: (TransactionEntry) -> CashbackHolder?,
    book: CashbackRuleBook, caps: CashbackCaps, tree: CategoryTree, calendar: CalendarContext,
    refunded: (UUID) -> AmountE4
  ) -> [UUID: CashbackExpectation] {
    var tracker = CashbackCapTracker(caps: caps)
    var result: [UUID: CashbackExpectation] = [:]
    let ordered = entries.sorted {
      let (a, b) = ($0.transaction, $1.transaction)
      if a.occurredAt != b.occurredAt { return a.occurredAt < b.occurredAt }
      return a.id.uuidString < b.id.uuidString
    }
    for entry in ordered {
      let held = holder(entry)
      guard
        let expectation = expected(
          entry, holder: held, book: book, tree: tree, calendar: calendar, refunded: refunded)
      else { continue }
      let transaction = entry.transaction
      let month = calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
        .monthKey
      let account = held.flatMap { book.account(of: $0) } ?? transaction.paymentMethodId
      result[transaction.id] =
        caps.isEmpty ? expectation : tracker.admit(expectation, month: month, account: account)
    }
    return result
  }
}
