import CoreAccounting
import CoreKit
import Foundation

/// The bank's choice of the month: the owner types what the bank offers this month (labels and
/// percents), the app tells which labels to take — by the purchases of the last months mapped
/// to the bank's labels (`BankCategoryMapping`, one table per bank) — and how much each choice
/// would bring, ceilings counted. Taking a choice writes the month's rules of the account.
public enum CashbackChoiceAdvisor {
  /// How many past months the average spending is taken over.
  public static let monthsOfHistory = 3
  /// More offers than this are not combined in every way: the best picks are taken one by one.
  static let exhaustiveLimit = 14

  /// One kind of purchase for the bank's table: a category and, when the operation has one, its
  /// merchant code.
  public struct SpendingBucket: Hashable, Sendable {
    public var categoryId: UUID
    public var mcc: String?

    public init(categoryId: UUID, mcc: String? = nil) {
      self.categoryId = categoryId
      self.mcc = MerchantCode.normalized(mcc)
    }
  }

  /// What the purchases that earn cashback cost by category, rubles a month on average over
  /// the `months` before `month`: the money charged (refunds taken back), as a bank counts it.
  /// Hidden accounts count too — only the total of a category is used, never an account.
  public static func monthlySpending(
    ledger: Ledger, before month: MonthKey, months: Int = monthsOfHistory
  ) -> [UUID: AmountE4] {
    monthlyCodedSpending(ledger: ledger, before: month, months: months).plain
  }

  /// The spending of `monthlySpending` and, beside it, the same split by merchant code too (an
  /// operation without one has a bucket of its own), so that a label with code lists can tell
  /// which purchases it covers. Rows without code lists read `plain`, so their figures are the
  /// ones `monthlySpending` gives, to the kopeck.
  public struct CodedSpending: Hashable, Sendable {
    public var plain: [UUID: AmountE4]
    public var buckets: [SpendingBucket: AmountE4]

    public init(plain: [UUID: AmountE4] = [:], buckets: [SpendingBucket: AmountE4] = [:]) {
      self.plain = plain
      self.buckets = buckets
    }

    /// What a read of these rows is taken over: the code split only when a row has lists and
    /// the split is known; spending given by category alone reads as purchases without a code.
    func source(for rows: [BankCategoryMapping]) -> [SpendingBucket: AmountE4] {
      rows.contains(where: \.hasCodes) && !buckets.isEmpty
        ? buckets : CashbackChoiceAdvisor.buckets(plain)
    }
  }

  public static func monthlyCodedSpending(
    ledger: Ledger, before month: MonthKey, months: Int = monthsOfHistory
  ) -> CodedSpending {
    let totals = spendingTotals(ledger: ledger, before: month, months: months)
    var byCategory: [UUID: Decimal] = [:]
    for (bucket, total) in totals { byCategory[bucket.categoryId, default: 0] += total }
    return CodedSpending(
      plain: averaged(byCategory, months: months), buckets: averaged(totals, months: months))
  }

  private static func averaged<Key>(_ totals: [Key: Decimal], months: Int) -> [Key: AmountE4] {
    totals.compactMapValues { total in
      try? AmountE4(decimal: DecimalMath.round(total / Decimal(months), scale: 2))
    }
  }

  private static func spendingTotals(
    ledger: Ledger, before month: MonthKey, months: Int
  ) -> [SpendingBucket: Decimal] {
    guard months > 0 else { return [:] }
    let range = DayRange(month.adding(months: -months).firstDay, month.previous.lastDay)
    var earns: [UUID: Bool] = [:]
    var totals: [SpendingBucket: Decimal] = [:]
    for row in ledger.rows(in: range) where row.kind == .expense {
      guard !OverviewSummary.isCountDifference(row) else {
        continue
      }
      guard let categoryId = row.categoryId else { continue }
      let counts =
        earns[row.transactionId]
        ?? {
          let value =
            ledger.entry(row.transactionId).map {
              CashbackMath.earns($0, tree: ledger.tree)
            } ?? false
          earns[row.transactionId] = value
          return value
        }()
      guard counts, !ledger.tree.isLoanCategory(categoryId) else { continue }
      let bucket = SpendingBucket(
        categoryId: categoryId, mcc: ledger.entry(row.transactionId)?.transaction.mcc)
      totals[bucket, default: 0] += (row.amountRubE4 - row.refundedRubE4).decimal
    }
    return totals
  }

  /// The categories a bank's label stands for, by that bank's table.
  public static func categories(
    of label: String, bankId: UUID?, mappings: [BankCategoryMapping]
  ) -> [UUID] {
    guard let bankId else { return [] }
    let key = BankCategoryMapping.normalized(label)
    return mappings.filter {
      $0.bankId == bankId && BankCategoryMapping.normalized($0.label) == key
    }
    .map(\.categoryId)
  }

  /// Whether a label's rows (the rows of one bank's table with that label) cover a kind of
  /// purchase, by the one reading every figure of cashback takes (`BankCategoryMapping.covers`).
  static func covers(
    rows: [BankCategoryMapping], bucket: SpendingBucket, tree: CategoryTree
  )
    -> Bool
  {
    BankCategoryMapping.covers(rows, categoryId: bucket.categoryId, mcc: bucket.mcc, tree: tree)
  }

  /// The rows of one bank's table that carry a label.
  static func rows(
    of label: String, bankId: UUID?, mappings: [BankCategoryMapping]
  )
    -> [BankCategoryMapping]
  {
    guard let bankId else { return [] }
    let key = BankCategoryMapping.normalized(label)
    return mappings.filter {
      $0.bankId == bankId && BankCategoryMapping.normalized($0.label) == key
    }
  }

  static func buckets(_ spending: [UUID: AmountE4]) -> [SpendingBucket: AmountE4] {
    Dictionary(
      uniqueKeysWithValues: spending.map { (SpendingBucket(categoryId: $0.key), $0.value) })
  }

  /// The monthly spending a label covers: its categories and everything under them, each
  /// category counted once.
  public static func spending(
    of label: String, bankId: UUID?, mappings: [BankCategoryMapping],
    spending: [UUID: AmountE4], tree: CategoryTree
  ) -> AmountE4 {
    self.spending(
      of: label, bankId: bankId, mappings: mappings, coded: CodedSpending(plain: spending),
      tree: tree)
  }

  /// The monthly spending a label covers when merchant codes are known (`covers`).
  public static func spending(
    of label: String, bankId: UUID?, mappings: [BankCategoryMapping],
    coded: CodedSpending, tree: CategoryTree
  ) -> AmountE4 {
    let rows = Self.rows(of: label, bankId: bankId, mappings: mappings)
    guard !rows.isEmpty else { return .zero }
    return AmountE4.sum(
      coded.source(for: rows).filter { bucket, _ in
        covers(rows: rows, bucket: bucket, tree: tree)
      }.values)
  }

  /// A choice of labels and what it would bring in a month like the last ones.
  public struct Pick: Hashable, Sendable {
    public var offerIds: [UUID]
    /// Rubles a month, ceilings counted.
    public var expectedRub: AmountE4
  }

  /// What one offer alone would bring a month: the spending its label covers at its percent.
  public static func value(
    of offer: CashbackOffer, bankId: UUID?, mappings: [BankCategoryMapping],
    spending: [UUID: AmountE4], tree: CategoryTree
  ) -> AmountE4 {
    value(
      of: offer, bankId: bankId, mappings: mappings, coded: CodedSpending(plain: spending),
      tree: tree)
  }

  /// `value` with merchant codes known.
  public static func value(
    of offer: CashbackOffer, bankId: UUID?, mappings: [BankCategoryMapping],
    coded: CodedSpending, tree: CategoryTree
  ) -> AmountE4 {
    let base = Self.spending(
      of: offer.label, bankId: bankId, mappings: mappings, coded: coded, tree: tree)
    let value = DecimalMath.round(base.decimal * offer.percent.fraction, scale: 2, mode: .down)
    return (try? AmountE4(decimal: value)) ?? .zero
  }

  /// The best choices of `pick` offers, best first (at most `limit`): what the labels bring
  /// together — a category two labels cover counts once, at the higher percent — and at most
  /// the account's ceiling. Offers of one label count as one. Ties go to the offers' order.
  public static func best(
    offers: [CashbackOffer], pick: Int, bankId: UUID?, mappings: [BankCategoryMapping],
    spending: [UUID: AmountE4], tree: CategoryTree, accountCap: AmountE4? = nil, limit: Int = 3
  ) -> [Pick] {
    best(
      offers: offers, pick: pick, bankId: bankId, mappings: mappings,
      coded: CodedSpending(plain: spending), tree: tree, accountCap: accountCap, limit: limit)
  }

  /// `best` with merchant codes known: a purchase is reached by a label through `covers`.
  public static func best(
    offers: [CashbackOffer], pick: Int, bankId: UUID?, mappings: [BankCategoryMapping],
    coded: CodedSpending, tree: CategoryTree, accountCap: AmountE4? = nil, limit: Int = 3
  ) -> [Pick] {
    let offerRows = offers.map { rows(of: $0.label, bankId: bankId, mappings: mappings) }
    let spending = coded.source(for: offerRows.flatMap { $0 })
    let count = min(max(pick, 0), offers.count)
    guard count > 0 else { return [] }
    // Each offer: the categories it reaches (with what lies under them) and its percent.
    let reach: [[SpendingBucket: Decimal]] = offers.indices.map { index in
      let offer = offers[index]
      let rows = offerRows[index]
      var map: [SpendingBucket: Decimal] = [:]
      for (bucket, _) in spending where covers(rows: rows, bucket: bucket, tree: tree) {
        map[bucket] = offer.percent.fraction
      }
      return map
    }
    func worth(_ chosen: [Int]) -> AmountE4 {
      var best: [SpendingBucket: Decimal] = [:]
      for index in chosen {
        for (id, fraction) in reach[index] { best[id] = max(best[id] ?? 0, fraction) }
      }
      var total = Decimal(0)
      for (id, fraction) in best { total += (spending[id]?.decimal ?? 0) * fraction }
      if let accountCap { total = min(total, accountCap.decimal) }
      return (try? AmountE4(decimal: DecimalMath.round(total, scale: 2, mode: .down))) ?? .zero
    }
    var picks: [([Int], AmountE4)] = []
    if offers.count <= exhaustiveLimit {
      func walk(_ start: Int, _ chosen: [Int]) {
        if chosen.count == count {
          picks.append((chosen, worth(chosen)))
          return
        }
        guard start < offers.count, offers.count - start >= count - chosen.count else { return }
        for index in start..<offers.count { walk(index + 1, chosen + [index]) }
      }
      walk(0, [])
    } else {
      var chosen: [Int] = []
      while chosen.count < count {
        let next = (0..<offers.count).filter { !chosen.contains($0) }
          .max { worth(chosen + [$0]) < worth(chosen + [$1]) }!
        chosen.append(next)
      }
      picks.append((chosen.sorted(), worth(chosen)))
    }
    picks.sort { left, right in
      if left.1 != right.1 { return left.1 > right.1 }
      return left.0.lexicographicallyPrecedes(right.0)
    }
    return picks.prefix(max(1, limit)).map { pick in
      Pick(offerIds: pick.0.map { offers[$0].id }, expectedRub: pick.1)
    }
  }

  /// The month's rules that taking `chosen` writes: one per category its label stands for, at
  /// the offer's percent; a category two chosen labels stand for takes the higher. A label
  /// with no category in the bank's table writes nothing — the owner maps it first.
  public static func rules(
    for chosen: [CashbackOffer], bankId: UUID?, mappings: [BankCategoryMapping],
    existing: [CashbackRule] = []
  ) -> [CashbackRule] {
    var byKey: [CashbackRuleKey: CashbackRule] = [:]
    var order: [CashbackRuleKey] = []
    for offer in chosen {
      for categoryId in categories(of: offer.label, bankId: bankId, mappings: mappings) {
        let key = CashbackRuleKey(
          accountId: offer.accountId, cardId: offer.cardId, month: offer.month,
          categoryId: categoryId)
        if let known = byKey[key] {
          if offer.percent > known.percent { byKey[key]?.percent = offer.percent }
          continue
        }
        var rule = CashbackRule(
          accountId: offer.accountId, cardId: offer.cardId, categoryId: categoryId,
          month: offer.month, percent: offer.percent)
        rule = CashbackRules.upserting(rule, into: existing)
        byKey[key] = rule
        order.append(key)
      }
    }
    return order.compactMap { byKey[$0] }
  }
}

/// «Выберите категории кэшбэка»: a line of «Стоит посмотреть» from the day the bank opens the
/// choice (set on the account, the 1st unless said otherwise) until the month has a choice.
public struct CashbackChoiceDue: Hashable, Sendable, Identifiable {
  public var accountId: UUID
  public var month: MonthKey

  public init(accountId: UUID, month: MonthKey) {
    self.accountId = accountId
    self.month = month
  }

  public var id: String { "cashback.choice:\(accountId.uuidString.lowercased()):\(month.iso)" }

  /// The accounts whose choice of `today`'s month is open and not made: no month rule of the
  /// account (or its cards) and no chosen offer for the month. A day past the month's end is
  /// its last day. Archived and hidden accounts say nothing.
  public static func due(
    today: DateOnly, accounts: [PaymentMethod], rules: [CashbackRule], offers: [CashbackOffer],
    hidden: Set<UUID> = [], calendar: CalendarContext
  ) -> [CashbackChoiceDue] {
    let month = today.monthKey
    let lastDay = calendar.daysInMonth(month)
    let chosen = Set(rules.filter { $0.month == month }.map(\.accountId))
      .union(offers.filter { $0.month == month && $0.chosen }.map(\.accountId))
    return accounts.compactMap { account in
      guard let day = account.cashbackChoiceDay, !account.archived,
        !hidden.contains(account.id), !chosen.contains(account.id),
        today.day >= min(max(day, 1), lastDay)
      else { return nil }
      return CashbackChoiceDue(accountId: account.id, month: month)
    }
  }
}
