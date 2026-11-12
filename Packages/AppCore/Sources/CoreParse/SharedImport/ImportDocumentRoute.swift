import CoreKit
import Foundation

/// Chooses an existing import flow from recognised facts. Unreadable paper remains a choice
/// for the owner: a PDF extension alone cannot distinguish a statement from a receipt.
public enum ImportDocumentRoute: Equatable, Sendable {
  case statement, receipt, screenshot, unknown

  public static func read(
    lines: [RecognizedLine], today: DateOnly, hasReceiptQR: Bool, isStatement: Bool
  ) -> Self {
    if hasReceiptQR { return .receipt }
    if isStatement { return .statement }
    let printed = PrintedReceiptReader.read(recognized: lines)
    switch printed {
    case .receipt: return .receipt
    case .bill, .nothing: break
    }
    let text = lines.map(\.text).joined(separator: "\n")
    if BankTextParser().parse(text, today: today) != nil { return .screenshot }
    if printed == .bill { return .receipt }
    return .unknown
  }
}
