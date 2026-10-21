import Foundation
import Testing

@testable import CoreKit

/// The order of the fields of the ↓ panel as the settings keep it: a line of raw values that
/// reads back as the same order, and a line from anywhere else — another build, an archive of
/// another Mac, a hand edit — that always reads as a whole order of every field, once each.
@Suite("The order of the fields of the ↓ panel")
struct EntryFieldOrderTests {
  /// The fourteen fields in the order the panel had before the order could be chosen, with the
  /// cashback after the account: nothing moves for an owner who never opens the setting.
  @Test func standardIsTheOrderOfOneOne() {
    let expected: [EntryField] = [
      .amount, .category, .quality, .forWhom, .place, .event, .account, .cashback, .goal, .debt,
      .note, .date, .incomeMonth, .currency,
    ]
    #expect(EntryFieldOrder.standard == expected)
    #expect(EntryField.allCases == expected)
    #expect(
      EntryField.allCases.map(\.rawValue) == [
        "amount", "category", "quality", "forWhom", "place", "event", "account", "cashback",
        "goal", "debt", "note", "date", "incomeMonth", "currency",
      ])
  }

  /// Every order written reads back as itself.
  @Test func encodeDecodeRoundTrip() {
    let reversed = Array(EntryFieldOrder.standard.reversed())
    #expect(EntryFieldOrder.decode(EntryFieldOrder.encode(reversed)) == reversed)
    #expect(
      EntryFieldOrder.decode(EntryFieldOrder.encode(EntryFieldOrder.standard))
        == EntryFieldOrder.standard)
    #expect(
      EntryFieldOrder.encode(EntryFieldOrder.standard)
        == "amount,category,quality,forWhom,place,event,account,cashback,goal,debt,note,date,"
        + "incomeMonth,currency")
  }

  /// A word no build knows and a field named twice go; the first place of a field wins.
  @Test func unknownAndRepeatedTokensAreDropped() {
    let order = EntryFieldOrder.decode("note,bogus,amount,note,,category, amount")
    #expect(Array(order.prefix(1)) == [.note])
    #expect(order.count == EntryField.allCases.count)
    #expect(Set(order) == Set(EntryField.allCases))
    #expect(order.firstIndex(of: .note) == 0)
    #expect(order.firstIndex(of: .amount)! < order.firstIndex(of: .category)!)
  }

  /// A line of a build that knew three fields, and a word of none: the missing ones take the
  /// place right after the nearest field that stands before them in the standard order.
  @Test func missingFieldsLandAfterTheirStandardNeighbour() {
    #expect(
      EntryFieldOrder.decode("note,amount,foo,category,amount") == [
        .note, .date, .incomeMonth, .currency, .amount, .category, .quality, .forWhom, .place,
        .event, .account, .cashback, .goal, .debt,
      ])
    // A field with no standard neighbour before it present goes first.
    #expect(
      EntryFieldOrder.sanitized([.currency, .category]) == [
        .amount, .currency, .category, .quality, .forWhom, .place, .event, .account, .cashback,
        .goal, .debt, .note, .date, .incomeMonth,
      ])
  }

  /// Nothing, an empty line and a line of words no build knows are the standard order.
  @Test(arguments: [nil, "", "foo,bar", ",,,", "AMOUNT,Category"] as [String?])
  func emptyOrGarbageIsStandard(_ stored: String?) {
    #expect(EntryFieldOrder.decode(stored) == EntryFieldOrder.standard)
  }

  /// The moves of a list dragged in the settings, as `List.onMove` gives them: the destination
  /// is counted before the moved rows leave.
  @Test func movingFollowsOnMove() {
    let standard = EntryFieldOrder.standard
    let noteFirst = EntryFieldOrder.moving(standard, from: IndexSet(integer: 10), to: 0)
    #expect(noteFirst.first == .note)
    #expect(Array(noteFirst.dropFirst()) == standard.filter { $0 != .note })

    let amountLast = EntryFieldOrder.moving(standard, from: IndexSet(integer: 0), to: 14)
    #expect(amountLast.last == .amount)
    #expect(Array(amountLast.dropLast()) == Array(standard.dropFirst()))

    #expect(EntryFieldOrder.moving(standard, from: IndexSet(integer: 3), to: 3) == standard)
    #expect(EntryFieldOrder.moving(standard, from: IndexSet(integer: 3), to: 4) == standard)

    let two = EntryFieldOrder.moving(standard, from: IndexSet([0, 1]), to: 3)
    #expect(Array(two.prefix(3)) == [.quality, .amount, .category])

    // An index out of the list moves nothing and loses nothing.
    #expect(EntryFieldOrder.moving(standard, from: IndexSet(integer: 40), to: 0) == standard)
    #expect(Set(EntryFieldOrder.moving(standard, from: IndexSet(integer: 2), to: 99)).count == 14)
  }

  /// «Сбросить» brings the standard order back, and only the standard order is standard.
  @Test func isStandardAfterReset() {
    #expect(EntryFieldOrder.isStandard(EntryFieldOrder.standard))
    let moved = EntryFieldOrder.moving(
      EntryFieldOrder.standard, from: IndexSet(integer: 10), to: 0)
    #expect(!EntryFieldOrder.isStandard(moved))
    #expect(EntryFieldOrder.isStandard(EntryFieldOrder.decode(nil)))
    #expect(!EntryFieldOrder.isStandard([.amount]))
  }
}
