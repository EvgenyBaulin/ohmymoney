import Foundation
import Testing

@testable import CoreKit

/// The panel edits the one-off mark («Разовое»): an edit rebuilds the operation from the draft,
/// so the draft has to carry the mark both ways or an edit would take it off.
@Suite("The one-off mark in drafts")
struct DraftOneOffTests {
  private func savedEntry(oneOff: Bool) throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: 300), note: "cinema", isOneOff: oneOff)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  @Test func aDraftDefaultsToNotOneOff() throws {
    #expect(!TransactionDraft().isOneOff)
    #expect(try savedEntry(oneOff: false).transaction.isOneOff == false)
  }

  @Test func theMarkGoesIntoTheOperationItMakes() throws {
    #expect(try savedEntry(oneOff: true).transaction.isOneOff)
  }

  @Test func reopeningAMarkedOperationKeepsTheMark() throws {
    let marked = try savedEntry(oneOff: true)
    #expect(TransactionDraft(entry: marked).isOneOff)
    #expect(!TransactionDraft(entry: try savedEntry(oneOff: false)).isOneOff)
  }

  @Test func anEditThatLeavesTheMarkAloneKeepsIt() throws {
    let marked = try savedEntry(oneOff: true)
    var draft = TransactionDraft(entry: marked)
    draft.note = "cinema with friends"
    let edited = try draft.materialize(updating: marked)
    #expect(edited.transaction.isOneOff, "an edit of the note must not take the mark off")
    #expect(edited.transaction.note == "cinema with friends")
  }

  @Test func theMarkCanBeTakenOffAndPutOnByAnEdit() throws {
    let marked = try savedEntry(oneOff: true)
    var draft = TransactionDraft(entry: marked)
    draft.isOneOff = false
    #expect(try draft.materialize(updating: marked).transaction.isOneOff == false)

    let plain = try savedEntry(oneOff: false)
    var other = TransactionDraft(entry: plain)
    other.isOneOff = true
    #expect(try other.materialize(updating: plain).transaction.isOneOff)
    #expect(other != TransactionDraft(entry: plain), "an unsaved mark is a change of the draft")
  }
}
