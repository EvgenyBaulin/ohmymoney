import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// A half of a year: the reminder to check the credit history comes once in each.
public struct HalfYear: Hashable, Sendable, Comparable {
  public var year: Int
  /// `false` — January to June, `true` — July to December.
  public var second: Bool

  public init(year: Int, second: Bool) {
    self.year = year
    self.second = second
  }

  public init(containing day: DateOnly) {
    self.init(year: day.year, second: day.month > 6)
  }

  /// `YYYY-H1` or `YYYY-H2`.
  public var iso: String { "\(year)-H\(second ? 2 : 1)" }

  public init?(iso: String) {
    let parts = iso.trimmingCharacters(in: .whitespaces).split(separator: "-")
    guard parts.count == 2, let year = Int(parts[0]), parts[0].count == 4 else { return nil }
    switch parts[1] {
    case "H1": self.init(year: year, second: false)
    case "H2": self.init(year: year, second: true)
    default: return nil
    }
  }

  public static func < (lhs: HalfYear, rhs: HalfYear) -> Bool {
    lhs.year != rhs.year ? lhs.year < rhs.year : (!lhs.second && rhs.second)
  }
}

/// A reminder about debts and credit cards, shown as a line of «Стоит посмотреть».
public enum DebtReminder: Hashable, Sendable, Identifiable {
  /// File the application for the early repayment planned on `prepayOn` by `fileBy`.
  case prepayNotice(debtId: UUID, fileBy: DateOnly, prepayOn: DateOnly, amountE4: AmountE4)
  case pledgeDue(debtId: UUID, returnBy: DateOnly, overdue: Bool)
  /// The insurance of a loan can still be given back.
  case insuranceCooling(costId: UUID, debtId: UUID, until: DateOnly)
  case creditHistory(half: HalfYear)
  case cardPayBy(accountId: UUID, due: DateOnly, fullE4: AmountE4, minimumE4: AmountE4?)
  case cardGraceMissed(accountId: UUID, statementDay: DateOnly, estimateE4: AmountE4)

  /// The key «Готово» puts the reminder away by (`reminders.dismissed`).
  public var id: String {
    switch self {
    case .prepayNotice(let debtId, _, let prepayOn, _):
      "prepay:\(debtId.uuidString):\(prepayOn.iso)"
    case .pledgeDue(let debtId, let returnBy, _): "pledge:\(debtId.uuidString):\(returnBy.iso)"
    case .insuranceCooling(let costId, _, _): "insurance:\(costId.uuidString)"
    case .creditHistory(let half): "creditHistory:\(half.iso)"
    case .cardPayBy(let accountId, let due, _, _): "cardPayBy:\(accountId.uuidString):\(due.iso)"
    case .cardGraceMissed(let accountId, let statementDay, _):
      "cardGrace:\(accountId.uuidString):\(statementDay.iso)"
    }
  }
}

/// The reminders of the debts and credit cards, as lines of «Стоит посмотреть»:
///
/// * the application for an early repayment the owner planned, from `N` days before it
///   (`Debt.prepayNoticeDays`, one by default) through its day;
/// * a pledge due back, from seven days before «вернуть до» on, and after it — overdue — while
///   it is open;
/// * the insurance of a loan paid once, which can be given back for thirty days from its day;
/// * the credit history, from 1 February through June and from 1 August through December,
///   until the owner says it is done for the half, unless they turned the reminder off;
/// * a credit card to pay by its day, from five days before it, while something is to pay;
/// * a credit card whose grace period was lost, with the interest it likely charges.
///
/// A reminder put away («Готово») is left out by its key (`DebtReminder.id`).
public enum DebtReminders {
  /// An early repayment's application is filed a day before unless the debt says otherwise.
  public static let defaultNoticeDays = 1
  /// A pledge is reminded of this many days before it is due back.
  public static let pledgeDaysBefore = 7
  /// The days insurance of a loan can be given back.
  public static let insuranceCoolingDays = 30
  /// A credit card is reminded of this many days before its payment is due.
  public static let cardDaysBefore = 5

  public static func list(
    debts: [Debt], costs: [DebtCost], cards: [UUID: CreditCardNow], today: DateOnly,
    dismissed: Set<String>, creditHistoryEnabled: Bool, creditHistoryDone: HalfYear?
  ) -> [DebtReminder] {
    var result: [DebtReminder] = []
    let open = debts.filter { !$0.closed && !$0.isDeleted }
    let byId = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for debt in open.sorted(by: { $0.name < $1.name }) {
      if debt.direction == .iOwe, let planned = debt.plannedPrepay {
        let notice = max(0, debt.prepayNoticeDays ?? defaultNoticeDays)
        let fileBy = planned.day.adding(days: -notice)
        if today >= fileBy, today <= planned.day {
          result.append(
            .prepayNotice(
              debtId: debt.id, fileBy: fileBy, prepayOn: planned.day,
              amountE4: planned.amountE4))
        }
      }
      if debt.direction == .owedToMe, debt.pledge, let returnBy = debt.returnBy,
        today >= returnBy.adding(days: -pledgeDaysBefore)
      {
        result.append(.pledgeDue(debtId: debt.id, returnBy: returnBy, overdue: today > returnBy))
      }
    }
    for cost in costs
    where cost.kind == .insurance && cost.every == .once && byId[cost.debtId] != nil {
      let until = cost.day.adding(days: insuranceCoolingDays)
      if today >= cost.day, today <= until {
        result.append(.insuranceCooling(costId: cost.id, debtId: cost.debtId, until: until))
      }
    }
    if creditHistoryEnabled {
      let half = HalfYear(containing: today)
      let opens = DateOnly(year: half.year, month: half.second ? 8 : 2, day: 1)
      if today >= opens, creditHistoryDone.map({ $0 < half }) ?? true {
        result.append(.creditHistory(half: half))
      }
    }
    for (accountId, card) in cards.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      if let payBy = card.payBy, card.toPayNoInterestE4.raw > 0,
        today >= payBy.adding(days: -cardDaysBefore), today <= payBy
      {
        result.append(
          .cardPayBy(
            accountId: accountId, due: payBy, fullE4: card.toPayNoInterestE4,
            minimumE4: card.minimumE4))
      }
      if !card.graceKept, let estimate = card.estimate, estimate.shownE4.raw > 0 {
        result.append(
          .cardGraceMissed(
            accountId: accountId, statementDay: estimate.statementDay,
            estimateE4: estimate.shownE4))
      }
    }
    return result.filter { !dismissed.contains($0.id) }
  }
}
