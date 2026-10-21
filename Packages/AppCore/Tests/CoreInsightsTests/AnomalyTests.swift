import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

/// A history built so that each of the seven anomaly rules has exactly one thing to find and
/// every other rule has nothing — «на синтетике с известными ответами».
///
/// Today is Saturday 19 September 2026, so the last **complete** week is 7–13 September and
/// the eight weeks before it run from 13 July to 6 September.
private struct AnomalyBook {
  static let today = day("2026-09-19")
  /// The Monday of the last complete week.
  static let spikeWeek = day("2026-09-07")

  let food = id(1)
  let cafe = id(2)
  let groceries = id(3)
  let transport = id(4)
  let services = id(5)
  let shopping = id(6)
  let gifts = id(7)
  let goalsRoot = id(8)

  let friend = id(20)
  let subscription = id(30)
  /// 15–20 September, budget 1 000, spent 1 500.
  let party = Event(
    id: id(40), name: "Party", startDate: day("2026-09-15"), endDate: day("2026-09-20"),
    budgetE4: money("1000"))

  /// The part that has been waiting for its money since 1 August.
  private(set) var waitingPartId = UUID()
  /// The later of the two operations five minutes apart.
  private(set) var duplicatePartId = UUID()
  /// The single payment far above what groceries usually cost.
  private(set) var largePartId = UUID()

  var entries: [TransactionEntry] = []
  private var next = 1_000

  init() {
    // Food: one cafe payment of 1 000 in each of the eight weeks before the last complete
    // one, and two of them in the last complete week. The week doubles; no single payment
    // stands out, and the ten payments are just enough to give the category a threshold.
    for week in 0..<8 {
      add(Self.weekday(weeksBefore: 8 - week, weekday: 2), "1000", category: cafe)
    }
    add("2026-09-08", "1000", category: cafe, quality: .bad)
    add("2026-09-10", "1000", category: cafe, quality: .bad)

    // Groceries: ten payments of 500 and one of 5 000 four days ago.
    add("2026-07-01", "500", category: groceries)
    add("2026-07-08", "500", category: groceries)
    for week in 0..<8 {
      add(Self.weekday(weeksBefore: 8 - week, weekday: 4), "500", category: groceries)
    }
    largePartId = add("2026-09-16", "5000", category: groceries)

    // Transport: the same 300 twice within five minutes.
    add("2026-09-17", "300", category: transport, hour: 10, minute: 0)
    duplicatePartId = add("2026-09-17", "300", category: transport, hour: 10, minute: 5)

    // A subscription charged monthly, dearer since September.
    add("2026-07-05", "600", category: services, payment: subscription)
    add("2026-08-05", "600", category: services, payment: subscription)
    add("2026-09-05", "800", category: services, payment: subscription)

    // Bad spending: 1 000 of it in each of the eight weeks, and 2 000 in the last complete
    // week — the two cafe payments above, which are the only bad ones there.
    for week in 0..<8 {
      add(
        Self.weekday(weeksBefore: 8 - week, weekday: 3), "1000", category: shopping, quality: .bad)
    }

    // Paid for a friend on 1 August and still waiting.
    waitingPartId = add("2026-08-01", "1500", category: cafe, reimbursable: true)

    // The party costs half again what it was given.
    add("2026-09-16", "1500", category: gifts, event: party)
  }

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: food, kind: .expense, name: "Food", quality: .neutral),
      CoreKit.Category(id: cafe, parentId: food, kind: .expense, name: "Cafe"),
      CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: transport, kind: .expense, name: "Transport", quality: .neutral),
      CoreKit.Category(id: services, kind: .expense, name: "Services", quality: .neutral),
      CoreKit.Category(id: shopping, kind: .expense, name: "Shopping", quality: .bad),
      CoreKit.Category(id: gifts, kind: .expense, name: "Gifts", quality: .good),
      CoreKit.Category(
        id: goalsRoot, kind: .expense, name: "Goals", quality: .neutral, systemRole: .goals),
    ]
  }

  var dataset: Dataset {
    Dataset(
      entries: entries, categories: categories,
      people: [Person(id: friend, name: "Friend")], events: [party])
  }

  var ledger: Ledger { Ledger(dataset: dataset, calendar: .utc) }

  var events: EventsPlanning { EventPlanning.build(ledger: ledger, today: Self.today) }

  func report(
    sensitivity: AnomalySensitivity = .normal, dismissals: [AnomalyDismissal] = []
  ) -> AnomalyReport {
    AnomalyRules.build(
      ledger: ledger, events: events, today: Self.today, dismissals: dismissals,
      options: .standard(sensitivity))
  }

  // MARK: - Making the operations

  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  /// A plain decimal, a dot and at most four places — «1250.5». Anything else is a typo, and a
  /// failed test that names it: `Decimal(string:)` alone read «1 000» as 1 and «abc» as zero.
  static func money(_ text: String) -> AmountE4 {
    guard text.wholeMatch(of: /-?[0-9]+(\.[0-9]{1,4})?/) != nil,
      let decimal = Decimal(string: text), let amount = try? AmountE4(decimal: decimal)
    else {
      Issue.record("«\(text)» is not an amount: write a plain decimal, such as 1250.5")
      return .zero
    }
    return amount
  }

  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }

  /// A day of a week before the last complete one: `weekday` 1 is its Monday.
  static func weekday(weeksBefore weeks: Int, weekday: Int) -> String {
    spikeWeek.adding(days: -7 * weeks + weekday - 1).iso
  }

  /// `hour` 12 and `minute` 0 is noon of the day — the moment the app gives an operation
  /// typed without a time (`CalendarContext.noon(of:)`).
  @discardableResult
  mutating func add(
    _ iso: String, _ amount: String, category: UUID?, quality: Quality = .neutral,
    reimbursable: Bool = false, event: Event? = nil, payment: UUID? = nil, hour: Int = 12,
    minute: Int = 0
  ) -> UUID {
    next += 1
    let transactionId = Self.id(next)
    let partId = Self.id(next + 500_000)
    let when = CalendarContext.utc.startOfDay(Self.day(iso))
      .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    let part = TransactionPart(
      id: partId, transactionId: transactionId, categoryId: category, quality: quality,
      qualitySource: .manual, amountE4: Self.money(amount),
      forWhom: reimbursable ? .friends : .me, forPersonId: reimbursable ? friend : nil,
      reimbursable: reimbursable, reimbursementStatus: reimbursable ? .expected : nil,
      eventId: event?.id)
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: .expense, occurredAt: when, amountE4: Self.money(amount),
          externalId: payment.map { OperationLink.scheduled(paymentId: $0, due: Self.day(iso)) }?
            .externalId,
          createdAt: when, updatedAt: when),
        parts: [part]))
    return partId
  }
}

@Suite("Anomalies: seven rules on a history with known answers")
struct AnomalyTests {
  private let book = AnomalyBook()

  /// The whole point of the fixture: each rule finds its one thing, and nothing else.
  @Test("Each rule fires exactly once")
  func eachRuleFiresOnce() {
    let found = book.report().all
    let byRule = Dictionary(grouping: found, by: \.rule).mapValues(\.count)

    for rule in AnomalyRule.allCases {
      #expect(byRule[rule] == 1, "\(rule.rawValue) fired \(byRule[rule] ?? 0) times, not once")
    }
    #expect(found.count == AnomalyRule.allCases.count)
  }

  @Test("A payment far above what its category usually costs")
  func theLargePayment() throws {
    let found = try #require(book.report().all.first { $0.rule == .largeExpense })

    #expect(found.partId == book.largePartId)
    #expect(found.amount == AnomalyBook.money("5000"))
    // Ten payments of 500: the median is 500 and the spread never falls below a tenth of
    // it, so the threshold is 500 + 3.5 × 50.
    #expect(found.reference == AnomalyBook.money("675"))
    #expect(found.day == AnomalyBook.day("2026-09-16"))
  }

  @Test("The same amount in the same category minutes apart")
  func theDuplicate() throws {
    let found = try #require(book.report().all.first { $0.rule == .possibleDuplicate })

    #expect(found.partId == book.duplicatePartId)
    #expect(found.amount == AnomalyBook.money("300"))
    #expect(found.categoryId == book.transport)
  }

  /// A day typed without a time gets noon (`CalendarContext.noon(of:)`) — a moment nobody
  /// said. Two fares of 300 on 18 September entered that way say nothing about ten minutes,
  /// and neither does one of them next to a fare paid at 11:55 that day: no duplicate.
  @Test("Operations without a time of their own are nobody's duplicates")
  func operationsWithoutATimeAreNotDuplicates() {
    var book = AnomalyBook()
    book.add("2026-09-18", "300", category: book.transport)
    book.add("2026-09-18", "300", category: book.transport)
    book.add("2026-09-18", "300", category: book.transport, hour: 11, minute: 55)
    let duplicates = book.report().all.filter { $0.rule == .possibleDuplicate }
    #expect(duplicates.map(\.partId) == [book.duplicatePartId])
  }

  @Test("A subscription that costs more than it did last time")
  func thePriceRise() throws {
    let found = try #require(book.report().all.first { $0.rule == .subscriptionPriceRise })

    #expect(found.paymentId == book.subscription)
    #expect(found.amount == AnomalyBook.money("800"))
    #expect(found.reference == AnomalyBook.money("600"))
    #expect(found.subject == book.subscription.uuidString.lowercased())
  }

  @Test("A week of a category well above its usual level")
  func theCategorySpike() throws {
    let found = try #require(book.report().all.first { $0.rule == .categorySpike })

    #expect(found.categoryId == book.food)
    #expect(found.amount == AnomalyBook.money("2000"))
    #expect(found.reference == AnomalyBook.money("1000"))
    #expect(found.day == AnomalyBook.spikeWeek)
  }

  @Test("A week of bad spending well above its usual level")
  func theBadSpendingRise() throws {
    let found = try #require(book.report().all.first { $0.rule == .badSpendingRise })

    #expect(found.amount == AnomalyBook.money("2000"))
    #expect(found.reference == AnomalyBook.money("1000"))
    #expect(found.day == AnomalyBook.spikeWeek)
    #expect(found.subject == AnomalyBook.spikeWeek.iso)
  }

  @Test("Money paid for somebody else and still not back")
  func theSlowReimbursement() throws {
    let found = try #require(book.report().all.first { $0.rule == .slowReimbursement })

    #expect(found.partId == book.waitingPartId)
    #expect(found.personId == book.friend)
    #expect(found.amount == AnomalyBook.money("1500"))
    #expect(found.days == 49)
  }

  /// A part the owner closed by hand with the money that came — «Вручную…», what is missing
  /// written as my expense (`ReimbursementResolver`) — waits for nothing more, however little
  /// came. A part money back covered only in part and left open still waits for the rest
  /// (`AnomalyRefundFoldTests`).
  @Test("A partial return closes the part, and the wait is over")
  func aPartialReturnEndsTheWait() throws {
    var entries = book.entries
    let owed = try #require(
      MyExpensesRule.owedToMe(entries: entries).first { $0.partId == book.waitingPartId })
    let reimbursementId = AnomalyBook.id(900)
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: reimbursementId, amountE4: AnomalyBook.money("1000"), closing: [owed])
    #expect(outcome.closedPartIds == [book.waitingPartId])
    #expect(outcome.shortfalls.map(\.amountE4) == [AnomalyBook.money("500")])

    // What the repository writes: the reimbursement, its links and the closed statuses.
    let when = CalendarContext.utc.startOfDay(AnomalyBook.day("2026-08-20"))
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: reimbursementId, kind: .reimbursement, occurredAt: when,
          amountE4: AnomalyBook.money("1000"), createdAt: when, updatedAt: when),
        parts: [
          TransactionPart(
            id: AnomalyBook.id(901), transactionId: reimbursementId,
            amountE4: AnomalyBook.money("1000"), forPersonId: book.friend)
        ]))
    for index in entries.indices {
      for part in entries[index].parts.indices
      where outcome.closedPartIds.contains(entries[index].parts[part].id) {
        entries[index].parts[part].reimbursementStatus = .returned
      }
    }
    let ledger = Ledger(
      dataset: Dataset(
        entries: entries, links: outcome.links, categories: book.categories,
        people: [Person(id: book.friend, name: "Friend")], events: [book.party]),
      calendar: .utc)
    #expect(ledger.returned(forPart: book.waitingPartId) == AnomalyBook.money("1000"))

    let report = AnomalyRules.build(
      ledger: ledger, events: EventPlanning.build(ledger: ledger, today: AnomalyBook.today),
      today: AnomalyBook.today)
    #expect(!report.all.contains { $0.rule == .slowReimbursement })
  }

  @Test("An event that has cost more than it was given")
  func theEventOverBudget() throws {
    let found = try #require(book.report().all.first { $0.rule == .eventOverBudget })

    #expect(found.eventId == book.party.id)
    #expect(found.amount == AnomalyBook.money("1500"))
    #expect(found.reference == AnomalyBook.money("1000"))
  }

  /// «Порог настраивается»: the same history, read more and less eagerly.
  @Test("Sensitivity only ever adds or removes, never rewrites")
  func sensitivityMovesTheLine() {
    let low = Set(book.report(sensitivity: .low).all.map(\.id))
    let normal = Set(book.report(sensitivity: .normal).all.map(\.id))
    let high = Set(book.report(sensitivity: .high).all.map(\.id))

    #expect(low.isSubset(of: normal), "a low sensitivity found something a normal one did not")
    #expect(normal.isSubset(of: high), "a normal sensitivity found something a high one did not")
  }

  /// A dismissal is forgotten when its anomaly no longer arises — at any sensitivity, not
  /// only the one chosen now. The week that doubled is no spike to a low sensitivity; the
  /// owner who waved it away at «normal», turned the level down and waved something else
  /// away must not see it come back when the level goes up again.
  @Test("What only a higher sensitivity finds still arises at a lower one")
  func aLowerSensitivityForgetsNothingAHigherOneFinds() throws {
    let low = book.report(sensitivity: .low)
    let high = Set(book.report(sensitivity: .high).all.map(\.id))
    let onlyHigher = high.subtracting(low.all.map(\.id))
    try #require(!onlyHigher.isEmpty, "the book has nothing only a high sensitivity finds")

    #expect(
      onlyHigher.subtracting(low.activeKeys).isEmpty,
      "a dismissal of an anomaly a higher level finds would be forgotten at a low one")
    #expect(low.activeKeys == high, "the anomalies that arise depend on the level chosen")
  }

  /// «Это нормально» hides one anomaly and leaves every other one alone, including the
  /// anomalies of the same rule.
  @Test("Dismissing one anomaly hides that one and no other")
  func dismissingHidesExactlyOne() throws {
    let spike = try #require(book.report().all.first { $0.rule == .categorySpike })
    let report = book.report(dismissals: [
      AnomalyDismissal(
        rule: .categorySpike, subject: spike.subject, at: Date(timeIntervalSince1970: 0))
    ])

    #expect(report.visible.count == AnomalyRule.allCases.count - 1)
    #expect(report.hidden.map(\.id) == [spike.id])
    // Hidden is not gone: the dismissal is still about something that happens, so it must
    // survive the garbage collection.
    #expect(report.activeKeys.contains(spike.id))
  }

  /// A dismissal of something that no longer happens is forgotten, exactly the way a
  /// put-off reminder is (`ReminderRules.dismissed`).
  @Test("A dismissal of an anomaly that no longer arises is forgotten")
  func staleDismissalsAreForgotten() {
    let stale = AnomalyDismissal(
      rule: .largeExpense, subject: UUID().uuidString, at: Date(timeIntervalSince1970: 0))
    let report = book.report(dismissals: [stale])

    #expect(!report.activeKeys.contains(stale.key))
    #expect(report.visible.count == AnomalyRule.allCases.count)
  }

  /// The one predicate the first five rules share: nothing system, nothing paid for
  /// somebody else, nothing the app wrote for its own books.
  @Test("Nothing system and nothing paid for others reaches the first five rules")
  func theFirstFiveLookAtMySpendingOnly() {
    let found = book.report().all.filter { $0.rule.isAboutMyOwnSpending }
    let rows = Dictionary(
      book.ledger.rows.map { ($0.partId, $0) }, uniquingKeysWith: { first, _ in first })

    for anomaly in found {
      guard let partId = anomaly.partId, let row = rows[partId] else { continue }
      #expect(row.systemRole == nil)
      #expect(!row.reimbursable)
      #expect(row.contribution.raw > 0)
    }
  }

  /// The midpoint of the two middle amounts is money arithmetic: through `Decimal`, rounded
  /// half away from zero like every other amount (and like `IncomeEstimate.median`), not
  /// the integer division that drops half a stored unit.
  @Test("The median of an even count rounds its midpoint half away from zero")
  func theMedianRoundsLikeMoney() {
    #expect(AnomalyRules.median([1, 2]) == 2)
    #expect(AnomalyRules.median([-2, -1]) == -2)
    #expect(AnomalyRules.median([5_000_000, 5_000_001, 1, 9_000_000]) == 5_000_001)
    #expect(AnomalyRules.median([4, 2, 6]) == 4)
    #expect(AnomalyRules.median([]) == 0)
  }

  /// An empty history says nothing at all — no rule may invent an anomaly out of nothing.
  @Test("An empty history has no anomalies")
  func anEmptyHistoryIsQuiet() {
    let report = AnomalyRules.build(
      ledger: Ledger(dataset: .empty, calendar: .utc), today: AnomalyBook.today)

    #expect(report.all.isEmpty)
  }
}

/// `AnomalyBook.money` reads an amount written as text. A typo is a failed test that names it,
/// never a quiet zero or the number `Decimal(string:)` finds at its start: «1 000» was 1.
@Suite("Amount literals of the anomaly fixtures")
struct AnomalyAmountLiteralTests {
  @Test(arguments: ["1 000", "1,000", "1000 ₽", "1e3", ".5", "0.12345", "abc", ""])
  func aTypoIsAFailedTest(_ text: String) {
    withKnownIssue { _ = AnomalyBook.money(text) }
  }
}
