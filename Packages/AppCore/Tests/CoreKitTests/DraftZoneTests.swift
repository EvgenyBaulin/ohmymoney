import Foundation
import Testing

@testable import CoreKit

/// A new operation records the zone of the Mac it was written on (Moscow as nothing, so a home
/// database stays as it was); an edit that leaves the moment alone leaves the zone, one that
/// moves the moment is a date typed on this Mac.
@Suite("Drafts record the zone of the Mac")
struct DraftZoneTests {
  private let at = Date(timeIntervalSince1970: 1_790_000_000)
  private let bali = TimeZone(identifier: "Asia/Makassar")!

  private func draft(at moment: Date) -> TransactionDraft {
    var draft = TransactionDraft(occurredAt: moment, amount: AmountE4(whole: 350))
    draft.normalizeSinglePart()
    return draft
  }

  @Test func aNewOperationRecordsTheZoneOfTheMac() throws {
    let entry = try draft(at: at).materialize(now: at, timeZone: bali)
    #expect(entry.transaction.timeZoneId == "Asia/Makassar")
  }

  @Test func aMacInMoscowRecordsNothing() throws {
    let entry = try draft(at: at).materialize(now: at, timeZone: TravelDay.moscowZone)
    #expect(entry.transaction.timeZoneId == nil)
  }

  @Test func anEditThatLeavesTheMomentLeavesTheZone() throws {
    let saved = try draft(at: at).materialize(now: at, timeZone: bali)
    var edited = draft(at: at)
    edited.note = "ужин"
    let updated = try edited.materialize(
      updating: saved, now: at, timeZone: TravelDay.moscowZone)
    #expect(updated.transaction.timeZoneId == "Asia/Makassar", "the Mac is home, the record is not")
    #expect(updated.transaction.note == "ужин")
  }

  @Test func anEditThatMovesTheMomentIsADateTypedOnThisMac() throws {
    let saved = try draft(at: at).materialize(now: at, timeZone: bali)
    let moved = try draft(at: at.addingTimeInterval(86_400)).materialize(
      updating: saved, now: at, timeZone: TravelDay.moscowZone)
    #expect(moved.transaction.timeZoneId == nil)
  }
}
