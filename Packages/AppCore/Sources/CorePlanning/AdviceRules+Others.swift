import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

// MARK: - Subscriptions, events, «for whom», cashback

extension AdviceRules {
  /// Complete months the «for whom» trend and the cashback look back over.
  static let recentMonths = 3
  /// Payment methods the cashback names at most.
  static let methodsShown = 5

  /// What came back for a closed part: its links, plus the drift of rates that closed it when
  /// nothing — no shortfall, no remainder written off — was written for the rest.
  private static func returnedOfClosed(_ row: LedgerRow, ledger: Ledger) -> AmountE4 {
    let links = ledger.returned(forPart: row.partId)
    let written = ledger.companionsRub(forPart: row.partId)
    let drift = row.amountRubE4 - links - written.shortfall - written.writtenOff
    guard drift.raw > 0, written.shortfall.isZero, written.writtenOff.isZero,
      drift <= MoneyBack.tolerance(partRub: row.amountRubE4, foreignInvolved: true)
    else { return links }
    return links + drift
  }

  /// Subscriptions («сумма в месяц и в год»): the running subscriptions, what their next
  /// charges come to a month and a year (the snapshot's totals). None running: no suggestion.
  /// A one-off is one charge and not a running subscription, as in the totals.
  static func subscriptions(
    scheduled: [ScheduledStatus], monthly: AmountE4, yearly: AmountE4
  ) -> [Advice] {
    let count = scheduled.filter { $0.payment.kind == .subscription && !$0.isOneOff }.count
    guard count > 0 else { return [] }
    return [
      Advice(
        id: AdviceBook.id(.subscriptions, nil), kind: .subscriptions,
        terms: [
          AdviceTerm(key: Key.subscriptionsCount, value: .count(count)),
          AdviceTerm(key: Key.subscriptionsYearly, value: .money(yearly)),
        ],
        result: AdviceTerm(key: Key.subscriptionsMonthly, op: .equals, value: .money(monthly)))
    ]
  }

  /// Subscriptions and bills paid for others («за других — сколько заплачено и сколько
  /// вернули»), over the last twelve months through today.
  ///
  /// The operations are the ones «Mark as paid» wrote for a payment the owner gets back
  /// (`sched:` links of a reimbursable payment). Paid is their rubles, all parts; returned is
  /// the money that came back for the parts (`Ledger.returned(forPart:)`, Σ of live links, so
  /// a part closed short counts what really came); waiting — what is left of the parts still
  /// expected, since money back may cover only some of a part; what it cost me is the rest: my
  /// own share, what was written off, what a closed part fell short by. A part closed within the
  /// drift of rates (`MoneyBack.tolerance`) with nothing written for the rest counts as all
  /// returned: the drift is no spending, as «За других» shows no shortfall for it. No such
  /// payment: no suggestion; no operation yet: «not enough data».
  static func subscriptionsForOthers(_ context: AdviceContext, book: PlanningBook) -> [Advice] {
    let payments = Set(book.scheduled.filter(\.reimbursable).map(\.id))
    guard !payments.isEmpty else { return [] }
    let today = context.today
    let window = DayRange(today.adding(months: -12).adding(days: 1), today)
    var paid = AmountE4.zero
    var returned = AmountE4.zero
    var waiting = AmountE4.zero
    var operations: Set<UUID> = []
    for row in context.ledger.rows(in: window) {
      guard case .scheduled(let paymentId, _) = row.link, payments.contains(paymentId),
        row.kind == .expense
      else { continue }
      operations.insert(row.transactionId)
      paid += row.amountRubE4
      guard row.reimbursable else { continue }
      switch row.reimbursementStatus {
      case .returned: returned += returnedOfClosed(row, ledger: context.ledger)
      case .expected:
        returned += context.ledger.returned(forPart: row.partId)
        waiting += context.ledger.remaining(ofPart: row)
      case .writtenOff, nil: break
      }
    }
    guard !operations.isEmpty else {
      return [.notEnoughData(.subscriptionsForOthers, reason: Reason.nothingPaidForOthers)]
    }
    return [
      Advice(
        id: AdviceBook.id(.subscriptionsForOthers, nil), kind: .subscriptionsForOthers,
        terms: [
          AdviceTerm(key: Key.forOthersPaid, op: .plus, value: .money(paid)),
          AdviceTerm(key: Key.forOthersReturned, op: .minus, value: .money(returned)),
          AdviceTerm(key: Key.forOthersWaiting, op: .minus, value: .money(waiting)),
        ],
        result: AdviceTerm(
          key: Key.forOthersCostMe, op: .equals, value: .money(paid - returned - waiting)),
        notes: [
          AdviceTerm(key: Key.forOthersPayments, value: .count(payments.count)),
          AdviceTerm(key: Key.forOthersOperations, value: .count(operations.count)),
        ])
    ]
  }

  /// The nearest event to save for («сколько откладывать в месяц до ближайшего события,
  /// исходя из бюджета или прошлогодних трат»): the first upcoming event with a target — its
  /// budget, else what the previous one of its series cost — and `EventPlan.monthlySaving`:
  /// max(0, target − spent) ÷ max(1, months until it starts). Upcoming events, but none with
  /// a target: «not enough data» for the nearest one; no upcoming event: no suggestion.
  static func eventSaving(_ events: EventsPlanning) -> [Advice] {
    guard let nearest = events.upcoming.first else { return [] }
    guard let plan = events.upcoming.first(where: { $0.monthlySaving != nil }),
      let target = plan.target, let saving = plan.monthlySaving
    else {
      return [
        .notEnoughData(
          .eventSaving, reason: Reason.eventNoTarget, subject: .event(nearest.event.name),
          idSuffix: nearest.event.id.uuidString.lowercased())
      ]
    }
    return [
      Advice(
        id: AdviceBook.id(.eventSaving, plan.event.id), kind: .eventSaving,
        subject: .event(plan.event.name),
        terms: [
          AdviceTerm(
            key: plan.budget != nil ? Key.eventBudget : Key.eventLastTime, op: .plus,
            value: .money(target)),
          AdviceTerm(key: Key.eventSpent, op: .minus, value: .money(plan.spent)),
          AdviceTerm(key: Key.eventMonths, value: .months(max(1, plan.monthsUntilStart))),
        ],
        result: AdviceTerm(key: Key.eventMonthlySaving, op: .equals, value: .money(saving)),
        notes: [AdviceTerm(key: Key.eventStart, value: .date(plan.event.startDate))])
    ]
  }

  /// Spending for others («доля трат на других и её динамика»): the share of my spending
  /// this month to date whose «for whom» is not «me», and the same share in each of the last
  /// three complete months and over the three together — `ForWhomReport`, so the figures are
  /// the ones of the «For whom» section. No spending at all: «not enough data»; nothing for
  /// others anywhere: no suggestion.
  static func forWhomShare(_ context: AdviceContext) -> [Advice] {
    let ledger = context.ledger
    let current = split(
      ForWhomReport(ledger: ledger, period: .monthToDate(today: context.today)).values)
    let months = context.completeMonths(recentMonths)
    var history: [(others: AmountE4, total: AmountE4)] = []
    if let first = months.first, let last = months.last {
      let report = ForWhomReport(
        ledger: ledger, period: .days(DayRange(first.firstDay, last.lastDay)))
      history = report.months.map { month in
        let others = AmountE4.sum(month.amounts.filter { $0.key != .me }.map(\.value))
        return (others, AmountE4.sum(month.amounts.values))
      }
    }
    guard current.total.raw > 0 || history.contains(where: { $0.total.raw > 0 }) else {
      return [.notEnoughData(.forWhomShare, reason: Reason.noSpending)]
    }
    guard !current.others.isZero || history.contains(where: { !$0.others.isZero }) else {
      return []
    }

    var terms: [AdviceTerm] = []
    var result: AdviceTerm?
    if current.total.raw > 0, let share = Shares.ratio(current.others, of: current.total) {
      terms = [
        AdviceTerm(key: Key.forOthersThisMonth, value: .money(current.others)),
        AdviceTerm(key: Key.spentThisMonth, value: .money(current.total)),
      ]
      result = AdviceTerm(key: Key.forOthersShare, op: .equals, value: .basisPoints(share))
    }
    var notes: [AdviceTerm] = []
    // Last month first: 1 month ago, 2 months ago, 3 months ago.
    for (offset, month) in history.reversed().enumerated() {
      guard let share = Shares.ratio(month.others, of: month.total) else { continue }
      notes.append(
        AdviceTerm(key: Key.forOthersShare(monthsAgo: offset + 1), value: .basisPoints(share)))
    }
    if let average = Shares.ratio(
      AmountE4.sum(history.map(\.others)), of: AmountE4.sum(history.map(\.total)))
    {
      notes.append(AdviceTerm(key: Key.forOthersShareAverage, value: .basisPoints(average)))
    }
    return [
      Advice(
        id: AdviceBook.id(.forWhomShare, nil), kind: .forWhomShare, terms: terms, result: result,
        notes: notes)
    ]
  }

  /// Σ for others and Σ of all the «for whom» values of a breakdown.
  private static func split(_ nodes: [BreakdownNode]) -> (others: AmountE4, total: AmountE4) {
    var others = AmountE4.zero
    var total = AmountE4.zero
    for node in nodes {
      total += node.amount
      if case .forWhom(let value) = node.key, value != .me { others += node.amount }
    }
    return (others, total)
  }

  /// Cashback by payment method («фактическая доля кэшбэка по способам за последние
  /// месяцы — только цифры»): `PaymentMethodsReport` over the last three complete months —
  /// cashback ÷ turnover of every method with a turnover, the way the Payment methods section
  /// has it. No cashback category set, or no cashback at all: no suggestion; no complete
  /// month: «not enough data».
  static func cashback(_ context: AdviceContext) -> [Advice] {
    let ledger = context.ledger
    guard ledger.dataset.settings.cashbackCategoryId != nil else { return [] }
    let months = context.completeMonths(recentMonths)
    guard let first = months.first, let last = months.last else {
      return [.notEnoughData(.cashback, reason: Reason.noCompleteMonth)]
    }
    let report = PaymentMethodsReport(
      ledger: ledger, period: .days(DayRange(first.firstDay, last.lastDay)))
    let methods = report.methods.compactMap { method -> (UUID, PaymentMethodsReport.Method)? in
      guard case .paymentMethod(let id) = method.key, method.turnover.raw > 0 else { return nil }
      return (id, method)
    }
    guard methods.contains(where: { !$0.1.cashback.isZero }) else { return [] }
    return methods.prefix(methodsShown).compactMap { id, method in
      guard let share = method.cashbackShare else { return nil }
      return Advice(
        id: AdviceBook.id(.cashback, id), kind: .cashback,
        subject: .paymentMethod(context.methodName(id)),
        terms: [
          AdviceTerm(key: Key.cashbackReceived, value: .money(method.cashback)),
          AdviceTerm(key: Key.cashbackTurnover, value: .money(method.turnover)),
        ],
        result: AdviceTerm(key: Key.cashbackShare, op: .equals, value: .basisPoints(share)),
        notes: [AdviceTerm(key: Key.monthsCounted, value: .count(months.count))])
    }
  }
}
