import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The operation that records the difference of a count, and its one part, have ids derived
/// from the count: every creation names the same rows.
@Suite("The ids of a count's difference operation")
struct ReconcileDifferenceIdsTests {
  @Test func theVectors() throws {
    let count = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    #expect(
      ReconcileDifferenceIds.operation(forCount: count).uuidString
        == "6374727E-4C41-5A5F-2120-3C33333A2574")
    #expect(
      ReconcileDifferenceIds.part(forCount: count).uuidString
        == "6374727E-4C41-5A5F-2120-3C3333252721")
    #expect(ReconcileDifferenceIds.operationMask == Array("reconcilediffop!".utf8))
    #expect(ReconcileDifferenceIds.partMask == Array("reconcilediffprt".utf8))
  }

  @Test func theSameCountAlwaysGivesTheSameIds() {
    let count = UUID()
    #expect(
      ReconcileDifferenceIds.operation(forCount: count)
        == ReconcileDifferenceIds.operation(forCount: count))
    #expect(
      ReconcileDifferenceIds.part(forCount: count) == ReconcileDifferenceIds.part(forCount: count))
  }

  /// On 500 random counts: never the count's own id, never each other, never the card the
  /// update would make of the same bytes, and applied twice the mask gives the count back.
  @Test func fiveHundredRandomCounts() {
    var operations: Set<UUID> = []
    var parts: Set<UUID> = []
    for _ in 0..<500 {
      let count = UUID()
      let operation = ReconcileDifferenceIds.operation(forCount: count)
      let part = ReconcileDifferenceIds.part(forCount: count)
      #expect(operation != count)
      #expect(part != count)
      #expect(operation != part)
      #expect(operation != CardsMigration.cardId(forAccount: count))
      #expect(part != CardsMigration.cardId(forAccount: count))
      #expect(ReconcileDifferenceIds.operation(forCount: operation) == count)
      #expect(ReconcileDifferenceIds.part(forCount: part) == count)
      operations.insert(operation)
      parts.insert(part)
    }
    #expect(operations.count == 500)
    #expect(parts.count == 500)
    #expect(operations.isDisjoint(with: parts))
  }
}
