import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// Which due dates of the scheduled payments are paid, and by what: an operation «Mark as
/// paid» wrote (`sched:<payment>:<due>`), or an ordinary expense that is plainly the same
/// payment — the rent typed in the entry line instead of pressed «Провести». Worked out at
/// read time and never written: the owner makes a match real with «Привязать» or dismisses it
/// with «Это другое».
public struct ScheduledMatches: Hashable, Sendable {
  /// Due dates paid by a written link, by payment.
  private var linked: [UUID: Set<DateOnly>]
  /// Due dates paid by a matching ordinary operation, by payment, with that operation.
  private var matched: [UUID: [DateOnly: UUID]]

  /// The operations that pay a due date by matching — not the linked ones: the forecast
  /// leaves them out of its daily average, as it leaves out the linked ones by their key.
  /// Operations that matched a due date before `next_date` are in it too: that date is paid
  /// or skipped already, so they pay nothing any more, but they were planned payments all the
  /// same, not daily spending.
  public private(set) var operationIds: Set<UUID>

  public static let empty = ScheduledMatches(linked: [:], matched: [:])

  /// `earlier` are the operations that matched due dates before `next_date`.
  public init(
    linked: [UUID: Set<DateOnly>], matched: [UUID: [DateOnly: UUID]], earlier: Set<UUID> = []
  ) {
    self.linked = linked
    self.matched = matched
    self.operationIds = Set(matched.values.flatMap(\.values)).union(earlier)
  }

  /// The due date is paid: by a link or by a matching operation.
  public func isPaid(_ paymentId: UUID, _ due: DateOnly) -> Bool {
    isLinked(paymentId, due) || matched[paymentId]?[due] != nil
  }

  /// The due date is paid by an operation that carries its key (`sched:<payment>:<due>`).
  public func isLinked(_ paymentId: UUID, _ due: DateOnly) -> Bool {
    linked[paymentId]?.contains(due) == true
  }

  /// The ordinary operation that pays the due date by matching; `nil` when a link pays it, or
  /// nothing does.
  public func operation(for paymentId: UUID, _ due: DateOnly) -> UUID? {
    guard !isLinked(paymentId, due) else { return nil }
    return matched[paymentId]?[due]
  }

  /// The due dates of a payment paid by matching operations, with those operations.
  public func matchedDues(of paymentId: UUID) -> [DateOnly: UUID] {
    matched[paymentId] ?? [:]
  }
}

/// The rule that tells an ordinary expense paid a due date of a scheduled payment.
///
/// A due date `d` of a payment `P` — from its `next_date` on, as the dates before it are paid
/// or skipped already — is paid by a live operation `O` when all of these hold:
///
/// * `O` is an expense that carries no key of the app (`OperationLink`): nothing else claimed
///   it;
/// * one of its parts is filed under the category of `P` or under a subcategory of it; a
///   payment without a category asks the note of `O` to contain its name instead, in any case;
/// * in the currency of `P`, its amount is within max(1 unit, 10 % of the price on `d`) of
///   that price; in another currency — a dollar subscription typed in rubles as the bank
///   charged them — its rubles are within max(1 ₽, 10 %) of the price in rubles at the rate of
///   its day (`dayRates`, else today's `rubPerUnit`); without a rate it does not match;
/// * it is dated at most 5 days from `d`, and not after today (or the day the caller asks
///   about instead, `operationsThrough`);
/// * the owner did not say «Это другое» about this operation and this payment — about any due
///   date of it: the key `<operation>:<payment>:<YYYY-MM-DD>` in
///   `planning.scheduledMatchRejections` names the due date answered about only so the setting
///   can be pruned (`isRejected`).
///
/// Greedy and the same on every run: of every pair of a due date and an operation that could
/// pay it, the pair closest by day is taken first, then the one with the earlier due date,
/// then the payment by id, the earlier moment and the operation by id. An operation pays one
/// due date at most, and a due date is paid once. Across payments the nearest pair wins;
/// within one payment its operations pay its oldest due dates first — an operation between
/// last week's unpaid due and this week's pays last week's — and the passes repeat until
/// nothing more is taken.
///
/// The due dates before `next_date` of the history the forecast reads are matched the same way
/// afterwards, with the operations left: they are paid or skipped already, so the operations
/// found there pay nothing, but they are planned payments and stay out of the forecast's
/// daily average (`ScheduledMatches.operationIds`).
public enum ScheduledMatching {
  /// How many days an operation may be from the due date it pays.
  public static let dayWindow = 5
  /// How far the amount may be from the price, in percent of the price.
  public static let tolerancePercent = 10
  /// Due dates of one payment looked at, at most: a weekly payment left alone for years must
  /// not cost a pass per week.
  static let duesPerPayment = 400

  /// The text of one «Это другое»: the operation, the payment and the due date.
  public static func rejectionKey(operation: UUID, payment: UUID, due: DateOnly) -> String {
    "\(operation.uuidString.lowercased()):\(payment.uuidString.lowercased()):\(due.iso)"
  }

  /// Whether the owner said «Это другое» about `operation` and `payment`: a stored key of this
  /// pair names any due date of the payment. What the owner dismissed is ordinary spending for
  /// every due date of that payment, as the hint of the button promises.
  public static func isRejected(
    operation: UUID, payment: UUID, rejections: Set<String>
  ) -> Bool {
    rejectedPairs(rejections).contains(pairKey(operation: operation, payment: payment))
  }

  /// `<operation>:<payment>` of every stored key, lowercased.
  static func rejectedPairs(_ rejections: Set<String>) -> Set<String> {
    Set(
      rejections.compactMap { key in
        let fields = key.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        return "\(fields[0]):\(fields[1])".lowercased()
      })
  }

  static func pairKey(operation: UUID, payment: UUID) -> String {
    "\(operation.uuidString.lowercased()):\(payment.uuidString.lowercased())"
  }

  /// The day of a rejection, or `nil` when the text is not one: what the setting is pruned by.
  public static func rejectionDay(_ key: String) -> DateOnly? {
    let fields = key.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 3 else { return nil }
    return DateOnly(iso: String(fields[2]))
  }

  /// The rejections with `key` added and those whose due date is more than `keepDays` before
  /// `today` dropped, so the setting does not grow for ever.
  public static func rejections(
    adding key: String, to stored: Set<String>, today: DateOnly, keepDays: Int = 400
  ) -> Set<String> {
    let oldest = today.adding(days: -keepDays)
    return stored.filter { rejectionDay($0).map { $0 >= oldest } ?? false }.union([key])
  }

  /// «Привязать»: the operation keyed to the due date (`sched:<payment>:<due>`), as «Mark as
  /// paid» would have written it. Both go in one write.
  ///
  /// The payment moves on only when the due date is its `next_date`: then past it and past
  /// every later due date a key paid already (`matches`). A later due date leaves the payment
  /// where it is — an earlier due date is still unpaid and must stay due; the key is enough to
  /// mark the tied one paid.
  ///
  /// `eventId` — the event the due date belongs to (`ScheduledRules.event(of:due:events:)`) —
  /// goes onto every part that carries no event, so the payment counts in the event's
  /// «потрачено».
  public static func bind(
    _ operation: TransactionEntry, to payment: ScheduledPayment, due: DateOnly,
    matches: ScheduledMatches = .empty, eventId: UUID? = nil
  ) -> (operation: TransactionEntry, payment: ScheduledPayment) {
    var bound = operation
    bound.transaction.externalId =
      OperationLink.scheduled(paymentId: payment.id, due: due).externalId
    if let eventId {
      for index in bound.parts.indices where bound.parts[index].eventId == nil {
        bound.parts[index].eventId = eventId
      }
    }
    guard payment.nextDate == due else { return (bound, payment) }
    var moved = ScheduledRules.advanced(payment, past: due)
    var steps = 0
    while let next = moved.nextDate, matches.isLinked(payment.id, next), steps < duesPerPayment {
      moved = ScheduledRules.advanced(moved, past: next)
      steps += 1
    }
    return (bound, moved)
  }

  /// The due dates paid, as of `today`.
  ///
  /// `operationsThrough` — today when not said — is the last day an operation may be dated to
  /// pay a due date, and the due dates looked at reach `dayWindow` days past it: the free sum
  /// asks what is paid by now, the plan of the month's end what operations already typed for
  /// later days pay. The due dates before `next_date` are looked for back from `today` all
  /// the same.
  public static func matches(
    book: PlanningBook, ledger: Ledger, today: DateOnly, rejections: Set<String>,
    dayRates: DayRates = .empty, rubPerUnit: [CurrencyCode: Decimal] = [:],
    operationsThrough: DateOnly? = nil
  ) -> ScheduledMatches {
    let through = operationsThrough ?? today
    var linked: [UUID: Set<DateOnly>] = [:]
    for row in ledger.rows where row.isFirstPart {
      if case .scheduled(let paymentId, let due) = row.link {
        linked[paymentId, default: []].insert(due)
      }
    }

    // The operations that could pay something, by day number: live expenses nothing claimed.
    var candidates: [Int: [Candidate]] = [:]
    var anyCandidate = false
    for entry in ledger.dataset.entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense,
        OperationLink(externalId: transaction.externalId) == nil,
        let first = entry.parts.first, let row = ledger.row(ofPart: first.id), row.day <= through
      else { continue }
      candidates[row.day.dayNumber, default: []].append(
        Candidate(
          id: transaction.id, day: row.day, occurredAt: transaction.occurredAt,
          currency: transaction.currency, amount: transaction.amountE4,
          rubles: transaction.amountRubE4, categories: entry.parts.compactMap(\.categoryId),
          note: transaction.note))
      anyCandidate = true
    }

    var matched: [UUID: [DateOnly: UUID]] = [:]
    guard anyCandidate else { return ScheduledMatches(linked: linked, matched: matched) }
    let payments = book.scheduled.filter(\.active)
    let tree = ledger.tree
    let rejected = rejectedPairs(rejections)

    // Every pair of an unpaid due date and an operation that could pay it.
    func pairs(of payment: ScheduledPayment, dues: [DateOnly]) -> [Pair] {
      var result: [Pair] = []
      for due in dues where linked[payment.id]?.contains(due) != true {
        let price = SubscriptionMath.price(of: payment, on: due, prices: book.prices)
        let tolerance = max(
          AmountE4(whole: 1),
          SubscriptionMath.rounded(price.decimal * Decimal(tolerancePercent) / 100))
        for offset in -dayWindow...dayWindow {
          for candidate in candidates[due.dayNumber + offset] ?? [] {
            guard
              candidate.currency == payment.currency
                ? (candidate.amount - price).magnitude <= tolerance
                : closeInRubles(candidate, to: price, in: payment.currency),
              belongs(candidate, to: payment, tree: tree),
              !rejected.contains(pairKey(operation: candidate.id, payment: payment.id))
            else { continue }
            result.append(
              Pair(
                paymentId: payment.id, due: due, candidate: candidate, distance: abs(offset)))
          }
        }
      }
      return result
    }

    // An operation in another currency — a dollar subscription typed in rubles from the
    // bank's message — is compared in rubles: its own against the price at the rate of its day.
    func closeInRubles(
      _ candidate: Candidate, to price: AmountE4, in currency: CurrencyCode
    ) -> Bool {
      guard
        let rate = dayRates.perUnit(currency, on: candidate.day)
          ?? rubPerUnit[currency].flatMap({ $0 > 0 ? $0 : nil })
      else { return false }
      let priceRub = SubscriptionMath.rounded(price.decimal * rate)
      let tolerance = max(
        AmountE4(whole: 1),
        SubscriptionMath.rounded(priceRub.decimal * Decimal(tolerancePercent) / 100))
      return (candidate.rubles - priceRub).magnitude <= tolerance
    }

    var used: Set<UUID> = []
    // From `next_date` on: what is paid.
    var ahead: [Pair] = []
    // Before `next_date`, back to the start of the forecast's history: what was planned.
    var before: [Pair] = []
    let earliest = today.adding(days: -(MonthForecast.windowLength + dayWindow))
    for payment in payments {
      guard let next = payment.nextDate else { continue }
      let rule = RecurrenceRule(payment: payment)
      ahead += pairs(
        of: payment,
        dues: Recurrence.occurrences(
          from: next, through: through.adding(days: dayWindow), rule: rule, end: payment.endDate,
          limit: duesPerPayment))
      // A one-off payment has no due date before its only one.
      guard payment.endDate != next else { continue }
      before += pairs(of: payment, dues: dues(before: next, from: earliest, rule: rule))
    }
    // Which operations pay which payment: the nearest pairs first, across every payment.
    // Within one payment its operations then pay its oldest due dates: of every way they can
    // pay its due dates, the one whose due dates are the earliest (`earliestFirst`). An
    // operation a payment gave up that way stays with it — the matching only ever grows —, and
    // what is still free is offered again, until nothing more is taken.
    var byPayment: [UUID: [Pair]] = [:]
    for pair in ahead { byPayment[pair.paymentId, default: []].append(pair) }
    let sortedAhead = ahead.sorted(by: Pair.precedes)
    while true {
      var touched: Set<UUID> = []
      for pair in sortedAhead {
        guard !used.contains(pair.candidate.id), matched[pair.paymentId]?[pair.due] == nil
        else { continue }
        used.insert(pair.candidate.id)
        matched[pair.paymentId, default: [:]][pair.due] = pair.candidate.id
        touched.insert(pair.paymentId)
      }
      guard !touched.isEmpty else { break }
      for paymentId in touched {
        let operations = Set(matched[paymentId]?.values.map { $0 } ?? [])
        matched[paymentId] = earliestFirst(
          (byPayment[paymentId] ?? []).filter { operations.contains($0.candidate.id) })
      }
    }
    var earlier: Set<UUID> = []
    var earlierDues: Set<PaymentDue> = []
    for pair in before.sorted(by: Pair.precedes) {
      let key = PaymentDue(paymentId: pair.paymentId, due: pair.due)
      guard !used.contains(pair.candidate.id), !earlierDues.contains(key) else { continue }
      used.insert(pair.candidate.id)
      earlierDues.insert(key)
      earlier.insert(pair.candidate.id)
    }
    return ScheduledMatches(linked: linked, matched: matched, earlier: earlier)
  }

  /// The due dates of a schedule from `first` on and before `next`, `next` being one of them:
  /// the schedule stepped back from `next`, the way `Recurrence.next(after:rule:)` steps it
  /// forward.
  static func dues(before next: DateOnly, from first: DateOnly, rule: RecurrenceRule) -> [DateOnly]
  {
    var result: [DateOnly] = []
    var current = previous(before: next, rule: rule)
    while current >= first, result.count < duesPerPayment {
      result.append(current)
      current = previous(before: current, rule: rule)
    }
    return result.reversed()
  }

  /// The occurrence before `occurrence`: `interval` months, weeks or years earlier, on the day
  /// of the rule — the day of the month clipped to that month, the weekday within that week.
  static func previous(before occurrence: DateOnly, rule: RecurrenceRule) -> DateOnly {
    let interval = max(1, rule.interval)
    switch rule.freq {
    case .monthly:
      return Recurrence.clipped(
        day: rule.day ?? occurrence.day, in: occurrence.monthKey.adding(months: -interval))
    case .weekly:
      let shifted = occurrence.adding(days: -7 * interval)
      guard let weekday = rule.day, (1...7).contains(weekday) else { return shifted }
      return shifted.weekStart.adding(days: weekday - 1)
    case .yearly:
      let month = rule.month.flatMap { (1...12).contains($0) ? $0 : nil } ?? occurrence.month
      return Recurrence.clipped(
        day: rule.day ?? occurrence.day,
        in: MonthKey(year: occurrence.year - interval, month: month))
    }
  }

  /// The due dates `pairs` of one payment pay, oldest first: each due date in turn takes an
  /// operation — the nearest free one, or one moved off a later due date that another can take
  /// instead —, so as many due dates are paid as the operations can pay, and of those the
  /// earliest.
  private static func earliestFirst(_ pairs: [Pair]) -> [DateOnly: UUID] {
    var byDue: [DateOnly: [Pair]] = [:]
    for pair in pairs { byDue[pair.due, default: []].append(pair) }
    for due in byDue.keys {
      byDue[due]?.sort { left, right in
        if left.distance != right.distance { return left.distance < right.distance }
        if left.candidate.occurredAt != right.candidate.occurredAt {
          return left.candidate.occurredAt < right.candidate.occurredAt
        }
        return left.candidate.id.uuidString < right.candidate.id.uuidString
      }
    }
    var dueOf: [UUID: DateOnly] = [:]
    func take(_ due: DateOnly, _ seen: inout Set<UUID>) -> Bool {
      for pair in byDue[due] ?? [] where seen.insert(pair.candidate.id).inserted {
        if let other = dueOf[pair.candidate.id], !take(other, &seen) { continue }
        dueOf[pair.candidate.id] = due
        return true
      }
      return false
    }
    for due in byDue.keys.sorted() {
      var seen: Set<UUID> = []
      _ = take(due, &seen)
    }
    var result: [DateOnly: UUID] = [:]
    for (operation, due) in dueOf { result[due] = operation }
    return result
  }

  // MARK: - Pieces

  private struct Candidate {
    var id: UUID
    var day: DateOnly
    var occurredAt: Date
    var currency: CurrencyCode
    var amount: AmountE4
    var rubles: AmountE4
    var categories: [UUID]
    var note: String?
  }

  /// The category of the payment or one below it; without a category, the name in the note.
  private static func belongs(
    _ candidate: Candidate, to payment: ScheduledPayment, tree: CategoryTree
  ) -> Bool {
    guard let category = payment.categoryId else {
      let name = payment.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, let note = candidate.note else { return false }
      return note.range(of: name, options: [.caseInsensitive]) != nil
    }
    return candidate.categories.contains { isWithin($0, category, tree: tree) }
  }

  /// `id` is `ancestor` or sits somewhere under it.
  private static func isWithin(_ id: UUID, _ ancestor: UUID, tree: CategoryTree) -> Bool {
    var current: UUID? = id
    var steps = 0
    while let node = current, steps < 64 {
      if node == ancestor { return true }
      current = tree.parent(of: node)?.id
      steps += 1
    }
    return false
  }

  private struct PaymentDue: Hashable {
    var paymentId: UUID
    var due: DateOnly
  }

  /// A due date and an operation that could pay it, `distance` days apart.
  private struct Pair {
    var paymentId: UUID
    var due: DateOnly
    var candidate: Candidate
    var distance: Int

    /// Nearer by day, then the earlier due date, the payment by id, the earlier moment and the
    /// operation by id.
    static func precedes(_ left: Pair, _ right: Pair) -> Bool {
      if left.distance != right.distance { return left.distance < right.distance }
      if left.due != right.due { return left.due < right.due }
      if left.paymentId != right.paymentId {
        return left.paymentId.uuidString < right.paymentId.uuidString
      }
      if left.candidate.occurredAt != right.candidate.occurredAt {
        return left.candidate.occurredAt < right.candidate.occurredAt
      }
      return left.candidate.id.uuidString < right.candidate.id.uuidString
    }
  }
}
