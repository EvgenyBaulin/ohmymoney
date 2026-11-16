import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// Random smaller operations around the due dates of a payment, checked against what a part
/// promises: what is paid plus what is left is the price, the question about closing the rest
/// is asked only close to the price, a closed due takes nothing more, and an operation is
/// never a part of two due dates.
@Suite("Scheduled payments paid in parts: random books")
struct ScheduledPartsPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...25)

  static let rent = Fx.payment(1, "Rent", "60000", day: 15, next: "2026-09-15")
  static let due = Fx.day("2026-09-15")

  struct Book {
    var fx = CashFx()
    var parts: [(id: UUID, amount: AmountE4)] = []
    var answer: ScheduledPartAnswer?
    var stored: Set<String> = []

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      fx.scheduled = [ScheduledPartsPropertyTests.rent]
      // Half the books land the parts between 90 % and the price, where an answer is asked.
      let inRange = random.chance(1, outOf: 2)
      let pieces = random.int(in: 2...5)
      let total = Int64(random.int(in: 54_000...59_900))
      let shares = AmountE4(whole: total).split(into: pieces)
      for index in 0..<(inRange ? pieces : random.int(in: 1...5)) {
        // Between 5 % and 50 % of the price: always a part, never a whole payment.
        let amount =
          inRange ? shares[index] : AmountE4(whole: Int64(random.int(in: 3_000...30_000)))
        let day = random.int(in: 10...18)
        let id = fx.add(
          .expense, amount.decimal.description,
          at: Fx.at("2026-09-\(day)", random.int(in: 0...23), random.int(in: 0...59)),
          category: random.chance(1, outOf: 2) ? Fx.rent : Fx.housing)
        parts.append((id, amount))
      }
      // An answer exists only once the parts have come within reach of the price.
      let asked = ScheduledMatching.matches(
        book: fx.book, ledger: fx.ledger, today: Fx.today, rejections: []
      ).parts(ScheduledPartsPropertyTests.rent.id, ScheduledPartsPropertyTests.due)
      if asked?.needsCloseDecision == true {
        answer = [ScheduledPartAnswer.close, .keep, nil][random.int(in: 0...2)]
      }
      if let answer {
        stored = ScheduledMatching.partAnswers(
          adding: answer, payment: ScheduledPartsPropertyTests.rent.id,
          due: ScheduledPartsPropertyTests.due, to: [], today: Fx.today)
      }
    }

    func matches(extra: [UUID] = []) -> ScheduledMatches {
      ScheduledMatching.matches(
        book: fx.book, ledger: fx.ledger, today: Fx.today, rejections: stored)
    }

    func amount(of id: UUID) -> AmountE4? {
      fx.entries.first { $0.id == id }?.transaction.amountE4
    }
  }

  @Test(arguments: seeds)
  func whatIsPaidPlusWhatIsLeftIsThePrice(_ seed: UInt64) {
    let book = Book(seed: seed)
    let found = book.matches()
    let price = Self.rent.amountE4
    guard let parts = found.parts(Self.rent.id, Self.due) else { return }
    var sum = AmountE4.zero
    for id in parts.operations { sum += book.amount(of: id) ?? .zero }
    #expect(parts.paidE4 == sum, "seed \(seed)")
    #expect(parts.priceE4 == price)
    if parts.paidE4 < price {
      #expect(parts.paidE4 + parts.remainingE4 == price, "seed \(seed)")
    } else {
      #expect(parts.remainingE4 == .zero, "seed \(seed)")
    }
    let unpaid = found.unpaid(Self.rent.id, Self.due, price: price)
    #expect(unpaid == (found.isPaid(Self.rent.id, Self.due) ? .zero : parts.remainingE4))
    #expect(
      found.isPaid(Self.rent.id, Self.due) == (parts.paidE4 >= price || parts.answer == .close))
  }

  @Test(arguments: seeds)
  func theQuestionComesOnlyBetweenNinetyPercentAndThePrice(_ seed: UInt64) {
    let book = Book(seed: seed)
    let found = book.matches()
    let price = Self.rent.amountE4
    #expect(ScheduledMatching.tolerance(of: price) == AmountE4(whole: 6_000))
    guard let parts = found.parts(Self.rent.id, Self.due) else { return }
    let inRange = parts.paidE4 < price && Decimal(parts.paidE4.raw) * 10 >= Decimal(price.raw) * 9
    #expect(parts.needsCloseDecision == (parts.answer == nil && inRange), "seed \(seed)")
    #expect(parts.answer == book.answer, "seed \(seed)")
  }

  /// The parts are taken oldest first until the due is paid; no shorter run of them already
  /// paid it.
  @Test(arguments: seeds)
  func noPartIsTakenAfterTheDueIsClosed(_ seed: UInt64) {
    let book = Book(seed: seed)
    let found = book.matches()
    let price = Self.rent.amountE4
    let tolerance = ScheduledMatching.tolerance(of: price)
    guard let parts = found.parts(Self.rent.id, Self.due) else { return }
    var prefix = AmountE4.zero
    for id in parts.operations.dropLast() {
      prefix += book.amount(of: id) ?? .zero
      let closedByAnswer = book.answer == .close && prefix >= price - tolerance
      #expect(prefix < price && !closedByAnswer, "seed \(seed): closed before the last part")
    }

    // A later small operation joins an open due and is left alone by a closed one.
    var more = book
    let late = more.fx.add(
      .expense, "1000", at: Fx.at("2026-09-19", 10), category: Fx.housing)
    let after = more.matches().parts(Self.rent.id, Self.due)
    if found.isPaid(Self.rent.id, Self.due) {
      #expect(after?.operations == parts.operations, "seed \(seed)")
      #expect(after?.operations.contains(late) == false, "seed \(seed)")
    }
  }

  /// Two payments of one category, one of them weekly: every operation is a part of one due
  /// date at most, and the parts of a due date are the operations that add up to what it shows.
  @Test(arguments: seeds)
  func anOperationIsNeverAPartOfTwoDues(_ seed: UInt64) {
    var random = SeededRandom(seed: seed &* 31)
    var fx = CashFx()
    let weekly = Fx.payment(2, "Gym", "5000", day: 1, next: "2026-08-24")
    var weeklyRule = weekly
    weeklyRule.freq = .weekly
    weeklyRule.day = weeklyRule.nextDate?.weekday ?? 1
    fx.scheduled = [Self.rent, weeklyRule]
    var amounts: [UUID: AmountE4] = [:]
    for _ in 0..<random.int(in: 3...12) {
      let amount = AmountE4(whole: Int64(random.int(in: 200...30_000)))
      let id = fx.add(
        .expense, amount.decimal.description,
        at: Fx.at("2026-09-\(random.int(in: 1...19))", random.int(in: 0...23)),
        category: Fx.housing)
      amounts[id] = amount
    }
    let found = ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: Fx.today, rejections: [])
    var seen: [UUID] = []
    for payment in fx.scheduled {
      for (due, part) in found.partDues(of: payment.id) {
        seen += part.operations
        let sum = part.operations.reduce(AmountE4.zero) { $0 + (amounts[$1] ?? .zero) }
        #expect(part.paidE4 == sum, "seed \(seed), \(payment.name) \(due)")
      }
      seen += Array(found.matchedDues(of: payment.id).values)
    }
    #expect(Set(seen).count == seen.count, "seed \(seed): an operation counted twice")
  }

  /// The random books are not idle: they reach every answer, an open question and a closed due.
  @Test func theRandomBooksReachEveryCase() {
    var answers: Set<String> = []
    var asking = 0
    var closed = 0
    var open = 0
    for seed in Self.seeds {
      let book = Book(seed: seed)
      let found = book.matches()
      answers.insert(book.answer?.rawValue ?? "none")
      guard let parts = found.parts(Self.rent.id, Self.due) else { continue }
      if parts.needsCloseDecision { asking += 1 }
      if found.isPaid(Self.rent.id, Self.due) { closed += 1 } else { open += 1 }
    }
    #expect(answers == ["close", "keep", "none"])
    #expect(asking > 0 && closed > 0 && open > 0)
  }
}
