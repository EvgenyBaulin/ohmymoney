import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// What the snapshot of the numbers reads of the cards, their cashback rules and the deleted
/// debts.
@Suite("The dataset reads the cards, the rules and the deleted debts")
struct DatasetTwelveTests {
  /// The cards in the owner's order — the order dragged, then by name —, archived ones too;
  /// the rules in the order they were made.
  @Test func cardsAndRulesAreLoaded() async throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let account = references.paymentMethod.id
    let cards = [
      PaymentCard(accountId: account, name: "Zeta", sort: 0),
      PaymentCard(accountId: account, name: "Alpha", sort: 0, archived: true),
      PaymentCard(accountId: account, name: "Beta", sort: 2),
    ]
    let rules = [
      CashbackRule(
        accountId: account, cardId: cards[2].id, categoryId: references.category.id,
        percent: CashbackPercent(e4: 50_000) ?? .zero),
      CashbackRule(accountId: account, cardId: cards[0].id, percent: .zero),
      CashbackRule(
        accountId: account, cardId: cards[0].id, month: MonthKey(year: 2026, month: 9),
        percent: CashbackPercent(e4: 15_000) ?? .zero),
    ]
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(cards: cards, cashbackRules: rules)))

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 3)
    #expect(dataset.cards.map(\.name) == ["Alpha", "Zeta", "Beta"])
    #expect(dataset.cards.first { $0.name == "Alpha" }?.archived == true)
    #expect(dataset.cashbackRules == rules)
    #expect(dataset.version == 3)
  }

  /// A deleted debt leaves `debts` — every list and figure of the debts reads that — and is
  /// kept apart, where the operations that point at it still find it.
  @Test func aDeletedDebtIsApartButFound() async throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    var deleted = references.debt
    deleted.deletedAt = Date(timeIntervalSince1970: 1_789_900_000)
    try ReferenceRepository(writer: stack.writer).save(deleted)

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    #expect(dataset.debts.map(\.id) == [references.creditDebt.id])
    #expect(dataset.deletedDebts == [deleted])
    #expect(dataset.debtsById[deleted.id] == deleted)
    #expect(dataset.debtsById[references.creditDebt.id] != nil)
  }

  /// The pickers, the vocabulary of the entry line and the money-back sheet read the debts
  /// through the repository: a deleted one is not there unless asked for.
  @Test func debtsReaderLeavesDeletedOut() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = ReferenceRepository(writer: stack.writer)
    var deleted = references.debt
    deleted.deletedAt = Date(timeIntervalSince1970: 1_789_900_000)
    try repository.save(deleted)
    var closed = references.creditDebt
    closed.closed = true
    try repository.save(closed)

    #expect(try repository.debts().isEmpty)
    #expect(try repository.debts(includeClosed: true).map(\.id) == [closed.id])
    #expect(
      Set(try repository.debts(includeClosed: true, includeDeleted: true).map(\.id))
        == [closed.id, deleted.id])
    #expect(try repository.debts(includeDeleted: true).map(\.id) == [deleted.id])
    let vocabulary = try repository.vocabulary(enabledCurrencies: [.rub])
    #expect(vocabulary.debts.isEmpty)
  }
}
