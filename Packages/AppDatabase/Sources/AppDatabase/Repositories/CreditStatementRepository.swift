import CoreKit
import Foundation
import GRDB

/// The minimum payments typed from a bank's statements. They are written through the planning
/// (`PlanningRows.creditStatements`), so a save is one step of ⌘Z; this reads them.
public struct CreditStatementRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// On an open database of the app.
  public init(stack: DatabaseStack) {
    self.writer = stack.writer
  }

  /// Everything, in a stable order; rows that do not read are left out.
  static func all(_ db: Database) throws -> [CreditStatementOverride] {
    try Row.fetchAll(
      db, sql: "SELECT * FROM credit_statements ORDER BY payment_method_id, statement_on, id"
    ).compactMap { try? CreditStatementOverride(row: $0) }
  }

  public func all() throws -> [CreditStatementOverride] {
    try writer.read { try Self.all($0) }
  }
}
