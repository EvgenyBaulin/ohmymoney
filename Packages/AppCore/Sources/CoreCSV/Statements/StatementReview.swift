import CoreKit
import Foundation

/// A statement written with unresolved totals. Stored with its operations in the same undo step.
public struct StatementReview: Codable, Hashable, Sendable, Identifiable {
  public static let settingsKey = "import.pendingReviews"
  public var id: String
  public var accountID: UUID
  public var fileName: String
  public var checks: [StatementCheck]
  public var closingBalance: AmountE4?
  public var ledgerBalance: AmountE4?
  public var currency: CurrencyCode?
  /// Also includes operations merged into older entries, which keep their original batch.
  public var operationIDs: [UUID]?
  public var transferIDs: [UUID]?

  public static func make(
    importID: String, accountID: UUID, fileName: String, checks: [StatementCheck],
    closingBalance: AmountE4? = nil, ledgerBalance: AmountE4? = nil, currency: CurrencyCode? = nil,
    operationIDs: [UUID] = [], transferIDs: [UUID] = []
  ) -> StatementReview? {
    let failed = checks.filter { $0.kind == .footerTotals && !$0.passed }
    let balanceNeedsReview = closingBalance != nil && closingBalance != ledgerBalance
    guard !failed.isEmpty || balanceNeedsReview else { return nil }
    return StatementReview(
      id: importID, accountID: accountID, fileName: fileName, checks: failed,
      closingBalance: balanceNeedsReview ? closingBalance : nil,
      ledgerBalance: balanceNeedsReview ? ledgerBalance : nil, currency: currency,
      operationIDs: operationIDs, transferIDs: transferIDs)
  }

  public static func decode(_ text: String?) -> [StatementReview] {
    guard let data = text?.data(using: .utf8),
      let reviews = try? JSONDecoder().decode([StatementReview].self, from: data)
    else { return [] }
    return reviews
  }

  public static func encode(_ reviews: [StatementReview]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(reviews), as: UTF8.self)
  }
}
