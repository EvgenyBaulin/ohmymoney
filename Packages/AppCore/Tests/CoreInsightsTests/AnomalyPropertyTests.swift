import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreInsights

/// The anomaly rules on random ledgers of purchases, refunds linked to them, parts paid for
/// friends and money back that covers some of them: whatever the book, the rules speak of
/// what the ledger counts — a refund inside its purchase, what is still owed on a part — and
/// the sensitivity only draws the line.
@Suite("Anomalies on random ledgers with refunds and money back")
struct AnomalyPropertyTests {
  static let seeds: [UInt64] = Array(1...30)
  static let today = DateOnly(year: 2026, month: 9, day: 19)
  static let groceries = UUID(uuidString: "00000000-0000-0000-0000-00000000B001") ?? UUID()
  static let music = UUID(uuidString: "00000000-0000-0000-0000-00000000B002") ?? UUID()

  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "0000B000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  struct Book {
    var entries: [TransactionEntry] = []
    var links: [ReimbursementLink] = []
    var refundParts: Set<UUID> = []

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      var purchases: [TransactionPart] = []
      var number = 1
      func next() -> Int {
        number += 1
        return number
      }
      let start = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 5, day: 1))
      for _ in 0..<random.int(in: 20...80) {
        let transaction = AnomalyPropertyTests.id(next())
        let at = start.addingTimeInterval(TimeInterval(random.int(in: 0...(140 * 24 * 60)) * 60))
        let amount = AmountE4(whole: Int64(random.choice(from: [300, 500, 500, 700, 5_000])))
        let forFriend = random.chance(1, outOf: 6)
        let part = TransactionPart(
          id: AnomalyPropertyTests.id(next()), transactionId: transaction,
          categoryId: random.chance(3, outOf: 4)
            ? AnomalyPropertyTests.groceries : AnomalyPropertyTests.music,
          quality: random.chance(1, outOf: 4) ? .bad : .neutral, qualitySource: .manual,
          amountE4: amount, amountRubE4: amount, forWhom: forFriend ? .friends : .me,
          reimbursable: forFriend, debtorPersonId: forFriend ? AnomalyPropertyTests.id(1) : nil,
          reimbursementStatus: forFriend ? .expected : nil)
        entries.append(
          TransactionEntry(
            transaction: Transaction(
              id: transaction, kind: .expense, occurredAt: at, amountE4: amount,
              amountRubE4: amount, createdAt: at, updatedAt: at),
            parts: [part]))
        purchases.append(part)
        // A twin a few minutes later now and then: a duplicate to find, or a refunded one.
        if random.chance(1, outOf: 8) {
          let twin = AnomalyPropertyTests.id(next())
          let twinAt = at.addingTimeInterval(TimeInterval(random.int(in: 1...9) * 60))
          var twinPart = part
          twinPart.id = AnomalyPropertyTests.id(next())
          twinPart.transactionId = twin
          entries.append(
            TransactionEntry(
              transaction: Transaction(
                id: twin, kind: .expense, occurredAt: twinAt, amountE4: amount,
                amountRubE4: amount, createdAt: twinAt, updatedAt: twinAt),
              parts: [twinPart]))
          purchases.append(twinPart)
        }
      }
      // Refunds of some of my purchases: all of it or some, a few days later.
      for part in purchases where !part.reimbursable && random.chance(1, outOf: 5) {
        guard let purchase = entries.first(where: { $0.id == part.transactionId }) else {
          continue
        }
        let refund = AnomalyPropertyTests.id(next())
        let at = purchase.transaction.occurredAt.addingTimeInterval(
          TimeInterval(random.int(in: 1...10) * 86_400))
        let amount =
          random.chance(1, outOf: 2)
          ? part.amountE4
          : AmountE4(whole: Int64(random.int(in: 1...Int(part.amountE4.raw / 10_000))))
        let refundPart = TransactionPart(
          id: AnomalyPropertyTests.id(next()), transactionId: refund, categoryId: part.categoryId,
          amountE4: amount, amountRubE4: amount, refundOfPartId: part.id)
        refundParts.insert(refundPart.id)
        entries.append(
          TransactionEntry(
            transaction: Transaction(
              id: refund, kind: .refund, occurredAt: at, amountE4: amount, amountRubE4: amount,
              createdAt: at, updatedAt: at),
            parts: [refundPart]))
      }
      // Money back for some of the friend's parts: all of it or some.
      for part in purchases where part.reimbursable && random.chance(1, outOf: 2) {
        let back = AnomalyPropertyTests.id(next())
        let amount =
          random.chance(1, outOf: 3)
          ? part.amountE4
          : AmountE4(whole: Int64(random.int(in: 1...Int(part.amountE4.raw / 10_000))))
        let at = start.addingTimeInterval(TimeInterval(150 * 86_400))
        entries.append(
          TransactionEntry(
            transaction: Transaction(
              id: back, kind: .reimbursement, occurredAt: at, amountE4: amount,
              amountRubE4: amount, createdAt: at, updatedAt: at),
            parts: [
              TransactionPart(
                id: AnomalyPropertyTests.id(next()), transactionId: back, amountE4: amount,
                amountRubE4: amount, forPersonId: AnomalyPropertyTests.id(1))
            ]))
        links.append(ReimbursementLink(reimbursementTxId: back, partId: part.id, amountE4: amount))
      }
      // A busy week now and then — the last complete one, 7–13 September — so the weekly rules
      // have something to find: groceries, some of them bad, some refunded within the week.
      // Drawn from a stream of its own, so the rest of the book stays what it was.
      var busy = SeededRandom(seed: seed &* 17 &+ 3)
      if busy.chance(2, outOf: 3) {
        let monday = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 7))
        for _ in 0..<busy.int(in: 3...8) {
          let transaction = AnomalyPropertyTests.id(next())
          let at = monday.addingTimeInterval(TimeInterval(busy.int(in: 0...(6 * 24 * 60)) * 60))
          let amount = AmountE4(whole: Int64(busy.choice(from: [700, 1_000, 1_500, 2_500])))
          let part = TransactionPart(
            id: AnomalyPropertyTests.id(next()), transactionId: transaction,
            categoryId: AnomalyPropertyTests.groceries,
            quality: busy.chance(1, outOf: 2) ? .bad : .neutral, qualitySource: .manual,
            amountE4: amount, amountRubE4: amount)
          entries.append(
            TransactionEntry(
              transaction: Transaction(
                id: transaction, kind: .expense, occurredAt: at, amountE4: amount,
                amountRubE4: amount, createdAt: at, updatedAt: at),
              parts: [part]))
          guard busy.chance(1, outOf: 3) else { continue }
          let refund = AnomalyPropertyTests.id(next())
          let back = AmountE4(whole: Int64(busy.int(in: 1...Int(amount.raw / 10_000))))
          let refundPart = TransactionPart(
            id: AnomalyPropertyTests.id(next()), transactionId: refund,
            categoryId: part.categoryId, amountE4: back, amountRubE4: back, refundOfPartId: part.id)
          refundParts.insert(refundPart.id)
          let refundAt = at.addingTimeInterval(3_600)
          entries.append(
            TransactionEntry(
              transaction: Transaction(
                id: refund, kind: .refund, occurredAt: refundAt, amountE4: back,
                amountRubE4: back, createdAt: refundAt, updatedAt: refundAt),
              parts: [refundPart]))
        }
      }
    }

    /// What each week costs me by the plain rule, by the Monday of the week: every part of a
    /// purchase of my own less what was refunded of it, wherever the refund is dated — `bad`
    /// only, or of one category only.
    func weeks(bad: Bool, category: UUID? = nil) -> [DateOnly: AmountE4] {
      var refunded: [UUID: AmountE4] = [:]
      for entry in entries where entry.transaction.kind == .refund {
        for part in entry.parts {
          if let of = part.refundOfPartId { refunded[of, default: .zero] += part.amountE4 }
        }
      }
      var result: [DateOnly: AmountE4] = [:]
      for entry in entries where entry.transaction.kind == .expense {
        let day = CalendarContext.utc.day(of: entry.transaction.occurredAt)
        let monday = day.adding(days: -(day.weekday - 1))
        for part in entry.parts where !part.reimbursable {
          if bad, part.quality != .bad { continue }
          if let category, part.categoryId != category { continue }
          let left = part.amountE4 - (refunded[part.id] ?? .zero)
          if left.raw > 0 { result[monday, default: .zero] += left }
        }
      }
      return result
    }

    var ledger: Ledger {
      Ledger(
        dataset: Dataset(
          entries: entries, links: links,
          categories: [
            CoreKit.Category(
              id: AnomalyPropertyTests.groceries, kind: .expense, name: "Groceries",
              quality: .neutral),
            CoreKit.Category(
              id: AnomalyPropertyTests.music, kind: .expense, name: "Music", quality: .neutral),
          ]),
        calendar: .utc)
    }
  }

  /// A payment and a duplicate are about a part that still costs me something; a payment says
  /// what it costs once its refunds are taken off, a duplicate says its check — a charge made
  /// twice is the same charge whatever came back of it; no refund is ever an anomaly of its own.
  @Test(arguments: seeds)
  func paymentRulesSpeakOfWhatThePurchaseStillCosts(_ seed: UInt64) {
    let book = Book(seed: seed)
    let ledger = book.ledger
    let report = AnomalyRules.build(ledger: ledger, today: Self.today)
    for anomaly in report.all where [.largeExpense, .possibleDuplicate].contains(anomaly.rule) {
      guard let partId = anomaly.partId, let row = ledger.row(ofPart: partId) else {
        Issue.record("seed \(seed): \(anomaly.rule) without its part")
        continue
      }
      #expect(row.kind == .expense, "seed \(seed)")
      #expect(row.contribution.raw > 0, "seed \(seed)")
      #expect(
        anomaly.amount
          == (anomaly.rule == .possibleDuplicate ? row.amountRubE4 : row.contribution),
        "seed \(seed)")
      #expect(!row.reimbursable)
      #expect(!book.refundParts.contains(partId))
    }
  }

  /// «Долгий возврат» is about exactly the parts for a friend still expected more than 30
  /// days, and it names what is left of each: the part less the live money back linked to it.
  @Test(arguments: seeds)
  func aSlowReturnNamesWhatIsLeft(_ seed: UInt64) {
    let book = Book(seed: seed)
    let ledger = book.ledger
    let slow = AnomalyRules.build(ledger: ledger, today: Self.today).all.filter {
      $0.rule == .slowReimbursement
    }
    var model: [UUID: AmountE4] = [:]
    for entry in book.entries {
      for part in entry.parts where part.reimbursable {
        let day = CalendarContext.utc.day(of: entry.transaction.occurredAt)
        guard day.days(to: Self.today) > 30 else { continue }
        let back = AmountE4.sum(book.links.filter { $0.partId == part.id }.map(\.amountE4))
        let left = max(.zero, part.amountE4 - back)
        if left.raw > 0 { model[part.id] = left }
      }
    }
    #expect(slow.count == model.count, "seed \(seed)")
    for anomaly in slow {
      #expect(anomaly.amount == anomaly.partId.flatMap { model[$0] }, "seed \(seed)")
    }
  }

  /// A lower sensitivity finds nothing a higher one does not, and every level knows the same
  /// anomalies still arising — so a dismissal lives as long as its anomaly at any level.
  @Test(arguments: seeds)
  func theLevelsAreNested(_ seed: UInt64) {
    let ledger = Book(seed: seed).ledger
    let reports = [AnomalySensitivity.low, .normal, .high].map {
      AnomalyRules.build(ledger: ledger, today: Self.today, options: .standard($0))
    }
    let ids = reports.map { Set($0.all.map(\.id)) }
    #expect(ids[0].isSubset(of: ids[1]), "seed \(seed)")
    #expect(ids[1].isSubset(of: ids[2]), "seed \(seed)")
    #expect(reports[0].activeKeys == reports[2].activeKeys, "seed \(seed)")
    #expect(reports[1].activeKeys == reports[2].activeKeys, "seed \(seed)")
    for report in reports {
      #expect(report.activeKeys.isSuperset(of: report.all.map(\.id)), "seed \(seed)")
    }
  }

  /// The list is newest first and the same whatever order the book came in.
  @Test(arguments: seeds)
  func theOrderIsTheBooksNotTheInputs(_ seed: UInt64) {
    var book = Book(seed: seed)
    let first = AnomalyRules.build(ledger: book.ledger, today: Self.today).all
    #expect(zip(first, first.dropFirst()).allSatisfy { $0.day >= $1.day }, "seed \(seed)")
    var random = SeededRandom(seed: seed &* 13)
    book.entries.shuffle(using: &random)
    book.links.shuffle(using: &random)
    #expect(AnomalyRules.build(ledger: book.ledger, today: Self.today).all == first, "seed \(seed)")
  }
}

extension AnomalyPropertyTests {
  /// The weekly rules against the plain rule: the last complete week (7–13 September) is a
  /// spike of a category, or a rise of bad spending, exactly when it costs more than half again
  /// the median of the eight weeks before it and that median is at least 500 — each week what
  /// its purchases still cost once their refunds, dated anywhere, are taken off.
  @Test(arguments: seeds)
  func theWeeklyRulesCountWhatTheWeekStillCosts(_ seed: UInt64) {
    let book = Book(seed: seed)
    let report = AnomalyRules.build(ledger: book.ledger, today: Self.today)
    let last = DateOnly(year: 2026, month: 9, day: 7)
    let before = (1...8).map { last.adding(days: -7 * $0) }
    func expected(_ weeks: [DateOnly: AmountE4]) -> (AmountE4, AmountE4)? {
      // The median of eight weeks: the midpoint of the fourth and the fifth, half a unit up.
      let sorted = before.map { (weeks[$0] ?? .zero).raw }.sorted()
      let usual = (sorted[3] + sorted[4] + 1) / 2
      guard usual >= AmountE4(whole: 500).raw else { return nil }
      let amount = weeks[last] ?? .zero
      guard amount.raw > usual + (usual + 1) / 2 else { return nil }
      return (amount, AmountE4(raw: usual))
    }
    for category in [Self.groceries, Self.music] {
      let spike = report.all.first { $0.rule == .categorySpike && $0.categoryId == category }
      let model = expected(book.weeks(bad: false, category: category))
      #expect(
        spike.map { [$0.amount, $0.reference] } == model.map { [$0.0, $0.1] }, "seed \(seed)")
      #expect(spike.map(\.day) == model.map { _ in last })
    }
    let bad = report.all.first { $0.rule == .badSpendingRise }
    let model = expected(book.weeks(bad: true))
    #expect(bad.map { [$0.amount, $0.reference] } == model.map { [$0.0, $0.1] }, "seed \(seed)")
  }

  /// The random ledgers reach what the rules are about — large payments, duplicates, slow
  /// returns with money back on them, spikes of a category and of bad spending — or the
  /// agreement above would be about nothing.
  @Test func theRandomLedgersReachEveryRule() {
    var counts: [AnomalyRule: Int] = [:]
    var partlyBack = 0
    for seed in Self.seeds {
      let book = Book(seed: seed)
      let ledger = book.ledger
      for anomaly in AnomalyRules.build(ledger: ledger, today: Self.today).all {
        counts[anomaly.rule, default: 0] += 1
        if anomaly.rule == .slowReimbursement, let part = anomaly.partId,
          ledger.returned(forPart: part).raw > 0
        {
          partlyBack += 1
        }
      }
    }
    #expect((counts[.largeExpense] ?? 0) >= 5)
    #expect((counts[.possibleDuplicate] ?? 0) >= 3)
    #expect((counts[.slowReimbursement] ?? 0) >= 5)
    #expect(partlyBack >= 1)
    #expect((counts[.categorySpike] ?? 0) >= 3)
    #expect((counts[.badSpendingRise] ?? 0) >= 3)
  }
}
