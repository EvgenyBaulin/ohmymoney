import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// Which due dates of the scheduled payments are paid, and by what: an operation «Mark as
/// paid» wrote (`sched:<payment>:<due>`), an ordinary expense plainly matching the payment, or
/// parts that reach the price or have an answer to close the rest.
public struct ScheduledMatches: Hashable, Sendable {
  /// Due dates paid by a written link, by payment.
  private var linked: [UUID: Set<DateOnly>]
  /// Due dates paid by a matching ordinary operation, by payment, with that operation.
  private var matched: [UUID: [DateOnly: UUID]]
  /// Due dates paid in parts by smaller operations of the payment's category, by payment.
  private var partial: [UUID: [DateOnly: DueParts]]

  /// The operations that pay a due date by matching — not the linked ones: the forecast
  /// leaves them out of its daily average, as it leaves out the linked ones by their key.
  /// Operations that matched a due date before `next_date` are in it too: that date is paid
  /// or skipped already, so they pay nothing any more, but they were planned payments all the
  /// same, not daily spending.
  public private(set) var operationIds: Set<UUID>

  public static let empty = ScheduledMatches(linked: [:], matched: [:])

  /// `earlier` are the operations that matched due dates before `next_date`, whole or in
  /// parts; `partial` are the due dates from `next_date` on paid in parts.
  public init(
    linked: [UUID: Set<DateOnly>], matched: [UUID: [DateOnly: UUID]],
    partial: [UUID: [DateOnly: DueParts]] = [:], earlier: Set<UUID> = []
  ) {
    self.linked = linked
    self.matched = matched
    self.partial = partial
    self.operationIds = Set(matched.values.flatMap(\.values))
      .union(partial.values.flatMap { $0.values.flatMap(\.operations) })
      .union(earlier)
  }

  /// The due date is closed: by a link, a matching operation, enough parts, or the saved answer
  /// to close their shortfall.
  public func isPaid(_ paymentId: UUID, _ due: DateOnly) -> Bool {
    isLinked(paymentId, due) || matched[paymentId]?[due] != nil
      || partial[paymentId]?[due]?.isComplete == true
  }

  /// The parts that pay the due date — paid in full or not yet —; `nil` when no part does.
  public func parts(_ paymentId: UUID, _ due: DateOnly) -> DueParts? {
    guard !isLinked(paymentId, due) else { return nil }
    return partial[paymentId]?[due]
  }

  /// The due dates of a payment paid in parts, with those parts.
  public func partDues(of paymentId: UUID) -> [DateOnly: DueParts] {
    partial[paymentId] ?? [:]
  }

  /// The ordinary operations to key when the payment moves past `due` — «Провести» or
  /// «Пропустить» —, oldest due date first: those that pay a due date from `from` (its
  /// `next_date`) on and before `due` whole, and the parts of every due date from `from`
  /// through `due` itself. Once `next_date` is past them nothing matches them any more:
  /// unkeyed, what they paid would drop out of the month's funding and back into the daily
  /// spending the forecast reads.
  public func toKey(
    _ paymentId: UUID, from: DateOnly, through due: DateOnly
  ) -> [(due: DateOnly, operation: UUID)] {
    var result: [(due: DateOnly, operation: UUID)] = []
    for (paid, operation) in matchedDues(of: paymentId) where paid >= from && paid < due {
      result.append((paid, operation))
    }
    for (paid, parts) in partDues(of: paymentId) where paid >= from && paid <= due {
      for operation in parts.operations { result.append((paid, operation)) }
    }
    return result.sorted { left, right in
      left.due != right.due
        ? left.due < right.due : left.operation.uuidString < right.operation.uuidString
    }
  }

  /// What is still to pay of the due date whose price is `price`: nothing when it is paid, the
  /// price less its parts when some are paid, else the price. In the payment's currency.
  public func unpaid(_ paymentId: UUID, _ due: DateOnly, price: AmountE4) -> AmountE4 {
    guard !isPaid(paymentId, due) else { return .zero }
    guard let parts = parts(paymentId, due) else { return price }
    return max(.zero, price - parts.paidE4)
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

/// The smaller operations that pay one due date of a scheduled payment in parts: rent of
/// 60 000 paid 30 000 two days before its day and 30 000 three days after it.
public struct DueParts: Hashable, Sendable {
  /// The operations, oldest first.
  public var operations: [UUID]
  /// What they paid together, in the payment's currency.
  public var paidE4: AmountE4
  /// The price of the due date, in the payment's currency.
  public var priceE4: AmountE4
  /// The allowance one operation gets (`ScheduledMatching.tolerance(of:)`); a sum within it
  /// prompts whether to close the rest.
  public var toleranceE4: AmountE4
  /// The answer about closing the shortfall, if one was saved for this due date.
  public var answer: ScheduledPartAnswer?

  public init(
    operations: [UUID], paidE4: AmountE4, priceE4: AmountE4, toleranceE4: AmountE4 = .zero,
    answer: ScheduledPartAnswer? = nil
  ) {
    self.operations = operations
    self.paidE4 = paidE4
    self.priceE4 = priceE4
    self.toleranceE4 = toleranceE4
    self.answer = answer
  }

  /// The parts pay the due date when they reach its price or the owner chose to close the rest.
  public var isComplete: Bool { paidE4 >= priceE4 || answer == .close }

  /// The parts fall within one operation's tolerance but have not yet reached the price, and
  /// the owner has not answered whether to close the rest.
  public var needsCloseDecision: Bool {
    answer == nil && paidE4 < priceE4 && paidE4 >= priceE4 - toleranceE4
  }

  /// The price less what the parts paid: what is left to pay while the due date is open, what
  /// they fell short by once it is paid («оплачено 58 000 из 60 000»).
  public var remainingE4: AmountE4 { max(.zero, priceE4 - paidE4) }
}

/// The answer to whether a due date should close before its parts reach the full price.
public enum ScheduledPartAnswer: String, Hashable, Sendable, CaseIterable {
  case close
  case keep
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
/// A payment may be paid in parts. Of the operations left over, those that would pay a due date
/// of a payment with a category but for their amount — less than its price, in its own
/// currency — pay part of the due date that has no link and no single operation paying it.
/// A part may come late: up to 5 days before the due date, and after it on any day before the
/// next due date of the payment — the rest of the rent paid ten days late is still the rent; a
/// one-off payment, with no next due date, keeps 5 days after its day. Each part pays one due
/// date: the payment of its nearest pair, as above, and within that payment its oldest due
/// date still short of its price, the parts taken by moment. A due date paid in parts closes
/// once their sum reaches its price. Between 90 % and the price, it waits for an answer about
/// closing the rest; «Оставить» keeps it open without asking again. «Это другое» lets a part go
/// just as it lets a whole payment go.
///
/// The due dates before `next_date` of the history the forecast reads are matched the same way
/// afterwards, whole and in parts, with the operations left: they are paid or skipped already,
/// so the operations found there pay nothing, but they are planned payments and stay out of
/// the forecast's daily average (`ScheduledMatches.operationIds`).
public enum ScheduledMatching {
  /// How many days an operation may be from the due date it pays.
  public static let dayWindow = 5
  /// How far the amount may be from the price, in percent of the price.
  public static let tolerancePercent = 10
  /// Due dates of one payment looked at, at most: a weekly payment left alone for years must
  /// not cost a pass per week.
  static let duesPerPayment = 400

  /// How far from `price` one operation may be and still pay it: max(1 unit, 10 %).
  public static func tolerance(of price: AmountE4) -> AmountE4 {
    max(
      AmountE4(whole: 1),
      SubscriptionMath.rounded(price.decimal * Decimal(tolerancePercent) / 100))
  }

  /// The text of one «Это другое»: the operation, the payment and the due date.
  public static func rejectionKey(operation: UUID, payment: UUID, due: DateOnly) -> String {
    "\(operation.uuidString.lowercased()):\(payment.uuidString.lowercased()):\(due.iso)"
  }

  /// A saved answer about whether parts close their due date.
  public static func partAnswerKey(
    _ answer: ScheduledPartAnswer, payment: UUID, due: DateOnly
  ) -> String {
    "part-answer:\(payment.uuidString.lowercased()):\(due.iso):\(answer.rawValue)"
  }

  /// The answer saved for this due date, if any.
  public static func partAnswer(
    payment: UUID, due: DateOnly, in stored: Set<String>
  ) -> ScheduledPartAnswer? {
    ScheduledPartAnswer.allCases.first {
      stored.contains(partAnswerKey($0, payment: payment, due: due))
    }
  }

  /// Replace the answer for this due date and discard saved answers and rejections older than
  /// `keepDays`, so one-off due dates do not grow the setting indefinitely.
  public static func partAnswers(
    adding answer: ScheduledPartAnswer, payment: UUID, due: DateOnly, to stored: Set<String>,
    today: DateOnly, keepDays: Int = 400
  ) -> Set<String> {
    let oldest = today.adding(days: -keepDays)
    let answerPrefix = "part-answer:\(payment.uuidString.lowercased()):\(due.iso):"
    return stored.filter { key in
      guard let day = storedDay(key), day >= oldest else { return false }
      return !key.hasPrefix(answerPrefix)
    }.union([partAnswerKey(answer, payment: payment, due: due)])
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
    return stored.filter { storedDay($0).map { $0 >= oldest } ?? false }.union([key])
  }

  private static func storedDay(_ key: String) -> DateOnly? {
    if let due = rejectionDay(key) { return due }
    let fields = key.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 4, fields[0] == "part-answer",
      UUID(uuidString: String(fields[1])) != nil,
      ScheduledPartAnswer(rawValue: String(fields[3])) != nil
    else { return nil }
    return DateOnly(iso: String(fields[2]))
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
    matches: ScheduledMatches = .empty, eventId: UUID? = nil, asPart: Bool = false
  ) -> (operation: TransactionEntry, payment: ScheduledPayment) {
    var bound = operation
    // A part keeps a key of its own: the rest written for the same due date takes the plain one.
    bound.transaction.externalId =
      asPart
      ? OperationLink.scheduledPartExternalId(
        paymentId: payment.id, due: due, operation: operation.transaction.id)
      : OperationLink.scheduled(paymentId: payment.id, due: due).externalId
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

    // Every pair of an unpaid due date and an operation in the payment's currency smaller
    // than its price that could pay part of it.
    // `open`: the due dates from `next_date` on, which wait for their rest after their day; one
    // before it is paid or skipped already and keeps 5 days either side.
    func partPairs(of payment: ScheduledPayment, dues: [DateOnly], open: Bool) -> [Pair] {
      var result: [Pair] = []
      let rule = RecurrenceRule(payment: payment)
      for due in dues where linked[payment.id]?.contains(due) != true {
        let price = SubscriptionMath.price(of: payment, on: due, prices: book.prices)
        // After the due date, up to the day before the next one; a one-off keeps 5 days.
        let following = Recurrence.next(after: due, rule: rule)
        let hasNext = payment.endDate.map { following <= $0 } ?? true
        let after =
          open && hasNext ? max(dayWindow, due.days(to: following) - 1) : dayWindow
        for offset in -dayWindow...after {
          for candidate in candidates[due.dayNumber + offset] ?? [] {
            guard !used.contains(candidate.id), candidate.currency == payment.currency,
              candidate.amount < price, belongs(candidate, to: payment, tree: tree),
              !rejected.contains(pairKey(operation: candidate.id, payment: payment.id))
            else { continue }
            result.append(
              Pair(
                paymentId: payment.id, due: due, candidate: candidate, distance: abs(offset),
                price: price))
          }
        }
      }
      return result
    }

    // Parts: the operations left, smaller than the price, on the due dates nothing paid whole.
    var partial: [UUID: [DateOnly: DueParts]] = [:]
    var partsAhead: [Pair] = []
    var partsBefore: [Pair] = []
    for payment in payments {
      guard let next = payment.nextDate, payment.categoryId != nil else { continue }
      let rule = RecurrenceRule(payment: payment)
      let open = Recurrence.occurrences(
        from: next, through: through.adding(days: dayWindow), rule: rule, end: payment.endDate,
        limit: duesPerPayment
      ).filter { matched[payment.id]?[$0] == nil }
      partsAhead += partPairs(of: payment, dues: open, open: true)
      guard payment.endDate != next else { continue }
      partsBefore += partPairs(
        of: payment,
        dues: dues(before: next, from: earliest, rule: rule).filter {
          !earlierDues.contains(PaymentDue(paymentId: payment.id, due: $0))
        }, open: false)
    }
    for (pair, price) in parted(partsAhead, used: &used, answers: rejections) {
      let answer = partAnswer(payment: pair.paymentId, due: pair.due, in: rejections)
      var parts =
        partial[pair.paymentId]?[pair.due]
        ?? DueParts(
          operations: [], paidE4: .zero, priceE4: price, toleranceE4: tolerance(of: price),
          answer: answer)
      parts.operations.append(pair.candidate.id)
      parts.paidE4 += pair.candidate.amount
      partial[pair.paymentId, default: [:]][pair.due] = parts
    }
    for (pair, _) in parted(partsBefore, used: &used, answers: rejections) {
      earlier.insert(pair.candidate.id)
    }
    return ScheduledMatches(linked: linked, matched: matched, partial: partial, earlier: earlier)
  }

  /// Which part pays which due date, in the order the parts were taken: each operation goes to
  /// the payment of its nearest pair, and within that payment to its oldest due date still
  /// open, the operations of one due date taken by moment.
  private static func parted(
    _ pairs: [Pair], used: inout Set<UUID>, answers: Set<String>
  ) -> [(pair: Pair, price: AmountE4)] {
    var owner: [UUID: UUID] = [:]
    for pair in pairs.sorted(by: Pair.precedes) where owner[pair.candidate.id] == nil {
      owner[pair.candidate.id] = pair.paymentId
    }
    let owned = pairs.filter { owner[$0.candidate.id] == $0.paymentId }
    var byDue: [PaymentDue: [Pair]] = [:]
    for pair in owned {
      byDue[PaymentDue(paymentId: pair.paymentId, due: pair.due), default: []].append(pair)
    }
    let order = byDue.keys.sorted { left, right in
      if left.paymentId != right.paymentId {
        return left.paymentId.uuidString < right.paymentId.uuidString
      }
      return left.due < right.due
    }
    var result: [(pair: Pair, price: AmountE4)] = []
    for key in order {
      var paid = AmountE4.zero
      let sorted = (byDue[key] ?? []).sorted { left, right in
        if left.candidate.occurredAt != right.candidate.occurredAt {
          return left.candidate.occurredAt < right.candidate.occurredAt
        }
        return left.candidate.id.uuidString < right.candidate.id.uuidString
      }
      let answer = partAnswer(payment: key.paymentId, due: key.due, in: answers)
      let target =
        answer == .close
        ? max(.zero, sorted[0].price - tolerance(of: sorted[0].price)) : sorted[0].price
      // Stop at the full price, or at the existing tolerance when the owner chose to close the
      // shortfall. Further operations are ordinary spending, not parts of a closed due date.
      for pair in sorted {
        guard paid < target, !used.contains(pair.candidate.id)
        else { continue }
        used.insert(pair.candidate.id)
        paid += pair.candidate.amount
        result.append((pair, pair.price))
      }
    }
    return result
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
    /// The price of the due date; only parts read it.
    var price: AmountE4 = .zero

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
