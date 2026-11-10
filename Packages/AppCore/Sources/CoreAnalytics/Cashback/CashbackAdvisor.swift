import CoreAccounting
import CoreKit
import Foundation

/// A card (or an account without cards) the owner could pay with.
public struct CashbackCandidate: Hashable, Sendable {
  public var holder: CashbackHolder
  public var accountId: UUID

  public init(holder: CashbackHolder, accountId: UUID) {
    self.holder = holder
    self.accountId = accountId
  }
}

/// The one calculation behind «Чем платить здесь», «Упущенный кэшбэк», the monthly choice and
/// the cashback trap: the rules of each card, the month's categories, the monthly ceilings.
///
/// Hidden accounts (0541) are never offered while they are hidden: the caller passes them in
/// `hidden`, and nothing here names one of them or a purchase made with one.
public enum CashbackAdvisor {
  /// What a purchase can be paid with: each live card of a live account, and a live account
  /// without live cards; only those whose rules promise anything, only accounts that hold
  /// `currency` when one is given, never a hidden or archived account, never a credit card
  /// line of a debt.
  public static func candidates(
    accounts: [PaymentMethod], cards: [PaymentCard], book: CashbackRuleBook,
    hidden: Set<UUID> = [], currency: CurrencyCode? = nil
  ) -> [CashbackCandidate] {
    var out: [CashbackCandidate] = []
    for account in accounts where !account.archived && !hidden.contains(account.id) {
      if let currency, !account.holds(currency) { continue }
      let live = CardRules.ordered(cards, of: account.id, locale: Locale(identifier: "en_US_POSIX"))
      let holders: [CashbackHolder] =
        live.isEmpty ? [.account(account.id)] : live.map { .card($0.id) }
      for holder in holders where !book.effectiveRules(of: holder).isEmpty {
        out.append(CashbackCandidate(holder: holder, accountId: account.id))
      }
    }
    return out
  }

  /// A way to pay a purchase and what it earns.
  public struct Option: Hashable, Sendable {
    public var candidate: CashbackCandidate
    public var rule: CashbackRule
    /// Rubles, down to the kopeck, with the month's ceilings left as they are.
    public var expectedRub: AmountE4
    public var percent: CashbackPercent { rule.percent }
  }

  /// The ways to pay `amountRub` of `categoryId` in `month`, the best first: the rule each
  /// card would take, the room its ceilings still leave. Ties go to the order of `candidates`.
  public static func options(
    categoryId: UUID?, amountRub: AmountE4, month: MonthKey, candidates: [CashbackCandidate],
    book: CashbackRuleBook, tracker: CashbackCapTracker
  ) -> [Option] {
    var options: [(Int, Option)] = []
    for (index, candidate) in candidates.enumerated() {
      guard let rule = book.rule(for: candidate.holder, categoryId: categoryId, month: month)
      else { continue }
      var value = amountRub.decimal.magnitude * rule.percent.fraction
      if let room = tracker.room(rule: rule.id, account: candidate.accountId, month: month) {
        value = min(value, room)
      }
      let rounded = DecimalMath.round(value, scale: 2, mode: .down)
      options.append(
        (
          index,
          Option(
            candidate: candidate, rule: rule,
            expectedRub: (try? AmountE4(decimal: rounded)) ?? .zero)
        ))
    }
    return options.sorted { left, right in
      if left.1.expectedRub != right.1.expectedRub {
        return left.1.expectedRub > right.1.expectedRub
      }
      if left.1.percent != right.1.percent { return left.1.percent > right.1.percent }
      return left.0 < right.0
    }.map(\.1)
  }

  /// The holder of a saved operation, as every figure of cashback takes it.
  static func holder(of transaction: Transaction, mainId: UUID?) -> CashbackHolder? {
    CashbackHolders.holder(
      accountId: transaction.paymentMethodId, cardId: transaction.cardId, mainAccountId: mainId)
  }

  static func mainAccount(_ dataset: Dataset) -> UUID? {
    dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
  }

  /// The purchases that earn cashback from the first day of `range`'s first month to its end,
  /// in the order they were made.
  static func purchases(_ ledger: Ledger, through range: DayRange) -> [TransactionEntry] {
    guard !range.isEmpty else { return [] }
    var seen = Set<UUID>()
    return ledger.rows(in: DayRange(range.start.monthKey.firstDay, range.end))
      .filter {
        $0.isFirstPart && $0.kind == .expense
          && !OverviewSummary.isCountDifference($0)
      }
      .compactMap { row -> TransactionEntry? in
        guard seen.insert(row.transactionId).inserted, let entry = ledger.entry(row.transactionId),
          CashbackMath.earns(entry, tree: ledger.tree)
        else { return nil }
        return entry
      }
      .sorted {
        let (a, b) = ($0.transaction, $1.transaction)
        if a.occurredAt != b.occurredAt { return a.occurredAt < b.occurredAt }
        return a.id.uuidString < b.id.uuidString
      }
  }

  static func month(of transaction: Transaction, calendar: CalendarContext) -> MonthKey {
    calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId).monthKey
  }

  /// Whether `id` is `ancestor` or lies under it.
  static func isUnder(_ id: UUID?, _ ancestor: UUID, tree: CategoryTree) -> Bool {
    var current = id
    var depth = 0
    while let value = current, depth < 8 {
      if value == ancestor { return true }
      current = tree.parent(of: value)?.id
      depth += 1
    }
    return false
  }
}

/// «Упущенный кэшбэк»: what the purchases of a period would have earned more with the best of
/// the owner's cards, as the rules and ceilings stood when each was made.
///
/// Every purchase is weighed in the order it was made. What it earned is what it earned (with
/// the ceilings, as every figure of cashback counts it); what another card would have earned is
/// that card's rule for the purchase's categories, in the room its ceilings had left at that
/// moment. Only cards of accounts in the purchase's currency are compared; a hidden account is
/// neither compared nor are its purchases listed.
public struct MissedCashback: Sendable {
  public struct Item: Hashable, Sendable, Identifiable {
    public var transactionId: UUID
    public var day: DateOnly
    public var placeId: UUID?
    public var categoryId: UUID?
    public var actualRub: AmountE4
    public var bestRub: AmountE4
    public var best: CashbackCandidate
    public var missedRub: AmountE4 { bestRub - actualRub }
    public var id: UUID { transactionId }
  }

  /// The purchases that could have earned more, the largest miss first.
  public let items: [Item]
  public let totalRub: AmountE4
  /// Rubles missed by month, in month order.
  public let byMonth: [(month: MonthKey, missedRub: AmountE4)]

  public init(ledger: Ledger, period: Period, hidden: Set<UUID> = []) {
    let dataset = ledger.dataset
    let book = CashbackRuleBook(
      rules: dataset.cashbackRules, tree: ledger.tree, cards: dataset.cards,
      accounts: dataset.paymentMethods)
    let caps = CashbackCaps(rules: dataset.cashbackRules, accounts: dataset.paymentMethods)
    let mainId = CashbackAdvisor.mainAccount(dataset)
    var tracker = CashbackCapTracker(caps: caps)
    var candidatesByCurrency: [CurrencyCode: [CashbackCandidate]] = [:]
    let refunded = { (part: UUID) in ledger.refunded(forPart: part) }
    var items: [Item] = []

    for entry in CashbackAdvisor.purchases(ledger, through: period.range) {
      let transaction = entry.transaction
      let month = CashbackAdvisor.month(of: transaction, calendar: ledger.calendar)
      let held = CashbackAdvisor.holder(of: transaction, mainId: mainId)
      let account = held.flatMap { book.account(of: $0) } ?? transaction.paymentMethodId
      let actual = CashbackMath.expected(
        entry, holder: held, book: book, tree: ledger.tree, calendar: ledger.calendar,
        refunded: refunded
      ).map { tracker.admit($0, month: month, account: account) }
      let day = ledger.calendar.day(of: transaction.occurredAt)
      guard period.range.contains(day), !(account.map(hidden.contains) ?? false) else { continue }
      let currency = transaction.movedMoney.currency
      if candidatesByCurrency[currency] == nil {
        candidatesByCurrency[currency] = CashbackAdvisor.candidates(
          accounts: dataset.paymentMethods, cards: dataset.cards, book: book, hidden: hidden,
          currency: currency)
      }
      var best: (CashbackCandidate, AmountE4)?
      for candidate in candidatesByCurrency[currency] ?? [] where candidate.holder != held {
        guard
          let other = CashbackMath.expected(
            entry, holder: candidate.holder, book: book, tree: ledger.tree,
            calendar: ledger.calendar, refunded: refunded)
        else { continue }
        var probe = tracker
        let earned = probe.admit(other, month: month, account: candidate.accountId).rubles
        if earned > (best?.1 ?? .zero) { best = (candidate, earned) }
      }
      let earned = actual?.rubles ?? .zero
      guard let best, best.1 > earned else { continue }
      items.append(
        Item(
          transactionId: transaction.id, day: day,
          placeId: entry.transaction.placeId, categoryId: entry.parts.first?.categoryId,
          actualRub: earned, bestRub: best.1, best: best.0))
    }
    items.sort {
      if $0.missedRub != $1.missedRub { return $0.missedRub > $1.missedRub }
      return $0.transactionId.uuidString < $1.transactionId.uuidString
    }
    self.items = items
    totalRub = AmountE4.sum(items.map(\.missedRub))
    var months: [MonthKey: AmountE4] = [:]
    for item in items { months[item.day.monthKey, default: .zero] += item.missedRub }
    byMonth = months.sorted { $0.key < $1.key }.map { (month: $0.key, missedRub: $0.value) }
  }
}
