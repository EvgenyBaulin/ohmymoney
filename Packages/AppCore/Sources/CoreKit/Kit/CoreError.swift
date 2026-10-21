import Foundation

/// Errors raised by the calculation core. Messages never contain amounts, notes,
/// people or category names: logs must stay free of personal data.
public enum CoreError: Error, Equatable, Sendable {
  case amountOutOfRange
  case divisionByZero
  case malformedExpression(position: Int)
  case emptyInput
  case unknownCurrency(String)
  case invalidDate
  case unbalancedSplit
  case invalidArchive(reason: ArchiveProblem)
  case unsupportedSchemaVersion(found: Int, supported: Int)

  public enum ArchiveProblem: String, Equatable, Sendable {
    case notAZipContainer
    case manifestMissing
    case manifestUnreadable
    case checksumMismatch
    case rowCountMismatch
    case wrongPassword
    case unsupportedFormatVersion
    case truncated
  }
}
