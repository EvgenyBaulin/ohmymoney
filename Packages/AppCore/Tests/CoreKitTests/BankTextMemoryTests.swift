import Foundation
import Testing

@testable import CoreKit

@Suite("The memory of the bank's texts the owner has written")
struct BankTextMemoryTests {
  private let account = UUID()
  private let bank = UUID()
  private let place = UUID()

  private var scope: BankTextMemory.Scope { .init(accountId: account, bankId: bank) }

  @Test func textKeyFoldsCaseYoAndPunctuation() {
    #expect(BankTextMemory.textKey("SAMPLE CAFE") == BankTextMemory.textKey("Sample-Cafe"))
    #expect(BankTextMemory.textKey("Пятёрочка") == BankTextMemory.textKey("ПЯТЕРОЧКА"))
    #expect(BankTextMemory.textKey(" — ") == nil)
  }

  @Test func storedFormRoundTripsAndIsStable() throws {
    var memory = BankTextMemory()
    memory.learn(
      scope: scope, kind: .expense, text: "SAMPLE CAFE",
      fill: BankTextFill(placeId: place, note: "Кофе", forWhom: .partner), operation: UUID())
    let text = try #require(memory.encoded())
    #expect(text == BankTextMemory.decoded(text).encoded())
    #expect(BankTextMemory.decoded(text) == memory)
    #expect(text.contains("samplecafe"))
    #expect(!text.contains("SAMPLE CAFE"))
    #expect(BankTextMemory.decoded(nil).isEmpty)
    #expect(BankTextMemory.decoded("not json").isEmpty)
    // A later build's memory is left alone rather than misread.
    let later = text.replacingOccurrences(of: #""version":1"#, with: #""version":99"#)
    #expect(BankTextMemory.decoded(later).isEmpty)
  }

  @Test func emptyFillOrTextTeachesNothing() {
    var memory = BankTextMemory()
    let taught1 = memory.learn(scope: scope, kind: .expense, text: "CAFE", fill: BankTextFill())
    #expect(!taught1)
    let taught2 = memory.learn(scope: scope, kind: .expense, text: "CAFE", fill: BankTextFill(forWhom: .me))
    #expect(!taught2)
    let taught3 = memory.learn(scope: scope, kind: .expense, text: "***", fill: .init(note: "x"))
    #expect(!taught3)
    let taught4 = memory.learn(scope: scope, kind: .expense, text: "CAFE", fill: .init(note: "  "))
    #expect(!taught4)
    #expect(memory.isEmpty)
  }

  @Test func latestWordWinsAndTheSameWordChangesNothing() {
    var memory = BankTextMemory()
    let taught5 = memory.learn(scope: scope, kind: .expense, text: "CAFE", fill: .init(note: "Кофе"))
    #expect(taught5)
    let taught6 = memory.learn(scope: scope, kind: .expense, text: "CAFE", fill: .init(note: "Кофе"))
    #expect(!taught6)
    let taught7 = memory.learn(scope: scope, kind: .expense, text: "CAFE", fill: .init(note: "Обед"))
    #expect(taught7)
    #expect(memory.fill(scope: scope, kind: .expense, text: "cafe")?.note == "Обед")
  }

  @Test func filledThroughAnotherAccountOfTheBankIsCopiedSoAnEditStaysLocal() {
    var memory = BankTextMemory()
    memory.learn(scope: scope, kind: .expense, text: "CAFE", fill: .init(note: "Кофе"))
    let sibling = BankTextMemory.Scope(accountId: UUID(), bankId: bank)
    let operation = UUID()
    let taught8 = memory.filled(operation: operation, scope: sibling, kind: .expense, text: "CAFE")
    #expect(taught8)
    let taught9 = memory.relearn(operation: operation, fill: .init(note: "Обед"))
    #expect(taught9)
    #expect(memory.fill(scope: sibling, kind: .expense, text: "CAFE")?.note == "Обед")
    #expect(memory.fill(scope: scope, kind: .expense, text: "CAFE")?.note == "Кофе")
    // Nothing learned: nothing filled, nothing remembered.
    let taught10 = memory.filled(operation: UUID(), scope: scope, kind: .expense, text: "SHOP")
    #expect(!taught10)
  }

  @Test func splitOperationTeachesOnlyItsPlaceAndWords() {
    let id = UUID()
    let transaction = Transaction(
      id: id, kind: .expense, occurredAt: Date(timeIntervalSince1970: 0),
      amountE4: AmountE4(whole: 300), note: "Ужин", placeId: place,
      createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    let parts = [
      TransactionPart(transactionId: id, categoryId: UUID(), amountE4: AmountE4(whole: 100)),
      TransactionPart(
        transactionId: id, categoryId: UUID(), amountE4: AmountE4(whole: 200), forWhom: .partner),
    ]
    let fill = BankTextFill(entry: TransactionEntry(transaction: transaction, parts: parts))
    #expect(fill.placeId == place && fill.note == "Ужин")
    #expect(fill.categoryId == nil && fill.forWhom == nil)
  }

  @Test func capacityKeepsTheLatestPairsAndForgetsTheirOperations() {
    var memory = BankTextMemory()
    let first = UUID()
    memory.learn(
      scope: scope, kind: .expense, text: "SHOP0", fill: .init(note: "n"), operation: first)
    for index in 1...BankTextMemory.capacity {
      memory.learn(scope: scope, kind: .expense, text: "SHOP\(index)", fill: .init(note: "n"))
    }
    #expect(memory.items.count == BankTextMemory.capacity)
    #expect(memory.fill(scope: scope, kind: .expense, text: "SHOP0") == nil)
    #expect(!memory.remembers(operation: first))
    #expect(memory.operations[first.uuidString] == nil)
  }
}
