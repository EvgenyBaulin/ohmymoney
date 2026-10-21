import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The order of the blocks of Planning and how many of the nearest items a long block shows.
@Suite("The layout of the Planning screen")
struct PlanningLayoutTests {
  // MARK: - The order of the blocks

  @Test func nothingStoredIsTheStandardOrder() {
    #expect(PlanningBlocks.decode(nil) == PlanningBlocks.standard)
    #expect(PlanningBlocks.decode("") == PlanningBlocks.standard)
    #expect(PlanningBlocks.decode(" , ,") == PlanningBlocks.standard)
  }

  /// A block this build does not know goes; a block named twice keeps its first place; a block
  /// the text does not name — one a later build added — comes at the end in its standard place.
  @Test func anyStoredTextReadsAsEveryBlockOnce() {
    let read = PlanningBlocks.decode("goals, banana,payments,goals,advice")
    #expect(Array(read.prefix(3)) == [.goals, .payments, .advice])
    #expect(
      read == [
        .goals, .payments, .advice, .freeMoney, .subscriptions, .expectedIncome,
        .limits, .events, .selfEmployment,
      ])
    #expect(Set(read) == Set(PlanningBlock.allCases))
    #expect(read.count == PlanningBlock.allCases.count)
  }

  @Test func encodeAndDecodeRoundTrip() {
    let order: [PlanningBlock] = [
      .advice, .events, .goals, .limits, .expectedIncome,
      .subscriptions, .payments, .freeMoney, .selfEmployment,
    ]
    #expect(
      PlanningBlocks.encode(order) == "advice,events,goals,limits,expectedIncome,"
        + "subscriptions,payments,freeMoney,selfEmployment")
    #expect(PlanningBlocks.decode(PlanningBlocks.encode(order)) == order)
    // An order missing blocks is written whole.
    #expect(PlanningBlocks.decode(PlanningBlocks.encode([.goals])).first == .goals)
    #expect(PlanningBlocks.decode(PlanningBlocks.encode([.goals])).count == 9)
  }

  /// The raw values are what the setting and the archive keep: renaming one would lose the order.
  @Test func theRawValuesStay() {
    #expect(
      PlanningBlock.allCases.map(\.rawValue) == [
        "freeMoney", "payments", "subscriptions", "expectedIncome", "limits", "goals", "events",
        "advice", "selfEmployment",
      ])
  }

  /// Dragged down, a block lands after the target; dragged up, before it; onto itself, nothing.
  @Test func aDroppedBlockTakesThePlaceOfTheTarget() {
    let order = PlanningBlocks.standard
    let down = PlanningBlocks.dropping(.freeMoney, onto: .expectedIncome, in: order)
    #expect(Array(down.prefix(4)) == [.payments, .subscriptions, .expectedIncome, .freeMoney])
    let up = PlanningBlocks.dropping(.advice, onto: .payments, in: order)
    #expect(Array(up.prefix(3)) == [.freeMoney, .advice, .payments])
    #expect(PlanningBlocks.dropping(.limits, onto: .limits, in: order) == order)
    #expect(Set(down) == Set(order))
  }

  @Test func upAndDownStopAtTheEdges() {
    let order = PlanningBlocks.standard
    #expect(PlanningBlocks.moving(.payments, by: -1, in: order).first == .payments)
    #expect(PlanningBlocks.moving(.freeMoney, by: -1, in: order) == order)
    #expect(PlanningBlocks.moving(.selfEmployment, by: 1, in: order) == order)
    #expect(!PlanningBlocks.canMove(.freeMoney, by: -1, in: order))
    #expect(PlanningBlocks.canMove(.freeMoney, by: 1, in: order))
    #expect(!PlanningBlocks.canMove(.selfEmployment, by: 1, in: order))
    #expect(PlanningBlocks.isStandard(order))
    #expect(!PlanningBlocks.isStandard(PlanningBlocks.moving(.limits, by: 1, in: order)))
  }

  /// Two columns take the blocks in turn, so the first two blocks head the two columns.
  @Test func theColumnsTakeTheBlocksInTurn() {
    let order = PlanningBlocks.standard
    #expect(PlanningBlocks.columns(order, count: 1) == [order])
    let two = PlanningBlocks.columns(order, count: 2)
    #expect(two[0] == [.freeMoney, .subscriptions, .limits, .events, .selfEmployment])
    #expect(two[1] == [.payments, .expectedIncome, .goals, .advice])
    #expect(PlanningBlocks.columns(order, count: 0) == [order])
  }

  // MARK: - How many items a block shows

  @Test func theLengthIsReadFromWhatTheSettingsOffer() {
    #expect(PlanningListLength(stored: "3") == .count(3))
    #expect(PlanningListLength(stored: "10") == .count(10))
    #expect(PlanningListLength(stored: "all") == .all)
    #expect(PlanningListLength(stored: nil) == nil)
    #expect(PlanningListLength(stored: "7") == nil)
    #expect(PlanningListLength(stored: "-3") == nil)
    #expect(PlanningListLength(stored: "lots") == nil)
    for choice in PlanningListLength.choices {
      #expect(PlanningListLength(stored: choice.stored) == choice)
    }
    #expect(PlanningListLength.standard == .count(5))
  }

  /// A block's own choice wins over the one of all blocks; without one, the block follows it.
  @Test func aBlocksOwnLengthBeatsTheSetting() {
    #expect(PlanningListLength.effective(own: .count(3), global: .count(10)) == .count(3))
    #expect(PlanningListLength.effective(own: .all, global: .count(3)) == .all)
    #expect(PlanningListLength.effective(own: nil, global: .count(10)) == .count(10))
  }

  /// Five of twelve show, seven wait behind «Показать все (12)»; opened out, all twelve; a list
  /// no longer than the limit has no button; «все» shows everything.
  @Test func theNearestFewAndTheRestBehindTheButton() {
    #expect(PlanningShortList.split(total: 12, length: .count(5), expanded: false) == (5, 7))
    #expect(PlanningShortList.split(total: 12, length: .count(5), expanded: true) == (12, 0))
    #expect(PlanningShortList.split(total: 5, length: .count(5), expanded: false) == (5, 0))
    #expect(PlanningShortList.split(total: 4, length: .count(3), expanded: false) == (3, 1))
    #expect(PlanningShortList.split(total: 40, length: .all, expanded: false) == (40, 0))
    #expect(PlanningShortList.split(total: 0, length: .count(3), expanded: false) == (0, 0))
  }

  /// Nearest by the date of each item in its own block; undated after every dated one; one
  /// date keeps the order it came in.
  @Test func nearestFirstByTheDateOfTheBlock() {
    let day = { (number: Int) in DateOnly(year: 2026, month: 10, day: number) }
    let items: [(String, DateOnly?)] = [
      ("rent", day(25)), ("phone", day(3)), ("none", nil), ("gym", day(3)), ("tv", day(12)),
    ]
    let sorted = PlanningShortList.nearestFirst(items) { $0.1 }.map(\.0)
    #expect(sorted == ["phone", "gym", "tv", "rent", "none"])
  }
}
