import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// The ranking of the limits running out, on random lines: over → on the edge → within,
/// within a status the bigger share spent first, compared exactly, then by name, case and
/// «ё» aside, then by id — the same list whatever order the lines came in.
@Suite("Limits running out: the ranking on random lines")
struct LimitRankingPropertyTests {
  static let seeds: [UInt64] = Array(1...30)

  static func uid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "11110000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  /// Names that tie once folded — «Ёлка» and «елка», «Кафе» and «кафе» — and an archived
  /// category with a child.
  static let categories: [CoreKit.Category] = [
    CoreKit.Category(id: uid(1), kind: .expense, name: "Ёлка"),
    CoreKit.Category(id: uid(2), kind: .expense, name: "елка"),
    CoreKit.Category(id: uid(3), kind: .expense, name: "Кафе"),
    CoreKit.Category(id: uid(4), kind: .expense, name: "кафе"),
    CoreKit.Category(id: uid(5), kind: .expense, name: "Books"),
    CoreKit.Category(id: uid(6), kind: .expense, name: "Taxi"),
    CoreKit.Category(id: uid(7), kind: .expense, name: "Old", archived: true),
    CoreKit.Category(id: uid(8), parentId: uid(7), kind: .expense, name: "Paints"),
    CoreKit.Category(id: uid(9), parentId: uid(5), kind: .expense, name: "Comics"),
  ]
  static let tree = CategoryTree(categories)

  static func name(of line: LimitLine) -> String {
    guard let category = tree.category(line.budget.categoryId) else { return "" }
    let name = tree.parent(of: category.id).map { "\($0.name) › \(category.name)" } ?? category.name
    return name.lowercased().replacingOccurrences(of: "ё", with: "е")
  }

  static func share(of line: LimitLine) -> Decimal {
    guard line.available.raw > 0 else {
      return line.spent.raw > 0 ? Decimal.greatestFiniteMagnitude : 0
    }
    return Decimal(line.spent.raw) / Decimal(line.available.raw)
  }

  static func rank(_ status: LimitStatus) -> Int {
    switch status {
    case .over: 0
    case .warning: 1
    case .ok: 2
    }
  }

  /// Random lines: a status, a spent amount and what is available — shares that tie, nothing
  /// available, names that tie once folded, limits of an archived category.
  static func lines(seed: UInt64) -> [LimitLine] {
    var random = SeededRandom(seed: seed)
    return (0..<random.int(in: 0...14)).map { index in
      let category = uid(random.int(in: 1...9))
      let available = AmountE4(whole: Int64(random.choice(from: [0, 1_000, 2_000, 3_000])))
      let spent = AmountE4(whole: Int64(random.choice(from: [0, 500, 1_000, 1_500, 3_000])))
      let budget = Budget(
        id: uid(100 + index), scope: .category, categoryId: category, amountE4: available)
      return LimitLine(
        budget: budget, month: MonthKey(year: 2026, month: 9), amount: available, carry: .zero,
        spent: spent, spentShareBp: nil, elapsedShareBp: 5_000, paceBp: nil, planned: .zero,
        forecast: spent, lowData: false,
        status: random.choice(from: [LimitStatus.over, .warning, .ok]))
    }
  }

  /// The order is the ranking rule, step by step, and nothing visible is lost or doubled.
  @Test(arguments: seeds)
  func theOrderIsTheRule(_ seed: UInt64) {
    let lines = Self.lines(seed: seed)
    let ranked = LimitRules.ranked(lines, topN: nil, tree: Self.tree)
    let visible = lines.filter { !LimitRules.isHidden($0.budget, tree: Self.tree) }
    #expect(ranked.total == visible.count)
    #expect(Set(ranked.shown.map(\.budget.id)) == Set(visible.map(\.budget.id)))
    #expect(ranked.shown.count == visible.count)
    for (left, right) in zip(ranked.shown, ranked.shown.dropFirst()) {
      let leftRank = Self.rank(left.status)
      let rightRank = Self.rank(right.status)
      #expect(leftRank <= rightRank, "seed \(seed)")
      guard leftRank == rightRank else { continue }
      #expect(Self.share(of: left) >= Self.share(of: right), "seed \(seed)")
      guard Self.share(of: left) == Self.share(of: right) else { continue }
      #expect(Self.name(of: left) <= Self.name(of: right), "seed \(seed)")
      guard Self.name(of: left) == Self.name(of: right) else { continue }
      #expect(left.budget.id.uuidString < right.budget.id.uuidString, "seed \(seed)")
    }
  }

  /// The same lines in any order rank the same.
  @Test(arguments: seeds)
  func theOrderTheLinesCameInDoesNotMatter(_ seed: UInt64) {
    var lines = Self.lines(seed: seed)
    let first = LimitRules.ranked(lines, topN: nil, tree: Self.tree).shown.map(\.budget.id)
    var random = SeededRandom(seed: seed &* 31)
    for _ in 0..<5 {
      lines.shuffle(using: &random)
      #expect(
        LimitRules.ranked(lines, topN: nil, tree: Self.tree).shown.map(\.budget.id) == first,
        "seed \(seed)")
    }
  }

  /// «Top n» is the head of the whole ranking, and «все» is all of it; the count of all is
  /// always the whole visible list, whatever n.
  @Test(arguments: seeds)
  func topNIsTheHeadOfTheRanking(_ seed: UInt64) {
    let lines = Self.lines(seed: seed)
    let all = LimitRules.ranked(lines, topN: nil, tree: Self.tree)
    for n in [-1, 0, 1, 3, 5, 100] {
      let top = LimitRules.ranked(lines, topN: n, tree: Self.tree)
      #expect(top.shown.map(\.budget.id) == Array(all.shown.prefix(max(0, n)).map(\.budget.id)))
      #expect(top.total == all.total)
    }
  }

  /// A limit of an archived category — or of a category under one — is hidden; a limit of a
  /// category the tree does not know stays, so it can still be deleted.
  @Test func archivedCategoriesHideTheirLimits() {
    func line(_ category: UUID, _ index: Int) -> LimitLine {
      LimitLine(
        budget: Budget(
          id: Self.uid(200 + index), scope: .category, categoryId: category,
          amountE4: AmountE4(whole: 1_000)),
        month: MonthKey(year: 2026, month: 9), amount: AmountE4(whole: 1_000), carry: .zero,
        spent: .zero, spentShareBp: nil, elapsedShareBp: 5_000, paceBp: nil, planned: .zero,
        forecast: .zero, lowData: false, status: .ok)
    }
    let ranked = LimitRules.ranked(
      [line(Self.uid(7), 1), line(Self.uid(8), 2), line(Self.uid(9), 3), line(Self.uid(99), 4)],
      topN: nil, tree: Self.tree)
    #expect(ranked.shown.map(\.budget.categoryId) == [Self.uid(99), Self.uid(9)])
    #expect(ranked.total == 2)
  }

  // MARK: - The status of a real line

  /// A random book of spending under three limits — Groceries, Fun and Housing (spent under
  /// Housing itself and under its Rent) — starting early for a full window of 90 days or late
  /// for a short one, some of it after today, some of it shortfalls of money back; and, by the
  /// limit's category, what was spent: (day, rubles, is a shortfall).
  struct SpendingBook {
    var ledger: Ledger
    var budgets: [Budget] = []
    var spending: [UUID: [(day: DateOnly, amount: Decimal, shortfall: Bool)]] = [:]

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      var fx = CashFx()
      for (index, category) in [CashFx.groceries, CashFx.fun, CashFx.housing].enumerated() {
        budgets.append(
          Budget(
            id: CashFx.id(720 + index), scope: .category, categoryId: category,
            amountE4: AmountE4(whole: Int64(random.int(in: 1...30) * 1_000))))
        let from = CashFx.day("2026-06-01").adding(days: random.int(in: 0...105))
        let span = from.days(to: CashFx.day("2026-09-30"))
        for number in 0..<random.int(in: 0...12) {
          let day = from.adding(days: random.int(in: 0...span))
          let amount = random.int(in: 1...5_000)
          let shortfall = random.chance(1, outOf: 8)
          let filed =
            category == CashFx.housing && random.chance(1, outOf: 2) ? CashFx.rent : category
          fx.add(
            .expense, "\(amount)", at: CalendarContext.utc.noon(of: day), category: filed,
            link: shortfall ? .shortfall(reimbursement: "r\(index)", part: "p\(number)") : nil)
          spending[category, default: []].append((day, Decimal(amount), shortfall))
        }
      }
      var book = fx.book
      book.budgets = budgets
      let base = fx.ledger.dataset
      ledger = Ledger(
        dataset: Dataset(
          entries: base.entries, categories: base.categories, events: base.events,
          paymentMethods: base.paymentMethods, debts: base.debts, goals: base.goals,
          planning: book, transfers: base.transfers, accountGroups: base.accountGroups),
        calendar: .utc)
    }

    var lines: [LimitLine] {
      LimitRules.lines(book: ledger.dataset.planning, ledger: ledger, today: CashFx.today)
    }

    /// The line of `budget` by the plain rule: (spent, low data, forecast, status).
    func model(_ budget: Budget) -> (Decimal, Bool, Decimal, LimitStatus) {
      let rows = spending[budget.categoryId ?? UUID()] ?? []
      let today = CashFx.today
      let yesterday = today.adding(days: -1)
      let floor = today.adding(days: -90)
      let spent = rows.filter { $0.day.monthKey == today.monthKey }.reduce(Decimal(0)) {
        $0 + $1.amount
      }
      func variable(_ from: DateOnly, _ through: DateOnly) -> Decimal {
        rows.filter { !$0.shortfall && $0.day >= from && $0.day <= through }
          .reduce(Decimal(0)) { $0 + $1.amount }
      }
      let earlier = rows.contains { $0.day < floor }
      let firstInWindow = rows.map(\.day).filter { $0 >= floor && $0 <= today }.min()
      var rate = variable(today.monthKey.firstDay, today) / Decimal(today.day)
      var lowData = true
      if let start = earlier ? floor : firstInWindow {
        let days = start.days(to: yesterday) + 1
        if days >= 28 {
          rate = variable(start, yesterday) / Decimal(days)
          lowData = false
        }
      }
      let daysLeft = today.monthKey.dayCount - today.day
      let forecast = spent + SubscriptionMath.rounded(max(0, rate * Decimal(daysLeft))).decimal
      let limit = budget.amountE4.decimal
      let status: LimitStatus =
        spent > limit ? .over : (forecast > limit || spent * 10 >= limit * 9) ? .warning : .ok
      return (spent, lowData, forecast, status)
    }
  }

  /// For any spending under a limit, every figure of the line against a plain model built from
  /// the operations themselves: spent is the month's spending of the category and its
  /// subcategories, operations after today included; the daily rate is the variable spending
  /// of the window [max(today − 90, the first day with spending under the limit), yesterday]
  /// over its days — or, for a window shorter than 28 days, this month's through today over
  /// today's day — with the shortfalls of money back spent but never paced; the forecast is
  /// spent + the rate × the days left; the status is over when spent exceeds the limit, on the
  /// edge when the forecast does or 90 % is spent, within otherwise. The ranking of such lines
  /// keeps its rule.
  @Test(arguments: seeds)
  func theStatusFollowsSpentAndForecast(_ seed: UInt64) {
    let book = SpendingBook(seed: seed)
    let lines = book.lines
    #expect(lines.count == 3)
    for line in lines {
      let (spent, lowData, forecast, status) = book.model(line.budget)
      #expect(line.spent.decimal == spent, "seed \(seed)")
      #expect(line.lowData == lowData, "seed \(seed)")
      #expect(line.forecast.decimal == forecast, "seed \(seed)")
      #expect(line.status == status, "seed \(seed)")
    }
    let ranked = LimitRules.ranked(lines, topN: nil, tree: book.ledger.tree).shown
    #expect(ranked.map { Self.rank($0.status) } == ranked.map { Self.rank($0.status) }.sorted())
  }

  /// The random books reach what the model is about: every status, full windows and short
  /// ones, shortfalls, spending after today and under a subcategory.
  @Test func theRandomSpendingReachesEveryCase() {
    var statuses: Set<Int> = []
    var lowData = 0
    var full = 0
    var shortfalls = 0
    var ahead = 0
    for seed in Self.seeds {
      let book = SpendingBook(seed: seed)
      for line in book.lines {
        statuses.insert(Self.rank(line.status))
        if line.lowData { lowData += 1 } else { full += 1 }
      }
      let rows = book.spending.values.joined()
      shortfalls += rows.filter(\.shortfall).count
      ahead += rows.filter { $0.day > CashFx.today }.count
    }
    #expect(statuses == [0, 1, 2])
    #expect(lowData >= 5)
    #expect(full >= 5)
    #expect(shortfalls >= 5)
    #expect(ahead >= 5)
  }
}
