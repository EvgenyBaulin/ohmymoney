import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation

/// One thing worth a second look.
///
/// Every anomaly carries the two numbers it is made of — what happened and what it is
/// measured against — so the screen can show the reasoning and not just the verdict.
public struct Anomaly: Hashable, Sendable, Identifiable {
  public var rule: AnomalyRule
  /// The rest of the identity: the part, the payment, the event, the category and the week.
  public var subject: String
  /// The day the anomaly is about; for a weekly rule, the Monday of that week.
  public var day: DateOnly
  /// What happened: the payment, the week's spending, the new price, the amount waiting.
  public var amount: AmountE4
  /// What it is measured against: the threshold, the usual week, the previous price, the
  /// budget. Zero when the rule has nothing to compare with.
  public var reference: AmountE4
  public var transactionId: UUID?
  public var partId: UUID?
  public var categoryId: UUID?
  public var personId: UUID?
  public var eventId: UUID?
  public var paymentId: UUID?
  /// Days the money has been waiting — «долгий возврат» and nothing else.
  public var days: Int?
  /// «Это нормально» was pressed on this one.
  public var isHidden: Bool

  public init(
    rule: AnomalyRule, subject: String, day: DateOnly, amount: AmountE4,
    reference: AmountE4 = .zero, transactionId: UUID? = nil, partId: UUID? = nil,
    categoryId: UUID? = nil, personId: UUID? = nil, eventId: UUID? = nil,
    paymentId: UUID? = nil, days: Int? = nil, isHidden: Bool = false
  ) {
    self.rule = rule
    self.subject = subject
    self.day = day
    self.amount = amount
    self.reference = reference
    self.transactionId = transactionId
    self.partId = partId
    self.categoryId = categoryId
    self.personId = personId
    self.eventId = eventId
    self.paymentId = paymentId
    self.days = days
    self.isHidden = isHidden
  }

  public var id: String { "\(rule.rawValue):\(subject)" }

  /// How much more than the reference, in basis points: 15 000 = half again as much.
  /// `nil` when there is nothing to compare with.
  public var excessBp: Int? {
    guard reference.raw > 0 else { return nil }
    let share = Decimal(amount.raw) * Decimal(Shares.whole) / Decimal(reference.raw)
    return (try? DecimalMath.int64(rounding: share)).map(Int.init)
  }
}

/// Everything the seven rules found, hidden ones included.
public struct AnomalyReport: Hashable, Sendable {
  /// Newest first; within a day, by rule and subject, so the order never depends on hashing.
  public var all: [Anomaly]
  /// Every anomaly that still arises at **any** sensitivity, hidden ones included. A dismissal
  /// outside this set is about something that no longer happens and may be forgotten — the
  /// same rule the reminders already live by (`ReminderRules.dismissed`). The level the owner
  /// chose only draws the line of what is shown: a week that is no spike to a low
  /// sensitivity is still one to a normal one, and its dismissal must outlive an evening at
  /// «low».
  public var activeKeys: Set<String>

  /// `activeKeys` defaults to what `all` holds — right for a report built at the most
  /// sensitive level, and for the reports tests build by hand.
  public init(all: [Anomaly] = [], activeKeys: Set<String>? = nil) {
    self.all = all
    self.activeKeys = activeKeys ?? Set(all.map(\.id))
  }

  public static let empty = AnomalyReport()

  public var visible: [Anomaly] { all.filter { !$0.isHidden } }
  public var hidden: [Anomaly] { all.filter(\.isHidden) }

  public func inside(_ period: Period) -> [Anomaly] {
    visible.filter { period.range.contains($0.day) }
  }
}

/// The seven anomaly rules, over one ledger.
public enum AnomalyRules {
  /// `events` comes from the planning snapshot the pipeline has already built: «событие
  /// сверх бюджета» is a question `EventPlanning` answers, and asking it twice would let
  /// the Planning screen and this one disagree.
  public static func build(
    ledger: Ledger, events: EventsPlanning = .empty, today: DateOnly,
    dismissals: [AnomalyDismissal] = [], options: AnomalyOptions = .standard()
  ) -> AnomalyReport {
    // One predicate, five rules. Written once so that «system categories and parts paid for
    // others stay out of the first five rules» cannot be true in four places and false in
    // the fifth.
    let mine = ledger.rows.filter(isMyOwnSpending)
    var found: [Anomaly] = []
    found += largePayments(in: mine, options: options)
    found += duplicates(in: mine, calendar: ledger.calendar, options: options)
    found += priceRises(in: mine)
    found += spikes(in: mine, ledger: ledger, today: today, options: options)
    found += badSpending(in: mine, ledger: ledger, today: today, options: options)
    found += slowReimbursements(in: ledger, today: today, options: options)
    found += eventsOverBudget(events, today: today)

    let hidden = Set(dismissals.map(\.key))
    for index in found.indices where hidden.contains(found[index].id) {
      found[index].isHidden = true
    }
    var arising = Set(found.map(\.id))
    // The levels are nested, so what the most sensitive one finds is what arises at all. Only
    // the three rules with a threshold that moves are asked again.
    let widest = options.mostSensitive
    if widest != options {
      arising.formUnion(largePayments(in: mine, options: widest).map(\.id))
      arising.formUnion(spikes(in: mine, ledger: ledger, today: today, options: widest).map(\.id))
      arising.formUnion(
        badSpending(in: mine, ledger: ledger, today: today, options: widest).map(\.id))
    }
    return AnomalyReport(all: found.sorted(by: precedes), activeKeys: arising)
  }

  /// My own spending and nothing else: not a system category, not a goal, not a payment on
  /// a debt, not money laid out for somebody else, not a line the app wrote for its books.
  ///
  /// The rules read `contribution`, so they see a refund where the ledger counts it: in the
  /// purchase it takes back from. A purchase refunded in full contributes nothing and is no
  /// large payment and nobody's duplicate; a refund's week is no spike of its own. Duplicates
  /// alone compare the checks (`amountRubE4`, before refunds): a charge made twice is the same
  /// charge whatever came back of one of them later.
  static func isMyOwnSpending(_ row: LedgerRow) -> Bool {
    row.kind == .expense && row.contribution.raw > 0 && row.systemRole == nil
      && !row.isGoalContribution && row.debtId == nil && !row.reimbursable
      && !(row.link?.isBookkeeping ?? false)
  }

  // MARK: - Крупная трата

  /// An amount above the steady threshold of its own category (the median and the MAD of its
  /// history, at least 10 operations). The threshold is the category's own: a weekly grocery
  /// run and a yearly insurance payment have nothing to say about each other.
  private static func largePayments(in rows: [LedgerRow], options: AnomalyOptions) -> [Anomaly] {
    var byCategory: [UUID: [LedgerRow]] = [:]
    for row in rows {
      guard let category = row.categoryId else { continue }
      byCategory[category, default: []].append(row)
    }
    var found: [Anomaly] = []
    for (category, rows) in byCategory where rows.count >= options.minimumOperations {
      let amounts = rows.map(\.contribution.raw)
      let middle = median(amounts)
      let deviation = median(amounts.map { abs($0 - middle) })
      // A category whose payments never vary has a deviation of zero, and every ruble above
      // the median would be an anomaly. The spread never falls below a share of the median.
      let spread = max(deviation, scaled(middle, byBp: options.minimumSpreadBp))
      let threshold = AmountE4(raw: middle + scaled(spread, byBp: options.deviationsBp))
      for row in rows where row.contribution > threshold {
        found.append(
          Anomaly(
            rule: .largeExpense, subject: key(row.partId), day: row.day,
            amount: row.contribution, reference: threshold, transactionId: row.transactionId,
            partId: row.partId, categoryId: category))
      }
    }
    return found
  }

  // MARK: - Возможный дубль

  /// The same amount and category within 10 minutes — the same operation entered twice,
  /// or the card charged twice. Two parts of one operation are not a duplicate of each other.
  ///
  /// The amount is the check — the part's rubles before refunds: 1,000 ₽ with 400 taken back
  /// and a 600 ₽ purchase next to it are two purchases, two checks of 1,000 ₽ are one charge
  /// made twice even after a refund of one. A twin refunded in full is gone from `rows`
  /// altogether (nothing is left of it): the double charge was taken back.
  ///
  /// Ten minutes need two moments somebody said. An operation dated a day typed without a
  /// time carries the app's noon of that day (`CalendarContext.noon(of:)`), which says
  /// nothing about minutes: it is nobody's duplicate — or every fare of that day would be
  /// one of every other.
  private static func duplicates(
    in rows: [LedgerRow], calendar: CalendarContext, options: AnomalyOptions
  ) -> [Anomaly] {
    struct Key: Hashable { var category: UUID; var amount: Int64 }
    var groups: [Key: [LedgerRow]] = [:]
    for row in rows where row.occurredAt != calendar.noon(of: row.day) {
      guard let category = row.categoryId else { continue }
      groups[Key(category: category, amount: row.amountRubE4.raw), default: []].append(row)
    }
    let window = TimeInterval(options.duplicateWindowSeconds)
    var found: [Anomaly] = []
    for (key, rows) in groups where rows.count > 1 {
      let ordered = rows.sorted {
        $0.occurredAt != $1.occurredAt
          ? $0.occurredAt < $1.occurredAt : $0.partId.uuidString < $1.partId.uuidString
      }
      for (index, row) in ordered.enumerated() where index > 0 {
        let before = ordered[index - 1]
        guard before.transactionId != row.transactionId,
          row.occurredAt.timeIntervalSince(before.occurredAt) <= window
        else { continue }
        found.append(
          Anomaly(
            rule: .possibleDuplicate, subject: self.key(row.partId), day: row.day,
            amount: row.amountRubE4, reference: before.amountRubE4,
            transactionId: row.transactionId, partId: row.partId, categoryId: key.category))
      }
    }
    return found
  }

  // MARK: - Рост цены подписки

  /// The price went up since the previous charge. The charges are the operations the
  /// app itself wrote for a scheduled payment (`sched:<payment>:<due>`), so this is about
  /// what was actually paid and not about the price announced in Planning.
  private static func priceRises(in rows: [LedgerRow]) -> [Anomaly] {
    struct Charge {
      var transactionId: UUID
      var day: DateOnly
      var occurredAt: Date
      var categoryId: UUID?
      var amount: AmountE4
    }
    var charges: [UUID: [UUID: Charge]] = [:]
    for row in rows {
      guard case .scheduled(let paymentId, _)? = row.link else { continue }
      var perTransaction = charges[paymentId] ?? [:]
      if var charge = perTransaction[row.transactionId] {
        charge.amount += row.contribution
        perTransaction[row.transactionId] = charge
      } else {
        perTransaction[row.transactionId] = Charge(
          transactionId: row.transactionId, day: row.day, occurredAt: row.occurredAt,
          categoryId: row.categoryId, amount: row.contribution)
      }
      charges[paymentId] = perTransaction
    }
    var found: [Anomaly] = []
    for (paymentId, perTransaction) in charges where perTransaction.count > 1 {
      let ordered = perTransaction.values.sorted {
        $0.occurredAt != $1.occurredAt
          ? $0.occurredAt < $1.occurredAt
          : $0.transactionId.uuidString < $1.transactionId.uuidString
      }
      guard let last = ordered.last, ordered.count >= 2 else { continue }
      let before = ordered[ordered.count - 2]
      guard last.amount > before.amount else { continue }
      found.append(
        Anomaly(
          rule: .subscriptionPriceRise, subject: key(paymentId), day: last.day,
          amount: last.amount, reference: before.amount, transactionId: last.transactionId,
          categoryId: last.categoryId, paymentId: paymentId))
    }
    return found
  }

  // MARK: - Всплеск в категории и рост плохих трат

  /// Spending of a week well above the usual level, by top-level category: a week of
  /// «Еда» says something, a week of «Кофе» is noise. The week compared is the last
  /// **complete** one — the week under way is still being lived in.
  private static func spikes(
    in rows: [LedgerRow], ledger: Ledger, today: DateOnly, options: AnomalyOptions
  ) -> [Anomaly] {
    guard let window = WeekWindow(today: today, ledger: ledger, options: options) else { return [] }
    var byCategory: [UUID: [LedgerRow]] = [:]
    for row in rows {
      guard let root = row.rootCategoryId else { continue }
      byCategory[root, default: []].append(row)
    }
    var found: [Anomaly] = []
    for (root, rows) in byCategory {
      guard let rise = window.rise(of: rows, options: options) else { continue }
      found.append(
        Anomaly(
          rule: .categorySpike, subject: "\(key(root)):\(window.last.iso)", day: window.last,
          amount: rise.amount, reference: rise.usual, categoryId: root))
    }
    return found
  }

  /// Bad spending of a week well above the usual level — the same arithmetic over
  /// the bad spending of every category at once.
  private static func badSpending(
    in rows: [LedgerRow], ledger: Ledger, today: DateOnly, options: AnomalyOptions
  ) -> [Anomaly] {
    guard let window = WeekWindow(today: today, ledger: ledger, options: options),
      let rise = window.rise(of: rows.filter { $0.quality == .bad }, options: options)
    else { return [] }
    return [
      Anomaly(
        rule: .badSpendingRise, subject: window.last.iso, day: window.last,
        amount: rise.amount, reference: rise.usual)
    ]
  }

  /// The last complete week and the weeks the usual level is taken from. Built once: both
  /// weekly rules ask the same question of the same weeks.
  private struct WeekWindow {
    /// The Monday of the last complete week.
    let last: DateOnly
    /// The Mondays of the weeks before it, oldest first.
    let before: [DateOnly]

    init?(today: DateOnly, ledger: Ledger, options: AnomalyOptions) {
      let thisWeek = today.adding(days: -(today.weekday - 1))
      let last = thisWeek.adding(days: -7)
      let before = (1...options.weeksOfHistory).map { last.adding(days: -7 * $0) }.reversed()
      // Weeks the history does not reach back to are not «usual», they are unknown.
      guard let first = before.first, let firstDay = ledger.firstDay, firstDay <= first else {
        return nil
      }
      self.last = last
      self.before = Array(before)
    }

    func weekStart(of day: DateOnly) -> DateOnly { day.adding(days: -(day.weekday - 1)) }

    /// What the last complete week cost and what such a week usually costs — when the usual
    /// level is worth comparing with at all, and the week is far enough above it.
    func rise(
      of rows: [LedgerRow], options: AnomalyOptions
    ) -> (amount: AmountE4, usual: AmountE4)? {
      var weeks: [DateOnly: Int64] = [:]
      for row in rows { weeks[weekStart(of: row.day), default: 0] += row.contribution.raw }
      let usual = median(before.map { weeks[$0] ?? 0 })
      guard usual >= options.weekFloor.raw else { return nil }
      let amount = weeks[last] ?? 0
      guard amount > usual + scaled(usual, byBp: options.weekExcessBp) else { return nil }
      return (AmountE4(raw: amount), AmountE4(raw: usual))
    }
  }

  // MARK: - Долгий возврат и событие сверх бюджета

  /// A part paid for somebody else has waited longer than N days for its money. This rule
  /// and the next are about the very things the first five leave out, so they read the
  /// whole ledger.
  ///
  /// The amount waiting is what is left of the part: money back may cover only some of it,
  /// and the part keeps waiting for the rest (`Ledger.remaining(ofPart:)`).
  private static func slowReimbursements(
    in ledger: Ledger, today: DateOnly, options: AnomalyOptions
  ) -> [Anomaly] {
    var found: [Anomaly] = []
    for row in ledger.rows
    where row.reimbursable && (row.reimbursementStatus ?? .expected) == .expected
      && !(row.link?.isBookkeeping ?? false)
    {
      let days = today.dayNumber - row.dayNumber
      guard days > options.slowReimbursementDays else { continue }
      let remaining = ledger.remaining(ofPart: row)
      guard remaining.raw > 0 else { continue }
      found.append(
        Anomaly(
          rule: .slowReimbursement, subject: key(row.partId), day: row.day,
          amount: remaining, transactionId: row.transactionId, partId: row.partId,
          categoryId: row.categoryId, personId: row.personId, days: days))
    }
    return found
  }

  /// The spending of an event is over its budget or on pace to go over — both questions are
  /// already answered by `EventPlan`, and answering them a second time here would let the
  /// Planning screen and this one disagree.
  private static func eventsOverBudget(_ events: EventsPlanning, today: DateOnly) -> [Anomaly] {
    events.withBudget.filter { $0.overBudget || $0.pacing }
      .map { plan in
        Anomaly(
          rule: .eventOverBudget, subject: key(plan.event.id),
          day: min(today, plan.event.endDate), amount: plan.spent,
          reference: plan.budget ?? .zero, eventId: plan.event.id)
      }
  }

  // MARK: - Arithmetic

  /// Newest first; inside a day by rule and subject, so the order never depends on hashing.
  private static func precedes(_ left: Anomaly, _ right: Anomaly) -> Bool {
    if left.day != right.day { return left.day > right.day }
    if left.rule != right.rule { return left.rule.rawValue < right.rule.rawValue }
    return left.subject < right.subject
  }

  private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

  /// The middle value; with an even count, the midpoint of the two middle ones — through
  /// `Decimal`, rounded half away from zero like every other amount (`IncomeEstimate.median`
  /// does the same), not an integer division that drops half a stored unit.
  static func median(_ values: [Int64]) -> Int64 {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
    let midpoint = (Decimal(sorted[middle - 1]) + Decimal(sorted[middle])) / 2
    return (try? DecimalMath.int64(rounding: midpoint)) ?? sorted[middle]
  }

  /// `raw × bp / 10 000`, through `Decimal` like every other money calculation.
  static func scaled(_ raw: Int64, byBp bp: Int) -> Int64 {
    let value = Decimal(raw) * Decimal(bp) / Decimal(Shares.whole)
    return (try? DecimalMath.int64(rounding: value)) ?? 0
  }
}
