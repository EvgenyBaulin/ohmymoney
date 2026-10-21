import CoreAccounting
import CoreKit
import Foundation

/// The interest a credit card likely charges in one statement: an estimate, never money.
public struct CreditInterestEstimate: Hashable, Sendable {
  public var statementDay: DateOnly
  public var purchaseInterestE4: AmountE4
  public var cashInterestE4: AmountE4
  public var cashFeesE4: AmountE4
  /// What the owner recorded from the statement; it replaces the estimate.
  public var recordedE4: AmountE4?

  public init(
    statementDay: DateOnly, purchaseInterestE4: AmountE4 = .zero,
    cashInterestE4: AmountE4 = .zero, cashFeesE4: AmountE4 = .zero, recordedE4: AmountE4? = nil
  ) {
    self.statementDay = statementDay
    self.purchaseInterestE4 = purchaseInterestE4
    self.cashInterestE4 = cashInterestE4
    self.cashFeesE4 = cashFeesE4
    self.recordedE4 = recordedE4
  }

  /// What is shown: the recorded sum, else the estimate.
  public var shownE4: AmountE4 {
    recordedE4 ?? purchaseInterestE4 + cashInterestE4 + cashFeesE4
  }
}

/// The interest of a credit card by the rules of a bank like Т-Банк:
///
/// 1. A statement paid in full by its due day: the purchases of its period cost nothing.
/// 2. One that is not: the grace period is lost, and every purchase of its period earns
///    interest at the rate of purchases from its own day — back in time — until it is repaid,
///    the oldest money repaid first. The statements after it keep earning so until one is paid
///    in full in time again: while that has not happened, new purchases earn from their day too.
/// 3. Cash and transfers with «без льготного периода» earn from the day after, at the rate of
///    cash, whatever happens to the statement, and cost the fee of the terms unless the owner
///    recorded the transfer's fee; without the mark they are treated like purchases (still at
///    the rate of cash, when there is one).
/// 4. A day earns as `InterestMath` says; the bank rounds once a statement, to the kopeck.
/// 5. The interest of a lost grace period is charged at the first statement on or after the
///    day it became known — the due day that was missed —, back to the day of each purchase;
///    then at every statement for its own period.
/// 6. A sum the owner recorded from a statement replaces the estimate of that statement.
///
/// Estimates are never money: not in a balance, the free sum, a forecast or the capital.
public enum CreditInterest {
  /// One piece of debt: a purchase or cash-like money charged to the card, repaid oldest first.
  struct Lot: Hashable, Sendable {
    var day: DateOnly
    var isCashLike: Bool
    var isFee: Bool
    var hasRecordedFee: Bool
    var amount: AmountE4
    var remaining: AmountE4
    /// The debt of the lot from the end of each day on (`InterestMath.accrue`).
    var steps: [Step]
    var repaidOn: DateOnly?

    struct Step: Hashable, Sendable {
      var from: DateOnly
      var amount: AmountE4
    }

    /// Repaid by the end of `day`.
    func repaid(by day: DateOnly) -> Bool { repaidOn.map { $0 <= day } ?? false }

    var segments: [(from: DateOnly, amount: AmountE4)] { steps.map { ($0.from, $0.amount) } }
  }

  /// The pieces of debt `movements` charged, each with how it was repaid: payments go to the
  /// oldest piece first; money paid beyond every piece waits on the card and covers the next
  /// charges before they become debt.
  static func lots(_ movements: [CreditMovement]) -> [Lot] {
    var lots: [Lot] = []
    var surplus = AmountE4.zero
    for movement in movements.sorted(by: CreditStatements.oldestFirst) {
      if movement.amountE4.raw < 0 {
        var amount = movement.amountE4.magnitude
        let covered = min(surplus, amount)
        surplus = surplus - covered
        amount = amount - covered
        guard amount.raw > 0 else { continue }
        lots.append(
          Lot(
            day: movement.day, isCashLike: movement.kind == .cashLike, isFee: movement.isFee,
            hasRecordedFee: movement.hasRecordedFee, amount: amount, remaining: amount,
            steps: [Lot.Step(from: movement.day, amount: amount)], repaidOn: nil))
      } else {
        var left = movement.amountE4
        for index in lots.indices where lots[index].remaining.raw > 0 && left.raw > 0 {
          let taken = min(left, lots[index].remaining)
          left = left - taken
          lots[index].remaining = lots[index].remaining - taken
          let step = Lot.Step(from: movement.day, amount: lots[index].remaining)
          if lots[index].steps.last?.from == movement.day {
            lots[index].steps[lots[index].steps.count - 1] = step
          } else {
            lots[index].steps.append(step)
          }
          if lots[index].remaining.isZero { lots[index].repaidOn = movement.day }
        }
        surplus += left
      }
    }
    return lots
  }

  /// Whether the grace period holds after `statements`: the latest one whose due day passed
  /// (or that is paid in full) was paid in full. Without such a statement it holds.
  static func graceKept(_ statements: [CreditStatement]) -> Bool {
    statements.last { $0.state != .waiting }?.state != .missed
  }

  /// The estimate of each statement in `statements` that charges anything, or that the owner
  /// recorded, and of the next statement after `through` (with days from a purchase: of
  /// `through` itself), oldest first. `recorded` are the sums recorded from the statements of
  /// this card, by `recordKey`.
  public static func estimates(
    terms: CreditCardTerms, statements: [CreditStatement], movements: [CreditMovement],
    recorded: [String: AmountE4], through: DateOnly
  ) -> [CreditInterestEstimate] {
    let lots = lots(movements)
    let calendar = CalendarContext.utc
    let cashRate = terms.cashRate ?? terms.purchaseRate
    var purchase: [DateOnly: Decimal] = [:]
    var cash: [DateOnly: Decimal] = [:]
    var fees: [DateOnly: AmountE4] = [:]
    var chargeDays: [DateOnly] = []

    switch terms.grace {
    case .statement(let day, _):
      let closed = statements.sorted { $0.closesOn < $1.closesOn }
      chargeDays = closed.map(\.closesOn)
      let next = CreditStatements.nextStatementDay(after: through, day: day, calendar: calendar)
      if chargeDays.last.map({ $0 < next }) ?? true { chargeDays.append(next) }

      for lot in lots {
        let free = lot.isCashLike && terms.cashWithoutGrace
        let own = closed.first { $0.holds(lot.day) }
        // The statement day the lot is charged in.
        let ownDay = own?.closesOn ?? chargeDays.first { $0 >= lot.day }
        if lot.isCashLike, !lot.isFee, !lot.hasRecordedFee, let ownDay {
          let fee = cashFee(amount: lot.amount, terms: terms)
          if !fee.isZero { fees[ownDay, default: .zero] += fee }
        }
        let rate = lot.isCashLike ? cashRate : terms.purchaseRate
        guard let rate, rate > 0 else { continue }
        // From which day on the interest of the lot is known and can be charged.
        let known: DateOnly
        if free {
          known = lot.day
        } else if let own {
          switch own.state {
          case .paidInFull: continue
          case .missed: known = own.due
          case .waiting:
            let before = closed.filter { $0.closesOn < own.closesOn }
            guard !graceKept(before) else { continue }
            known = lot.day
          }
        } else {
          guard !graceKept(closed) else { continue }
          known = lot.day
        }
        var after = lot.day
        for charge in chargeDays where charge >= known && charge > after {
          let earned = InterestMath.accrue(
            segments: lot.segments, percent: rate, after: after, through: charge)
          if earned != 0 {
            if lot.isCashLike {
              cash[charge, default: 0] += earned
            } else {
              purchase[charge, default: 0] += earned
            }
          }
          after = charge
          if lot.repaid(by: charge) { break }
        }
      }

    case .fromPurchase(let days):
      chargeDays = [through]
      let outstanding = lots.filter { !$0.repaid(by: through) }
      let lost = outstanding.contains { calendar.adding(days: days, to: $0.day) < through }
      for lot in lots {
        if lot.isCashLike, !lot.isFee, !lot.hasRecordedFee, lot.day <= through {
          let fee = cashFee(amount: lot.amount, terms: terms)
          if !fee.isZero { fees[through, default: .zero] += fee }
        }
        let free = lot.isCashLike && terms.cashWithoutGrace
        guard free || lost, lot.day < through else { continue }
        let rate = lot.isCashLike ? cashRate : terms.purchaseRate
        guard let rate, rate > 0 else { continue }
        let earned = InterestMath.accrue(
          segments: lot.segments, percent: rate, after: lot.day, through: through)
        if lot.isCashLike {
          cash[through, default: 0] += earned
        } else {
          purchase[through, default: 0] += earned
        }
      }
    }

    var byDay: [DateOnly: AmountE4] = [:]
    for (key, amount) in recorded {
      guard let day = recordedDay(key) else { continue }
      byDay[day] = amount
    }
    let days = Set(chargeDays).union(byDay.keys).sorted()
    return days.compactMap { day in
      let estimate = CreditInterestEstimate(
        statementDay: day, purchaseInterestE4: InterestMath.cents(purchase[day] ?? 0),
        cashInterestE4: InterestMath.cents(cash[day] ?? 0), cashFeesE4: fees[day] ?? .zero,
        recordedE4: byDay[day])
      guard estimate.recordedE4 != nil || !estimate.shownE4.isZero else { return nil }
      return estimate
    }
  }

  /// The fee for cash or a transfer: percent × amount + the fixed sum, to the kopeck.
  public static func cashFee(amount: AmountE4, terms: CreditCardTerms) -> AmountE4 {
    guard amount.raw > 0 else { return .zero }
    let percent = terms.cashFeePercent.map {
      InterestMath.cents(amount.magnitude.decimal * $0 / 100)
    }
    let fixed = terms.cashFeeFixedE4
    guard percent != nil || fixed != nil else { return .zero }
    return (percent ?? .zero) + (fixed ?? .zero)
  }

  /// `ccinterest:<account>:<YYYY-MM-DD>` — the expense of the interest of one statement.
  public static func recordKey(account: UUID, statementDay: DateOnly) -> String {
    "ccinterest:\(account.uuidString.lowercased()):\(statementDay.iso)"
  }

  /// The account and the statement day of a key of `recordKey`, or `nil` for another key.
  public static func parseKey(_ key: String?) -> (account: UUID, statementDay: DateOnly)? {
    guard let key else { return nil }
    let fields = key.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0] == "ccinterest",
      let account = UUID(uuidString: String(fields[1])),
      let day = DateOnly(iso: String(fields[2]))
    else { return nil }
    return (account, day)
  }

  /// The sums recorded from the statements of `accountId`, by `recordKey`: the live expenses
  /// that carry such a key, each by its amount.
  public static func recorded(
    of accountId: UUID, entries: [TransactionEntry]
  ) -> [String: AmountE4] {
    var result: [String: AmountE4] = [:]
    for entry in entries where !entry.transaction.isDeleted {
      guard let parsed = parseKey(entry.transaction.externalId), parsed.account == accountId
      else { continue }
      result[recordKey(account: accountId, statementDay: parsed.statementDay)] =
        entry.transaction.amountE4
    }
    return result
  }

  private static func recordedDay(_ key: String) -> DateOnly? {
    guard let tail = key.split(separator: ":").last else { return nil }
    return DateOnly(iso: String(tail))
  }
}
