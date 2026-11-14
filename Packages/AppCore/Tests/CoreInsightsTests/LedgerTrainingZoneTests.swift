import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("The day the model learns an operation on")
struct LedgerTrainingZoneTests {
  /// A purchase at 02:00 on 1 October in Bali teaches the model October 1, not 30 September.
  @Test func anExampleIsDatedInTheZoneOfItsOperation() {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_790_791_200),
      amount: AmountE4(whole: 500), note: "Coffee")
    draft.normalizeSinglePart()
    var entry = try! draft.materialize()
    entry.transaction.timeZoneId = "Asia/Makassar"
    let rows = LedgerTraining.rows(
      of: Dataset(entries: [entry]), calendar: .utc)
    #expect(rows.map(\.query.day) == [DateOnly(year: 2026, month: 10, day: 1)])
  }
}
