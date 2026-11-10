import CoreAccounting
import CoreKit
import Foundation

/// «Чем платить здесь»: a line of «Стоит посмотреть» for a place (or, without one, a category)
/// the owner pays at often with a card that earns less this month than another of the owner's
/// cards would.
public struct PayHereHint: Hashable, Sendable, Identifiable {
  public var month: MonthKey
  /// The place; `nil` when the purchases name none and `categoryId` stands for them.
  public var placeId: UUID?
  public var categoryId: UUID?
  public var best: CashbackCandidate
  public var bestPercent: CashbackPercent
  /// The card used most often there; `nil` when it earns nothing.
  public var usual: CashbackCandidate?
  public var usualPercent: CashbackPercent
  /// Rubles the last 30 days' purchases there would have earned more with `best`.
  public var gainRub: AmountE4

  public init(
    month: MonthKey, placeId: UUID?, categoryId: UUID?, best: CashbackCandidate,
    bestPercent: CashbackPercent, usual: CashbackCandidate?, usualPercent: CashbackPercent,
    gainRub: AmountE4
  ) {
    self.month = month
    self.placeId = placeId
    self.categoryId = categoryId
    self.best = best
    self.bestPercent = bestPercent
    self.usual = usual
    self.usualPercent = usualPercent
    self.gainRub = gainRub
  }

  public var id: String {
    let subject = (placeId ?? categoryId)?.uuidString.lowercased() ?? "none"
    return "cashback.payHere:\(month.iso):\(subject)"
  }
}

/// The cashback trap: «потратили 3 000 ₽ ради 150 ₽ кэшбэка там, где обычно тратите 1 000 ₽».
/// A category the owner took for the month's higher cashback, where the month's spending grew
/// far beyond the usual and the growth is much more than the cashback it brought.
public struct CashbackTrap: Hashable, Sendable, Identifiable {
  public var month: MonthKey
  public var categoryId: UUID
  public var spentRub: AmountE4
  public var cashbackRub: AmountE4
  /// The median of the months before.
  public var usualRub: AmountE4

  public init(
    month: MonthKey, categoryId: UUID, spentRub: AmountE4, cashbackRub: AmountE4,
    usualRub: AmountE4
  ) {
    self.month = month
    self.categoryId = categoryId
    self.spentRub = spentRub
    self.cashbackRub = cashbackRub
    self.usualRub = usualRub
  }

  public var id: String { "cashback.trap:\(month.iso):\(categoryId.uuidString.lowercased())" }
}

public enum CashbackHints {
  /// A hint is worth a line from this many rubles of gain in 30 days.
  public static let minGainRub = AmountE4(whole: 100)
  /// At most this many hints at once, the largest gain first.
  public static let maxHints = 3
  /// A place counts from this many purchases in 30 days.
  public static let minPurchases = 2

  /// The hints for `today`: the purchases of the 30 days up to it, priced by this month's
  /// rules. Hidden accounts are neither offered nor looked at.
  public static func payHere(
    ledger: Ledger, today: DateOnly, hidden: Set<UUID> = [], minGain: AmountE4 = minGainRub,
    limit: Int = maxHints
  ) -> [PayHereHint] {
    let dataset = ledger.dataset
    let book = CashbackRuleBook(
      rules: dataset.cashbackRules, tree: ledger.tree, cards: dataset.cards,
      accounts: dataset.paymentMethods)
    guard !book.isEmpty else { return [] }
    let month = today.monthKey
    let mainId = CashbackAdvisor.mainAccount(dataset)
    let tracker = monthTracker(ledger: ledger, book: book, today: today, mainId: mainId)
    let range = DayRange(today.adding(days: -29), today)

    struct Group {
      var amounts: [AmountE4] = []
      var holders: [CashbackHolder: Int] = [:]
      var categories: [UUID: Int] = [:]
      var currency: CurrencyCode = .rub
    }
    var groups: [String: (place: UUID?, category: UUID?, group: Group)] = [:]
    var seen = Set<UUID>()
    for row in ledger.rows(in: range) where row.isFirstPart && row.kind == .expense {
      guard !OverviewSummary.isCountDifference(row) else { continue }
      guard seen.insert(row.transactionId).inserted, let entry = ledger.entry(row.transactionId),
        CashbackMath.earns(entry, tree: ledger.tree)
      else { continue }
      let transaction = entry.transaction
      guard let held = CashbackAdvisor.holder(of: transaction, mainId: mainId),
        let account = book.account(of: held) ?? transaction.paymentMethodId,
        !hidden.contains(account)
      else { continue }
      let category = row.categoryId
      let key =
        transaction.placeId.map { "p:" + $0.uuidString } ?? category.map { "c:" + $0.uuidString }
      guard let key else { continue }
      var slot =
        groups[key] ?? (transaction.placeId, transaction.placeId == nil ? category : nil, Group())
      slot.group.amounts.append(transaction.amountRubE4 - row.refundedRubE4)
      slot.group.holders[held, default: 0] += 1
      if let category { slot.group.categories[category, default: 0] += 1 }
      slot.group.currency = transaction.movedMoney.currency
      groups[key] = slot
    }

    var hints: [PayHereHint] = []
    for (_, slot) in groups.sorted(by: { $0.key < $1.key }) {
      let group = slot.group
      guard group.amounts.count >= minPurchases else { continue }
      let usualHolder = group.holders.max { left, right in
        left.value != right.value ? left.value < right.value : "\(left.key)" > "\(right.key)"
      }!.key
      let category =
        slot.category
        ?? group.categories.max { left, right in
          left.value != right.value
            ? left.value < right.value : left.key.uuidString > right.key.uuidString
        }?.key
      let candidates = CashbackAdvisor.candidates(
        accounts: dataset.paymentMethods, cards: dataset.cards, book: book, hidden: hidden,
        currency: group.currency)
      let total = AmountE4.sum(group.amounts)
      guard
        let best = CashbackAdvisor.options(
          categoryId: category, amountRub: total, month: month, candidates: candidates, book: book,
          tracker: tracker
        ).first, best.candidate.holder != usualHolder
      else { continue }
      let usualRule = book.rule(for: usualHolder, categoryId: category, month: month)
      let usualPercent = usualRule?.percent ?? .zero
      guard best.percent > usualPercent else { continue }
      let usualEarned = total.decimal * usualPercent.fraction
      let gain = DecimalMath.round(best.expectedRub.decimal - usualEarned, scale: 0, mode: .down)
      guard let gainRub = try? AmountE4(decimal: gain), gainRub >= minGain else { continue }
      let usualAccount = book.account(of: usualHolder)
      hints.append(
        PayHereHint(
          month: month, placeId: slot.place, categoryId: category, best: best.candidate,
          bestPercent: best.percent,
          usual: usualAccount.map { CashbackCandidate(holder: usualHolder, accountId: $0) },
          usualPercent: usualPercent, gainRub: gainRub))
    }
    hints.sort {
      $0.gainRub != $1.gainRub ? $0.gainRub > $1.gainRub : $0.id < $1.id
    }
    return Array(hints.prefix(max(0, limit)))
  }

  /// The month of `today` so far, admitted under the ceilings: how much room each card still has.
  static func monthTracker(
    ledger: Ledger, book: CashbackRuleBook, today: DateOnly, mainId: UUID?
  ) -> CashbackCapTracker {
    let dataset = ledger.dataset
    var tracker = CashbackCapTracker(
      caps: CashbackCaps(rules: dataset.cashbackRules, accounts: dataset.paymentMethods))
    guard !tracker.caps.isEmpty else { return tracker }
    for entry in CashbackAdvisor.purchases(
      ledger, through: DayRange(today.monthKey.firstDay, today))
    {
      let transaction = entry.transaction
      let held = CashbackAdvisor.holder(of: transaction, mainId: mainId)
      guard
        let expected = CashbackMath.expected(
          entry, holder: held, book: book, tree: ledger.tree, calendar: ledger.calendar,
          refunded: { ledger.refunded(forPart: $0) })
      else { continue }
      let account = held.flatMap { book.account(of: $0) } ?? transaction.paymentMethodId
      _ = tracker.admit(
        expected, month: CashbackAdvisor.month(of: transaction, calendar: ledger.calendar),
        account: account)
    }
    return tracker
  }

  /// The month's spending grew this much over the usual before it is a trap…
  public static let trapGrowth = Decimal(string: "1.5")!
  /// …by at least this many rubles…
  public static let trapMinExtraRub = AmountE4(whole: 1_000)
  /// …and by this many times the cashback the category brought.
  public static let trapCashbackTimes = Decimal(2)

  /// The traps of `month`: each category a month rule of a shown account took, where the
  /// month's spending (every account) is at least `trapGrowth` times the median of the three
  /// months before (two of them with spending), and the growth is at least `trapMinExtraRub` and
  /// `trapCashbackTimes` times the cashback the rule brought.
  public static func traps(
    ledger: Ledger, month: MonthKey, through today: DateOnly? = nil, hidden: Set<UUID> = []
  ) -> [CashbackTrap] {
    let dataset = ledger.dataset
    let monthRules = dataset.cashbackRules.filter {
      $0.month == month && $0.categoryId != nil && !hidden.contains($0.accountId)
    }
    guard !monthRules.isEmpty else { return [] }
    let book = CashbackRuleBook(
      rules: dataset.cashbackRules, tree: ledger.tree, cards: dataset.cards,
      accounts: dataset.paymentMethods)
    let caps = CashbackCaps(rules: dataset.cashbackRules, accounts: dataset.paymentMethods)
    let mainId = CashbackAdvisor.mainAccount(dataset)
    let end = min(today ?? month.lastDay, month.lastDay)
    let purchases = CashbackAdvisor.purchases(ledger, through: DayRange(month.firstDay, end))
    let expectations = CashbackMath.cappedExpectations(
      purchases, holder: { CashbackAdvisor.holder(of: $0.transaction, mainId: mainId) },
      book: book, caps: caps, tree: ledger.tree, calendar: ledger.calendar,
      refunded: { ledger.refunded(forPart: $0) })

    func spent(_ category: UUID, in range: DayRange) -> Decimal {
      var total = Decimal(0)
      for row in ledger.rows(in: range) where row.kind == .expense {
        guard !OverviewSummary.isCountDifference(row) else { continue }
        guard CashbackAdvisor.isUnder(row.categoryId, category, tree: ledger.tree) else { continue }
        total += (row.amountRubE4 - row.refundedRubE4).decimal
      }
      return total
    }

    var traps: [CashbackTrap] = []
    var done = Set<UUID>()
    for rule in monthRules {
      guard let category = rule.categoryId, done.insert(category).inserted else { continue }
      let current = spent(category, in: DayRange(month.firstDay, end))
      let before = (1...3).map { back -> Decimal in
        let m = month.adding(months: -back)
        return spent(category, in: DayRange(m.firstDay, m.lastDay))
      }
      guard before.filter({ $0 > 0 }).count >= 2 else { continue }
      let usual = before.sorted()[1]
      let rulesOfCategory = Set(monthRules.filter { $0.categoryId == category }.map(\.id))
      var cashback = Decimal(0)
      for expectation in expectations.values {
        let total = expectation.byRule.values.reduce(0, +)
        guard total != 0 else { continue }
        let share = expectation.byRule.filter { rulesOfCategory.contains($0.key) }.values
          .reduce(0, +)
        cashback += expectation.rubles.decimal * share / total
      }
      let extra = current - usual
      guard cashback > 0, current >= usual * trapGrowth, extra >= trapMinExtraRub.decimal,
        extra >= cashback * trapCashbackTimes
      else { continue }
      func money(_ value: Decimal) -> AmountE4 {
        (try? AmountE4(decimal: DecimalMath.round(value, scale: 2))) ?? .zero
      }
      traps.append(
        CashbackTrap(
          month: month, categoryId: category, spentRub: money(current),
          cashbackRub: money(cashback), usualRub: money(usual)))
    }
    return traps.sorted { $0.spentRub - $0.usualRub > $1.spentRub - $1.usualRub }
  }
}

/// A line of «Стоит посмотреть» about cashback.
public enum CashbackNote: Hashable, Sendable, Identifiable {
  case choose(CashbackChoiceDue)
  case payHere(PayHereHint)
  case trap(CashbackTrap)

  /// The key «Готово» puts away: one per subject and month.
  public var id: String {
    switch self {
    case .choose(let due): due.id
    case .payHere(let hint): hint.id
    case .trap(let trap): trap.id
    }
  }

  /// Every cashback line for `today`, without the ones put away: the choices that are open,
  /// the traps of this month so far and of the month before, the places to pay with another
  /// card. `offers` are the bank's offers the owner typed (`CashbackOffer`).
  public static func list(
    ledger: Ledger, today: DateOnly, offers: [CashbackOffer] = [], hidden: Set<UUID> = [],
    dismissed: Set<String> = []
  ) -> [CashbackNote] {
    let dataset = ledger.dataset
    var notes: [CashbackNote] = CashbackChoiceDue.due(
      today: today, accounts: dataset.paymentMethods, rules: dataset.cashbackRules,
      offers: offers, hidden: hidden, calendar: ledger.calendar
    ).map(CashbackNote.choose)
    let month = today.monthKey
    notes += CashbackHints.traps(ledger: ledger, month: month, through: today, hidden: hidden)
      .map(CashbackNote.trap)
    notes += CashbackHints.traps(ledger: ledger, month: month.previous, hidden: hidden)
      .map(CashbackNote.trap)
    notes += CashbackHints.payHere(ledger: ledger, today: today, hidden: hidden)
      .map(CashbackNote.payHere)
    return notes.filter { !dismissed.contains($0.id) }
  }
}
