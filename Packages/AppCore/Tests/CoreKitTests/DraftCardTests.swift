import Foundation
import Testing

@testable import CoreKit

/// The card and the cashback of an operation are fields of the ↓ panel: a draft carries them
/// into the operation it makes, and an edit through the panel, which rebuilds the operation from
/// the draft, keeps what it was opened with.
@Suite("Drafts carry the card and the cashback")
struct DraftCardTests {
  private let card = UUID()
  private let account = UUID()
  private let at = Date(timeIntervalSince1970: 1_790_000_000)
  private let cashback = Money(amount: AmountE4(whole: 45), currency: .rub)

  @Test func aNewDraftCarriesThem() throws {
    var draft = TransactionDraft(
      occurredAt: at, amount: AmountE4(whole: 350), paymentMethodId: account, cardId: card,
      cashback: cashback)
    draft.normalizeSinglePart()
    let entry = try draft.materialize(now: at)
    #expect(entry.transaction.cardId == card)
    #expect(entry.transaction.cashback == cashback)
    #expect(entry.transaction.paymentMethodId == account)
  }

  @Test func aDraftWithoutThemMakesAnOperationWithoutThem() throws {
    var draft = TransactionDraft(occurredAt: at, amount: AmountE4(whole: 350))
    draft.normalizeSinglePart()
    let entry = try draft.materialize(now: at)
    #expect(entry.transaction.cardId == nil)
    #expect(entry.transaction.cashback == nil)
  }

  @Test func anEditKeepsTheCardAndTheCashback() throws {
    var original = TransactionDraft(
      occurredAt: at, amount: AmountE4(whole: 350), paymentMethodId: account, cardId: card,
      cashback: cashback)
    original.normalizeSinglePart()
    let saved = try original.materialize(now: at)

    var reopened = TransactionDraft(entry: saved)
    #expect(reopened.cardId == card)
    #expect(reopened.cashback == cashback)
    reopened.note = "coffee"
    let edited = try reopened.materialize(updating: saved, now: at.addingTimeInterval(60))
    #expect(edited.transaction.cardId == card)
    #expect(edited.transaction.cashback == cashback)
    #expect(edited.transaction.note == "coffee")
  }

  /// They are the panel's: an edit that clears them clears them.
  @Test func anEditThatClearsThemClearsThem() throws {
    var original = TransactionDraft(
      occurredAt: at, amount: AmountE4(whole: 350), paymentMethodId: account, cardId: card,
      cashback: cashback)
    original.normalizeSinglePart()
    let saved = try original.materialize(now: at)
    var reopened = TransactionDraft(entry: saved)
    reopened.cardId = nil
    reopened.cashback = nil
    let edited = try reopened.materialize(updating: saved, now: at.addingTimeInterval(60))
    #expect(edited.transaction.cardId == nil)
    #expect(edited.transaction.cashback == nil)
  }
}
