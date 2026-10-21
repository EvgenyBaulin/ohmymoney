import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The half of the month the owner lives in now: from the income of the last term to the day of
/// the next one.
public struct PayHalf: Hashable, Sendable {
  public var start: DateOnly
  public var nextIncomeDay: DateOnly
  public var nextIncomeId: UUID
  /// The day of the next income passed without it: the half goes on.
  public var late: Bool

  public init(start: DateOnly, nextIncomeDay: DateOnly, nextIncomeId: UUID, late: Bool) {
    self.start = start
    self.nextIncomeDay = nextIncomeDay
    self.nextIncomeId = nextIncomeId
    self.late = late
  }
}

/// The halves of a month paid twice.
///
/// An income that comes more than once a month — the terms of one expectation («Ещё срок в
/// месяце» writes one expectation per term, alike in name, category and currency), or one
/// that comes every week — splits the month: a half runs from the day the income of the last
/// term came in and was linked, through the day of the next term, that day included — a payment
/// due on the day the money comes is paid from the half that ends. When the day of the next
/// term passes with no income linked to it, the half goes on (`late`): «Зарплата не пришла?».
public enum PayHalves {
  /// Only while a live expected income has two or more terms in a month.
  public static func current(
    today: DateOnly, expected: [ExpectedIncome], links: [ExpectedIncomeLink], ledger: Ledger
  ) -> PayHalf? {
    struct Term {
      var day: DateOnly
      var incomeId: UUID
      /// The day the income of the term came, when one is linked.
      var received: DateOnly?
    }
    let live = expected.filter { !$0.closed && $0.kind == .recurring }
    guard !live.isEmpty else { return nil }
    let from = today.monthKey.adding(months: -2).firstDay
    let through = today.monthKey.adding(months: 2).lastDay

    var linkedDays: [UUID: [(day: DateOnly, month: MonthKey)]] = [:]
    for link in links {
      guard let entry = ledger.entry(link.transactionId), entry.transaction.kind == .income,
        !entry.transaction.isDeleted, let part = entry.parts.first,
        let row = ledger.row(ofPart: part.id)
      else { continue }
      linkedDays[link.expectedIncomeId, default: []].append((row.day, row.month))
    }

    // Sources: terms of one income are alike in name, category and currency.
    var sources: [String: [ExpectedIncome]] = [:]
    for income in live {
      let key = [
        income.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        income.categoryId?.uuidString ?? "", income.currency.code,
      ].joined(separator: "|")
      sources[key, default: []].append(income)
    }

    var best: PayHalf?
    for incomes in sources.values {
      var terms: [Term] = []
      for income in incomes {
        let freq = income.freq ?? .monthly
        let dues = ExpectedIncomeRules.dueDates(
          of: income, freq: freq, through: through, today: today
        ).filter { $0 >= from }
        let days = linkedDays[income.id] ?? []
        for due in dues {
          let received = days.filter { linked in
            switch freq {
            case .monthly: linked.month == due.monthKey
            case .yearly: linked.month.year == due.year
            case .weekly: linked.day.weekStart == due.weekStart
            }
          }.map(\.day).min()
          terms.append(Term(day: due, incomeId: income.id, received: received))
        }
      }
      // Two terms in one month at least.
      var perMonth: [MonthKey: Set<DateOnly>] = [:]
      for term in terms { perMonth[term.day.monthKey, default: []].insert(term.day) }
      guard perMonth.values.contains(where: { $0.count >= 2 }) else { continue }
      terms.sort { $0.day < $1.day }

      // The last term received by today, and the first term after it not received.
      let lastReceived = terms.lastIndex { term in
        term.received.map { $0 <= today } ?? false
      }
      let nextIndex: Int?
      if let lastReceived {
        nextIndex = terms[(lastReceived + 1)...].firstIndex { $0.received == nil }
      } else {
        nextIndex = terms.firstIndex { $0.day >= today }
      }
      guard let nextIndex else { continue }
      let next = terms[nextIndex]
      let start: DateOnly
      if let lastReceived, let day = terms[lastReceived].received {
        start = day
      } else if nextIndex > 0 {
        start = terms[nextIndex - 1].day
      } else {
        start = today.monthKey.firstDay
      }
      let half = PayHalf(
        start: start, nextIncomeDay: next.day, nextIncomeId: next.incomeId,
        late: next.day < today)
      if best.map({ half.nextIncomeDay < $0.nextIncomeDay }) ?? true { best = half }
    }
    return best
  }
}

extension PlanningSnapshot {
  /// «До 25-го: X · в день Y»: the free sum through the day of the next term of the half — today
  /// when that day has passed —; `nil` without a half.
  public func halfFreeMoney(ledger: Ledger) -> FreeMoney? {
    guard let payHalf else { return nil }
    return freeMoney(until: max(today, payHalf.nextIncomeDay), ledger: ledger)
  }
}
