import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A random book: purchases of my own and for other people, refunds taken back from purchases
/// in later months, refunds of no purchase, money back covering parts whole or in part, income
/// for its own or another month, some of it deleted — and a plain model of what each month
/// should show, worked out apart from the ledger.
private struct RandomBook {
  let groceries = id(10)
  let clothes = id(11)
  let salary = id(31)
  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: clothes, kind: .expense, name: "Clothes", quality: .bad),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    ]
  }
  let start = CalendarContext.utc.startOfDay(day("2026-01-01"))
  var entries: [TransactionEntry] = []
  var links: [ReimbursementLink] = []
  var dice: MoneyDice
  private var next = 1000

  init(seed: UInt64) {
    dice = MoneyDice(seed: seed)
    for _ in 0..<120 {
      switch dice.below(10) {
      case 0, 1, 2: purchase()
      case 3: purchase(forOthers: true)
      case 4, 5: refund()
      case 6: moneyBack()
      case 7: income()
      case 8: refundOfNoPurchase()
      default: deleteSomething()
      }
    }
  }

  mutating func number() -> Int {
    next += 1
    return next
  }

  mutating func someMoment() -> Date {
    start.addingTimeInterval(TimeInterval(dice.below(150) * 86_400 + dice.below(86_400)))
  }

  mutating func add(
    _ kind: TransactionKind, at: Date, currency: CurrencyCode = .rub, rate: Decimal? = nil,
    parts: [TransactionPart], periodMonth: MonthKey? = nil
  ) -> TransactionEntry {
    let number = number()
    var fixed = parts
    for index in fixed.indices {
      fixed[index].id = id(number * 10 + index)
      fixed[index].transactionId = id(number)
    }
    let amount = AmountE4.sum(fixed.map(\.amountE4))
    let rub = rate.map { (try? AmountE4(decimal: amount.decimal * $0)) ?? amount } ?? amount
    let shares = rub.allocated(proportionallyTo: fixed.map(\.amountE4), outOf: amount)
    for index in fixed.indices { fixed[index].amountRubE4 = shares[index] }
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: kind, occurredAt: at, currency: currency, amountE4: amount,
        rate: rate, amountRubE4: rub, paymentMethodId: id(1), periodMonth: periodMonth,
        createdAt: at, updatedAt: at),
      parts: fixed)
    entries.append(entry)
    return entry
  }

  func piece(_ amount: AmountE4, category: UUID?, forOthers: Bool = false) -> TransactionPart {
    TransactionPart(
      transactionId: id(0), categoryId: category, amountE4: amount,
      forWhom: forOthers ? .friends : .me, reimbursable: forOthers,
      debtorPersonId: forOthers ? id(300) : nil, reimbursementStatus: forOthers ? .expected : nil)
  }

  mutating func purchase(forOthers: Bool = false) {
    let foreign = dice.chance(30)
    let parts = (0..<dice.int(1...2)).map { _ in
      piece(
        foreign ? dice.fineAmount(upTo: 300) : dice.amount(upTo: 9000),
        category: dice.pick([groceries, clothes]), forOthers: forOthers && dice.chance(80))
    }
    _ = add(
      .expense, at: someMoment(), currency: foreign ? .usd : .rub,
      rate: foreign ? Decimal(dice.int(700_000...1_109_999)) / 10_000 : nil, parts: parts)
  }

  var live: [TransactionEntry] { entries.filter { !$0.transaction.isDeleted } }

  /// What live refunds took back from each purchase part so far.
  var refunded: [UUID: AmountE4] {
    var result: [UUID: AmountE4] = [:]
    for entry in live where entry.transaction.kind == .refund {
      for part in entry.parts {
        if let target = part.refundOfPartId { result[target, default: .zero] += part.amountE4 }
      }
    }
    return result
  }

  mutating func refund() {
    let taken = refunded
    let open = live.filter { $0.transaction.kind == .expense }.flatMap { entry in
      entry.parts.filter { !$0.reimbursable && $0.amountE4 > (taken[$0.id] ?? .zero) }
        .map { (entry, $0) }
    }
    guard !open.isEmpty else { return purchase() }
    let (purchase, part) = dice.pick(open)
    let left = part.amountE4 - (taken[part.id] ?? .zero)
    let amount = dice.chance(40) ? left : AmountE4(raw: Int64(dice.int(1...Int(left.raw))))
    let rubles = RefundRules.rubles(
      refundAmount: amount, part: part,
      refundedBefore: (taken[part.id] ?? .zero, storedRub(of: part.id)))
    var refundPart = piece(amount, category: part.categoryId)
    refundPart.refundOfPartId = part.id
    let entry = add(
      .refund,
      at: purchase.transaction.occurredAt.addingTimeInterval(
        TimeInterval(dice.int(1...80) * 86_400)),
      currency: purchase.transaction.currency, rate: purchase.transaction.rate, parts: [refundPart])
    // The rubles the refund stores are the rule's, not the ones at its rate.
    let index = entries.count - 1
    entries[index].transaction.amountRubE4 = rubles
    entries[index].parts[0].amountRubE4 = rubles
    _ = entry
  }

  func storedRub(of partId: UUID) -> AmountE4 {
    AmountE4.sum(
      live.filter { $0.transaction.kind == .refund }.flatMap(\.parts)
        .filter { $0.refundOfPartId == partId }.map(\.amountRubE4))
  }

  mutating func refundOfNoPurchase() {
    _ = add(.refund, at: someMoment(), parts: [piece(dice.amount(upTo: 2000), category: groceries)])
  }

  /// What is still owed on each part paid for somebody else.
  var owed: [UUID: AmountE4] {
    let liveIds = Set(live.map(\.id))
    var back: [UUID: AmountE4] = [:]
    for link in links where liveIds.contains(link.reimbursementTxId) {
      back[link.partId, default: .zero] += link.amountE4
    }
    var result: [UUID: AmountE4] = [:]
    for entry in live where entry.transaction.kind == .expense {
      for part in entry.parts where part.reimbursable && part.reimbursementStatus == .expected {
        result[part.id] = max(.zero, part.amountRubE4 - (back[part.id] ?? .zero))
      }
    }
    return result
  }

  /// Money back for one open part: some of what is left, or all of it — then the part is closed.
  mutating func moneyBack() {
    let open = owed.filter { $0.value.raw > 0 }.sorted { $0.key.uuidString < $1.key.uuidString }
    guard !open.isEmpty else { return purchase(forOthers: true) }
    let (partId, left) = dice.pick(open)
    let amount = dice.chance(50) ? left : AmountE4(raw: Int64(dice.int(1...Int(left.raw))))
    let entry = add(.reimbursement, at: someMoment(), parts: [piece(amount, category: nil)])
    links.append(ReimbursementLink(reimbursementTxId: entry.id, partId: partId, amountE4: amount))
    if amount == left {
      for position in entries.indices {
        for index in entries[position].parts.indices
        where entries[position].parts[index].id == partId {
          entries[position].parts[index].reimbursementStatus = .returned
        }
      }
    }
  }

  mutating func income() {
    let at = someMoment()
    let month = CalendarContext.utc.day(of: at).monthKey
    _ = add(
      .income, at: at, parts: [piece(dice.amount(upTo: 90_000), category: salary)],
      periodMonth: dice.chance(30) ? month.adding(months: dice.pick([-1, 1])) : nil)
  }

  /// A refund, an income, a money back that closed no part — it covered its part only partly, so
  /// nothing is to be opened again — or a purchase nothing leans on.
  mutating func deleteSomething() {
    let taken = refunded
    var closed: Set<UUID> = []
    for entry in entries {
      for part in entry.parts where part.reimbursementStatus == .returned { closed.insert(part.id) }
    }
    let closing = Set(links.filter { closed.contains($0.partId) }.map(\.reimbursementTxId))
    let candidates = entries.indices.filter { position in
      let entry = entries[position]
      guard !entry.transaction.isDeleted else { return false }
      switch entry.transaction.kind {
      case .refund, .income: return true
      case .reimbursement: return !closing.contains(entry.id)
      case .expense:
        return entry.parts.allSatisfy { part in
          (taken[part.id] ?? .zero).isZero && !part.reimbursable
        }
      }
    }
    guard !candidates.isEmpty else { return }
    let position = dice.pick(candidates)
    entries[position].transaction.deletedAt = entries[position].transaction.occurredAt
  }

  // MARK: The model

  func month(of date: Date) -> MonthKey { CalendarContext.utc.day(of: date).monthKey }

  /// My spending by the month of its day: purchases cheaper by what came back from them,
  /// wherever the refund fell; refunds of no purchase on their own day.
  var spendingByMonth: [MonthKey: AmountE4] {
    let purchaseParts = Set(
      live.filter { $0.transaction.kind == .expense }.flatMap(\.parts).map(\.id))
    let taken = refunded
    var result: [MonthKey: AmountE4] = [:]
    for entry in live {
      let month = month(of: entry.transaction.occurredAt)
      for part in entry.parts {
        switch entry.transaction.kind {
        case .expense:
          guard !part.reimbursable || part.reimbursementStatus == .writtenOff else { continue }
          let back = taken[part.id] ?? .zero
          let backRub =
            back.isZero
            ? AmountE4.zero
            : back >= part.amountE4
              ? part.amountRubE4
              : (try? AmountE4(
                decimal: part.amountRubE4.decimal * back.decimal / part.amountE4.decimal)) ?? .zero
          result[month, default: .zero] += part.amountRubE4 - backRub
        case .refund:
          if let target = part.refundOfPartId, purchaseParts.contains(target) { continue }
          result[month, default: .zero] += -part.amountRubE4
        case .income, .reimbursement:
          continue
        }
      }
    }
    return result
  }

  /// Income by the month it is for.
  var incomeByMonth: [MonthKey: AmountE4] {
    var result: [MonthKey: AmountE4] = [:]
    for entry in live where entry.transaction.kind == .income {
      let month = entry.transaction.periodMonth ?? month(of: entry.transaction.occurredAt)
      result[month, default: .zero] += entry.transaction.amountRubE4
    }
    return result
  }

  /// What came back for the parts paid for other people: the links of live money back to
  /// parts of live purchases.
  var returnedForOthers: AmountE4 {
    let liveIds = Set(live.map(\.id))
    let others = Set(
      live.filter { $0.transaction.kind == .expense }.flatMap(\.parts).filter(\.reimbursable)
        .map(\.id))
    return AmountE4.sum(
      links.filter { liveIds.contains($0.reimbursementTxId) && others.contains($0.partId) }
        .map(\.amountE4))
  }

  /// What I paid for other people: the rubles of every part «за другого» of a live purchase.
  var paidForOthers: AmountE4 {
    AmountE4.sum(
      live.filter { $0.transaction.kind == .expense }.flatMap(\.parts).filter(\.reimbursable)
        .map(\.amountRubE4))
  }

  var ledger: Ledger {
    Ledger(dataset: Dataset(entries: entries, links: links, categories: categories), calendar: .utc)
  }
}

/// The ledger against the model of `RandomBook`, month by month.
@Suite("The ledger against a model of the money, month by month")
struct LedgerPropertyTests {
  static let seeds: [UInt64] = Array(1...40)
  static let months = (0..<9).map { MonthKey(year: 2026, month: 1).adding(months: $0) }

  func range(_ month: MonthKey) -> DayRange {
    let first = DateOnly(year: month.year, month: month.month, day: 1)
    return DayRange(first, first.adding(months: 1).adding(days: -1))
  }

  /// Each month spends what its purchases cost less what came back from them — refunds in
  /// later months included —, and earns the income that is for it.
  @Test(arguments: seeds)
  func eachMonthSpendsAndEarnsWhatTheModelSays(seed: UInt64) {
    let book = RandomBook(seed: seed)
    let ledger = book.ledger
    let spending = book.spendingByMonth
    let income = book.incomeByMonth
    for month in Self.months {
      #expect(
        ledger.expenses(in: range(month)) == spending[month] ?? .zero, "seed \(seed), \(month)")
      #expect(
        ledger.income(in: .month(month)) == income[month] ?? .zero, "seed \(seed), \(month)")
    }
  }

  /// A linked refund row adds nothing on its own day, and the whole of every month adds up to
  /// what the day headers and a selection of everything say.
  @Test(arguments: seeds)
  func theRowsTheDayHeadersAndTheMonthsAgree(seed: UInt64) {
    let book = RandomBook(seed: seed)
    let ledger = book.ledger
    for row in ledger.rows where row.refundOfPartId != nil {
      #expect(row.contribution == .zero, "seed \(seed)")
    }
    let everything = ledger.rowTotals(of: book.live.map(\.id))
    #expect(everything.myExpenses == AmountE4.sum(ledger.rows.map(\.contribution)), "seed \(seed)")
    #expect(
      everything.myExpenses == AmountE4.sum(book.spendingByMonth.values), "seed \(seed)")
    var byDay: [DateOnly: [UUID]] = [:]
    for entry in book.live {
      byDay[CalendarContext.utc.day(of: entry.transaction.occurredAt), default: []].append(entry.id)
    }
    for (day, ids) in byDay {
      let header = ledger.rowTotals(of: ids).myExpenses
      #expect(header == ledger.expenses(in: DayRange(day, day)), "seed \(seed), \(day)")
    }
  }

  /// «Мне должны» is what is left of every part still waiting, and «За других» agrees with it.
  @Test(arguments: seeds)
  func whatIsOwedIsWhatIsLeft(seed: UInt64) {
    let book = RandomBook(seed: seed)
    let ledger = book.ledger
    let owed = book.owed.values.filter { $0.raw > 0 }
    let overview = OverviewSummary(ledger: ledger, today: day("2026-06-30"))
    #expect(overview.owedToMe == AmountE4.sum(owed), "seed \(seed)")
    #expect(overview.owedCount == owed.count, "seed \(seed)")
    let others = OthersReport(
      ledger: ledger, period: .days(DayRange(day("2025-12-01"), day("2026-12-31"))))
    #expect(others.totals.waiting == AmountE4.sum(owed), "seed \(seed)")
    #expect(others.totals.shortfall == .zero, "seed \(seed)")
    #expect(others.totals.returned == book.returnedForOthers, "seed \(seed)")
    #expect(others.totals.paid == book.paidForOthers, "seed \(seed)")
  }
}
