import CoreKit
import CoreParse
import Foundation
import Testing

struct ImportDocumentRouteTests {
  private let today = DateOnly(year: 2026, month: 11, day: 11)

  private func route(
    _ text: String, qr: Bool = false, statement: Bool = false
  ) -> ImportDocumentRoute {
    ImportDocumentRoute.read(
      lines: text.components(separatedBy: "\n").map {
        RecognizedLine(text: $0, confidence: 0.95)
      }, today: today, hasReceiptQR: qr, isStatement: statement)
  }

  @Test func recognisedStatementsStayInStatementImport() {
    #expect(route("Покупка 450 ₽. Карта *7788", statement: true) == .statement)
  }

  @Test func fiscalQRHasPriorityOverPrintedBankText() {
    #expect(route("Покупка 450 ₽. Карта *7788", qr: true) == .receipt)
  }

  @Test func receiptsAndGuestBillsKeepTheirExistingRules() {
    #expect(route("Sample Market LLC\nCəmi: 7.40 ₼\nTarix 02.11.2026\nVaxt 10:15") == .receipt)
    #expect(route("Предварительный счёт\nИтого 450\n11.11.2026 12:45") == .receipt)
  }

  @Test func bankOperationPicturesGoToScreenshotMatching() {
    #expect(route("MIR-3230 12:45 Покупка 1250р PYATEROCHKA Баланс: 52340.11р") == .screenshot)
    #expect(route("MIR-3230 12:45 Покупка 1250р PYATEROCHKA\nСчёт списания") == .screenshot)
  }

  @Test func unrecognisedDocumentsAskInsteadOfGuessing() {
    #expect(route("synthetic unreadable document") == .unknown)
    #expect(route("") == .unknown)
  }
}
