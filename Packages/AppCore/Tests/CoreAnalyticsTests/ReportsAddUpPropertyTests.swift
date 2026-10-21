import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A random book for the tables: purchases split over categories and subcategories, for me, for
/// a «for whom» value and for a person, at places and events, refunds of a purchase and of no
/// purchase, income — and the promise every table makes: it adds up to my expenses of the
/// period, a parent is the sum of its children, and the shares of a level make 100.00 %.
private struct TableBook {
  static let food = id(10)
  static let cafe = id(12)
  static let clothes = id(11)
  static let shoes = id(13)
  static let salary = id(31)
  static let categories = [
    CoreKit.Category(id: food, kind: .expense, name: "Food", quality: .neutral),
    CoreKit.Category(id: cafe, parentId: food, kind: .expense, name: "Cafe", quality: .bad),
    CoreKit.Category(id: clothes, kind: .expense, name: "Clothes", quality: .neutral),
    CoreKit.Category(id: shoes, parentId: clothes, kind: .expense, name: "Shoes"),
    CoreKit.Category(id: salary, kind: .income, name: "Salary"),
  ]
  let start = CalendarContext.utc.startOfDay(day("2026-01-01"))
  var entries: [TransactionEntry] = []
  var dice: MoneyDice
  private var next = 2000

  init(seed: UInt64) {
    dice = MoneyDice(seed: seed &* 0x9E37_79B9 &+ 11)
    for _ in 0..<90 {
      switch dice.below(10) {
      case 0...5: purchase()
      case 6: refund()
      case 7: refundOfNoPurchase()
      default: income()
      }
    }
  }

  mutating func someMoment() -> Date {
    start.addingTimeInterval(TimeInterval(dice.below(200) * 86_400 + dice.below(86_400)))
  }

  mutating func piece(_ amount: AmountE4, category: UUID?) -> TransactionPart {
    let whom = dice.pick([ForWhom.me, .me, .partner, .friends, .family, .other])
    let person: UUID? = dice.chance(40) ? id(300 + dice.below(3)) : nil
    let forOthers = whom != .me && dice.chance(20)
    return TransactionPart(
      transactionId: id(0), categoryId: category, amountE4: amount, forWhom: whom,
      forPersonId: forOthers ? nil : person, reimbursable: forOthers,
      debtorPersonId: forOthers ? id(300) : nil,
      reimbursementStatus: forOthers ? dice.pick([.expected, .writtenOff]) : nil,
      eventId: dice.chance(30) ? id(500 + dice.below(2)) : nil)
  }

  @discardableResult
  mutating func add(
    _ kind: TransactionKind, parts: [TransactionPart], at: Date? = nil
  ) -> TransactionEntry {
    next += 1
    let number = next
    let moment = at ?? someMoment()
    var fixed = parts
    for index in fixed.indices {
      fixed[index].id = id(number * 10 + index)
      fixed[index].transactionId = id(number)
      fixed[index].amountRubE4 = fixed[index].amountE4
    }
    let amount = AmountE4.sum(fixed.map(\.amountE4))
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: kind, occurredAt: moment, amountE4: amount, amountRubE4: amount,
        placeId: dice.chance(60) ? id(400 + dice.below(3)) : nil,
        paymentMethodId: dice.chance(80) ? id(1) : id(2), createdAt: moment,
        updatedAt: moment),
      parts: fixed)
    entries.append(entry)
    return entry
  }

  mutating func purchase() {
    let parts = (0..<dice.int(1...3)).map { _ in
      piece(
        dice.amount(upTo: 5000),
        category: dice.pick([Self.food, Self.cafe, Self.clothes, Self.shoes, nil]))
    }
    add(.expense, parts: parts)
  }

  mutating func refund() {
    let purchases = entries.filter { $0.transaction.kind == .expense }
    guard !purchases.isEmpty else { return purchase() }
    let purchase = dice.pick(purchases)
    let part = dice.pick(purchase.parts)
    var back = piece(
      AmountE4(raw: Int64(dice.int(1...Int(part.amountE4.raw)))), category: part.categoryId)
    back.refundOfPartId = part.id
    back.forWhom = part.forWhom
    back.forPersonId = part.forPersonId
    back.reimbursable = false
    back.debtorPersonId = nil
    back.reimbursementStatus = nil
    add(
      .refund, parts: [back],
      at: purchase.transaction.occurredAt.addingTimeInterval(TimeInterval(dice.below(40) * 86_400)))
  }

  mutating func refundOfNoPurchase() {
    var back = piece(
      dice.amount(upTo: 3000), category: dice.pick([Self.food, Self.cafe, Self.shoes]))
    back.reimbursable = false
    back.debtorPersonId = nil
    back.reimbursementStatus = nil
    add(.refund, parts: [back])
  }

  mutating func income() {
    var part = piece(dice.amount(upTo: 60_000), category: Self.salary)
    part.forWhom = .me
    part.forPersonId = nil
    part.eventId = nil
    part.reimbursable = false
    part.debtorPersonId = nil
    part.reimbursementStatus = nil
    add(.income, parts: [part])
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(entries: entries, categories: Self.categories), calendar: .utc)
  }
}

@Suite("Every table adds up to my expenses, its parents and its shares")
struct ReportsAddUpPropertyTests {
  static let seeds: [UInt64] = Array(1...60)
  static let periods: [Period] =
    (1...7).map { Period.month(MonthKey(year: 2026, month: $0)) } + [
      .year(2026), .days(DayRange(day("2026-02-10"), day("2026-05-20"))),
    ]

  /// The shares of a level: 10 000 in all when any line is positive, else none.
  func checkShares(_ nodes: [BreakdownNode], _ note: String) {
    let shares = nodes.compactMap(\.share)
    if nodes.contains(where: { $0.amount.raw > 0 }) {
      #expect(shares.reduce(0, +) == Shares.whole, "\(note): shares \(shares)")
    }
    for node in nodes where node.amount.raw <= 0 {
      #expect(node.share == nil, "\(note): a line not above zero has no share")
    }
  }

  /// A two-level table: each parent the sum of its children, the upper level's shares and the
  /// lowest level's — children and childless parents — each 100 %.
  func checkTwoLevel(_ nodes: [BreakdownNode], total: AmountE4, _ note: String) {
    #expect(AmountE4.sum(nodes.map(\.amount)) == total, "\(note): the lines and the total")
    checkShares(nodes, note + " upper")
    var lowest: [BreakdownNode] = []
    for node in nodes {
      if node.children.isEmpty {
        lowest.append(node)
      } else {
        #expect(
          AmountE4.sum(node.children.map(\.amount)) == node.amount,
          "\(note): \(node.key) is not the sum of its children")
        lowest += node.children
      }
    }
    let childless = nodes.filter { $0.children.isEmpty }
    if lowest.contains(where: { $0.amount.raw > 0 }) {
      // The children's shares are taken over the lowest level of the whole table: every child
      // and every childless parent.
      let expected = Shares.basisPoints(lowest.map(\.amount))
      let actualChildren = nodes.flatMap(\.children).map(\.share)
      let expectedChildren = zip(lowest, expected).filter { pair in
        !childless.contains(where: { $0 == pair.0 })
      }.map(\.1)
      #expect(actualChildren == expectedChildren, "\(note): child shares")
    }
  }

  @Test(arguments: seeds)
  func everyTableAddsUpToMyExpenses(seed: UInt64) {
    let ledger = TableBook(seed: seed).ledger
    let builder = ReportBuilder(ledger: ledger, today: day("2026-09-15"))
    for period in Self.periods {
      let expenses = ledger.expenses(in: period.range)
      let note = "seed \(seed), \(period)"
      let breakdown = CategoryBreakdown(ledger: ledger, period: period, kind: .expense)
      #expect(breakdown.total == expenses, "\(note): breakdown")
      checkTwoLevel(breakdown.nodes, total: expenses, note + " breakdown")

      for grouping in ReportGrouping.allCases {
        let two = builder.table(
          .expensesByCategoryAndSubcategory, period: period, grouping: grouping)
        #expect(two.total.amount == expenses, "\(note) \(grouping): two levels")
        checkTwoLevel(
          two.rows.map(Self.node), total: expenses, note + " \(grouping) two levels")
        let one = builder.table(.expensesByCategory, period: period, grouping: grouping)
        #expect(one.total.amount == expenses, "\(note) \(grouping): one level")
        checkShares(one.rows.map(Self.node), note + " \(grouping) one level")
      }

      let forWhom = ForWhomReport(ledger: ledger, period: period)
      #expect(AmountE4.sum(forWhom.values.map(\.amount)) == expenses, "\(note): for whom")
      checkShares(forWhom.values, note + " for whom")
      let ofPeople = AmountE4.sum(
        ledger.rows(in: period.range).filter { $0.personId != nil }.map(\.contribution))
      #expect(AmountE4.sum(forWhom.people.map(\.amount)) == ofPeople, "\(note): people")
      #expect(!forWhom.people.contains { $0.key == .noPerson }, "\(note): no «no person» line")
      if period.isWholeMonths {
        let byMonth = AmountE4.sum(
          forWhom.months.flatMap { $0.amounts.values })
        #expect(byMonth == expenses, "\(note): the months of «for whom»")
      }
    }
  }

  /// The monthly table of the year and the total of the year are one figure.
  @Test(arguments: seeds)
  func theMonthsOfTheYearAddUpToTheYear(seed: UInt64) {
    let ledger = TableBook(seed: seed).ledger
    let builder = ReportBuilder(ledger: ledger, today: day("2026-09-15"))
    let monthly = builder.table(.monthly, period: .year(2026))
    let total = builder.table(.periodTotal, period: .year(2026))
    let expenses = total.rows.first { $0.key == .expenses }?.amount
    let income = total.rows.first { $0.key == .income }?.amount
    #expect(monthly.total.values[0] == expenses, "seed \(seed): expenses")
    #expect(monthly.total.values[1] == income, "seed \(seed): income")
    #expect(monthly.total.values[2] == total.total.amount, "seed \(seed): net")
    let months = monthly.rows.compactMap { $0.values[0] }
    #expect(AmountE4.sum(months) == expenses, "seed \(seed): the month lines")
  }

  static func node(_ row: ReportRow) -> BreakdownNode {
    BreakdownNode(
      key: row.key, amount: row.amount ?? .zero, share: row.share,
      children: row.children.map(node))
  }
}
