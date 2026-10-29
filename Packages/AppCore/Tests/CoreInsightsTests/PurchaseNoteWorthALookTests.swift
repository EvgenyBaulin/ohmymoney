import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

@Suite("Purchase lines in «Стоит посмотреть»")
struct PurchaseNoteWorthALookTests {
  @Test func theLineKeepsTheIdOfItsNote() {
    let question = RegretQuestion(
      transactionId: UUID(), boughtOn: DateOnly(year: 2026, month: 10, day: 28), categoryId: nil,
      amountRubE4: AmountE4(whole: 15_000), note: nil)
    let note = PurchaseNote.regret(question)
    #expect(WorthALookNote.purchase(note).id == note.id)
    #expect(note.id == "purchase.regret:\(question.transactionId.uuidString)")
  }
}
