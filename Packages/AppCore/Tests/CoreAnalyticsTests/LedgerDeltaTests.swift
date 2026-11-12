import CoreAccounting
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// «A ledger worked out from the one before it is the ledger built whole»: after every kind of
/// write, on synthetic histories, the quick path and the full build agree on every row, index
/// and lookup — and the writes that something else in the ledger is made of take the full build.
@Suite("Ledger delta")
struct LedgerDeltaTests {
  private static let cases = [
    SyntheticCase(seed: 7, months: 6), SyntheticCase(seed: 42, months: 24),
  ]

  /// Every observable of a ledger. Rows and the refund index are compared whole; the lookups
  /// cover what the private indexes answer.
  private func expectSame(
    _ left: Ledger, _ right: Ledger, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(left.rows == right.rows, sourceLocation: sourceLocation)
    #expect(left.firstDay == right.firstDay, sourceLocation: sourceLocation)
    #expect(left.refundIndex == right.refundIndex, sourceLocation: sourceLocation)
    #expect(
      Dictionary(uniqueKeysWithValues: left.entries.map { ($0.id, $0) })
        == Dictionary(uniqueKeysWithValues: right.entries.map { ($0.id, $0) }),
      sourceLocation: sourceLocation)
    var mismatches = 0
    for row in right.rows {
      if left.row(ofPart: row.partId) != row { mismatches += 1 }
      if left.searchKey(of: row.transactionId) != right.searchKey(of: row.transactionId) {
        mismatches += 1
      }
      if left.returned(forPart: row.partId) != right.returned(forPart: row.partId) {
        mismatches += 1
      }
      let a = left.companionsRub(forPart: row.partId)
      let b = right.companionsRub(forPart: row.partId)
      if a.shortfall != b.shortfall || a.writtenOff != b.writtenOff { mismatches += 1 }
    }
    #expect(mismatches == 0, sourceLocation: sourceLocation)
    let months = Set(right.rows.map(\.month)).sorted()
    #expect(
      left.rows(attributedTo: months) == right.rows(attributedTo: months),
      sourceLocation: sourceLocation)
    #expect(
      left.rows(in: DayRange(DateOnly(year: 2024, month: 1, day: 1), DateOnly(year: 2027, month: 1, day: 1)))
        == right.rows(
          in: DayRange(DateOnly(year: 2024, month: 1, day: 1), DateOnly(year: 2027, month: 1, day: 1))),
      sourceLocation: sourceLocation)
  }

  private func dataset(_ testCase: SyntheticCase) -> Dataset {
    Synthetic.dataset(Synthetic.generate(testCase))
  }

  /// An operation the quick path may touch: a purchase nothing else in the ledger leans on.
  private func isPlain(_ entry: TransactionEntry, in dataset: Dataset) -> Bool {
    let targets = Set(dataset.entries.flatMap(\.parts).compactMap(\.refundOfPartId))
    return entry.transaction.kind == .expense && !entry.transaction.isDeleted
      && entry.transaction.externalId == nil
      && !entry.parts.contains {
        $0.qualitySource == .manual || targets.contains($0.id) || $0.refundOfPartId != nil
      }
  }

  private func plain(in dataset: Dataset, skipping: Int = 0) throws -> TransactionEntry {
    let found = dataset.entries.filter { isPlain($0, in: dataset) }
    // Not on the first day: the first day of the ledger is the one thing a removal cannot keep.
    let oldest = try #require(dataset.entries.map(\.transaction.occurredAt).min())
    return try #require(
      found.filter { $0.transaction.occurredAt > oldest.addingTimeInterval(3 * 86_400) }
        .dropFirst(skipping).first)
  }

  private func copy(
    of entry: TransactionEntry, at moment: Date, number: Int
  ) -> TransactionEntry {
    var made = entry
    made.transaction.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    made.transaction.occurredAt = moment
    made.transaction.externalId = nil
    for index in made.parts.indices {
      made.parts[index].id = UUID(
        uuidString: String(format: "00000000-0000-4000-9000-%012d", number * 10 + index))!
      made.parts[index].transactionId = made.transaction.id
    }
    return made
  }

  @Test(arguments: cases)
  func aWrittenPurchaseTakesTheQuickPathAndAgrees(_ testCase: SyntheticCase) throws {
    let base = dataset(testCase)
    let ledger = Ledger(dataset: base, calendar: Synthetic.calendar)
    let template = try plain(in: base)
    let last = try #require(ledger.rows.last)
    // Today, in the middle of the history, and on a day that already has operations.
    for (number, moment) in [
      last.occurredAt.addingTimeInterval(3_600),
      ledger.rows[ledger.rows.count / 2].occurredAt.addingTimeInterval(1),
      template.transaction.occurredAt,
    ].enumerated() {
      let next = base.upserting([copy(of: template, at: moment, number: number + 1)])
      let quick = try #require(ledger.delta(to: next))
      expectSame(quick, Ledger(dataset: next, calendar: Synthetic.calendar))
      expectSame(ledger.updated(to: next), quick)
    }
  }

  @Test(arguments: cases)
  func anEditedPurchaseAgrees(_ testCase: SyntheticCase) throws {
    let base = dataset(testCase)
    let ledger = Ledger(dataset: base, calendar: Synthetic.calendar)
    var edited = try plain(in: base, skipping: 3)
    edited.parts[0].amountE4 = edited.parts[0].amountE4 + AmountE4(raw: 12_300)
    edited.parts[0].amountRubE4 = edited.parts[0].amountRubE4 + AmountE4(raw: 12_300)
    edited.parts[0].note = "A changed note"
    edited.transaction.occurredAt = edited.transaction.occurredAt.addingTimeInterval(86_400 * 2)
    let next = base.upserting([edited])
    let quick = try #require(ledger.delta(to: next))
    expectSame(quick, Ledger(dataset: next, calendar: Synthetic.calendar))
  }

  @Test(arguments: cases)
  func aRemovedAndASoftDeletedPurchaseAgree(_ testCase: SyntheticCase) throws {
    let base = dataset(testCase)
    let ledger = Ledger(dataset: base, calendar: Synthetic.calendar)
    let first = try plain(in: base, skipping: 1)
    let second = try plain(in: base, skipping: 5)

    let removed = base.removing([first.id])
    expectSame(
      try #require(ledger.delta(to: removed)), Ledger(dataset: removed, calendar: Synthetic.calendar))

    var deleted = second
    deleted.transaction.deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let soft = base.upserting([deleted])
    expectSame(
      try #require(ledger.delta(to: soft)), Ledger(dataset: soft, calendar: Synthetic.calendar))
  }

  @Test(arguments: cases)
  func aChainOfWritesStaysEqualToTheFullBuild(_ testCase: SyntheticCase) throws {
    var data = dataset(testCase)
    var ledger = Ledger(dataset: data, calendar: Synthetic.calendar)
    var dice = SystemRandomNumberGeneratorFree(seed: testCase.seed)
    var quick = 0
    for step in 0..<25 {
      let template = try plain(in: data, skipping: Int(dice.next() % 40))
      switch dice.next() % 3 {
      case 0:
        let moment = ledger.rows[Int(dice.next()) % ledger.rows.count].occurredAt
          .addingTimeInterval(Double(dice.next() % 5_000) + 0.5)
        data = data.upserting([copy(of: template, at: moment, number: 100 + step)])
      case 1:
        var edited = template
        edited.parts[0].categoryId =
          data.categories.filter { $0.kind == .expense && $0.systemRole == nil }
          .randomElement(using: &dice)?.id
        edited.parts[0].note = "edit \(step)"
        data = data.upserting([edited])
      default:
        data = data.removing([template.id])
      }
      if ledger.delta(to: data) != nil { quick += 1 }
      ledger = ledger.updated(to: data)
      expectSame(ledger, Ledger(dataset: data, calendar: Synthetic.calendar))
    }
    #expect(quick > 15, "most plain writes take the quick path")
  }

  /// The writes the ledger's other rows lean on: each is built whole, and so is just as equal.
  @Test func writesThatOtherRowsLeanOnTakeTheFullBuild() throws {
    let base = dataset(SyntheticCase(seed: 7, months: 6))
    let ledger = Ledger(dataset: base, calendar: Synthetic.calendar)

    // An operation I rated by hand feeds the history every unrated operation is rated by.
    var rated = try plain(in: base, skipping: 2)
    rated.parts[0].quality = .bad
    rated.parts[0].qualitySource = .manual
    rated.transaction.updatedAt = Date(timeIntervalSince1970: 1_900_000_000)
    let byHand = base.upserting([rated])
    #expect(ledger.delta(to: byHand) == nil)
    expectSame(ledger.updated(to: byHand), Ledger(dataset: byHand, calendar: Synthetic.calendar))

    // A refund of a purchase.
    let purchase = try plain(in: base, skipping: 4)
    var refund = copy(of: purchase, at: purchase.transaction.occurredAt.addingTimeInterval(86_400), number: 900)
    refund.transaction.kind = .refund
    refund.parts[0].refundOfPartId = purchase.parts[0].id
    let refunded = base.upserting([refund])
    #expect(ledger.delta(to: refunded) == nil)
    expectSame(ledger.updated(to: refunded), Ledger(dataset: refunded, calendar: Synthetic.calendar))

    // The purchase a refund takes back from, once it is edited.
    let refundedLedger = ledger.updated(to: refunded)
    var changed = purchase
    changed.parts[0].amountRubE4 = changed.parts[0].amountRubE4 + AmountE4(raw: 10_000)
    let reedited = refunded.upserting([changed])
    #expect(refundedLedger.delta(to: reedited) == nil)
    expectSame(
      refundedLedger.updated(to: reedited), Ledger(dataset: reedited, calendar: Synthetic.calendar))

    // The operation of the first day goes: the first day of the ledger has to be found again.
    let oldest = try #require(base.entries.min { $0.transaction.occurredAt < $1.transaction.occurredAt })
    let withoutFirst = base.removing([oldest.id])
    #expect(ledger.delta(to: withoutFirst) == nil)
    expectSame(
      ledger.updated(to: withoutFirst), Ledger(dataset: withoutFirst, calendar: Synthetic.calendar))

    // A category renamed: every row's search key changes.
    var renamed = base
    renamed.categories[0].name += " renamed"
    #expect(ledger.delta(to: renamed) == nil)
    expectSame(ledger.updated(to: renamed), Ledger(dataset: renamed, calendar: Synthetic.calendar))
  }

  @Test func nothingChangedKeepsTheLedger() throws {
    let base = dataset(SyntheticCase(seed: 7, months: 6))
    let ledger = Ledger(dataset: base, calendar: Synthetic.calendar)
    let same = base.upserting([])
    expectSame(try #require(ledger.delta(to: same)), ledger)
  }
}

/// A small deterministic generator, so a failing chain of writes can be replayed.
private struct SystemRandomNumberGeneratorFree: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state >> 11
  }
}
