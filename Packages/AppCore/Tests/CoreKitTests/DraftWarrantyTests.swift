import Foundation
import Testing

@testable import CoreKit

/// The warranty, the place of the original and the return term belong to the operation: an edit
/// that rebuilds it from the draft keeps them, and the panel can change them.
@Suite("The warranty and return terms in drafts")
struct DraftWarrantyTests {
  private let until = DateOnly(year: 2028, month: 10, day: 29)
  private let returnDay = DateOnly(year: 2026, month: 11, day: 12)

  private func bought() throws -> TransactionEntry {
    var draft = TransactionDraft(
      amount: AmountE4(whole: 5_000), note: "kettle", warrantyUntil: until,
      warrantyWhere: "  folder «Appliances»  ", returnUntil: returnDay)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  @Test func aDraftStartsWithNoTerms() throws {
    let draft = TransactionDraft()
    #expect(draft.warrantyUntil == nil && draft.warrantyWhere == nil && draft.returnUntil == nil)
  }

  @Test func theTermsGoIntoTheOperationAndTheTextIsTrimmed() throws {
    let transaction = try bought().transaction
    #expect(transaction.warrantyUntil == until)
    #expect(transaction.warrantyWhere == "folder «Appliances»")
    #expect(transaction.returnUntil == returnDay)
  }

  @Test func blankPlaceReadsAsNone() throws {
    var draft = TransactionDraft(amount: AmountE4(whole: 1), warrantyWhere: "   ")
    draft.normalizeSinglePart()
    #expect(try draft.materialize().transaction.warrantyWhere == nil)
  }

  @Test func reopeningAndEditingSomethingElseKeepsThem() throws {
    let saved = try bought()
    var draft = TransactionDraft(entry: saved)
    #expect(draft.warrantyUntil == until && draft.returnUntil == returnDay)
    draft.note = "kettle, red"
    let edited = try draft.materialize(updating: saved).transaction
    #expect(edited.note == "kettle, red")
    #expect(edited.warrantyUntil == until)
    #expect(edited.warrantyWhere == "folder «Appliances»")
    #expect(edited.returnUntil == returnDay)
  }

  @Test func theTermsCanBeChangedAndRemovedByAnEdit() throws {
    let saved = try bought()
    var draft = TransactionDraft(entry: saved)
    draft.warrantyUntil = nil
    draft.returnUntil = DateOnly(year: 2026, month: 12, day: 1)
    let edited = try draft.materialize(updating: saved).transaction
    #expect(edited.warrantyUntil == nil)
    #expect(edited.returnUntil == DateOnly(year: 2026, month: 12, day: 1))
  }
}
