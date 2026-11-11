import AppCore
import Foundation
import GRDB
import Testing

@testable import AppDatabase

struct StatementReviewExportTests {
  @Test func aCopyWithoutHiddenAccountsDoesNotKeepTheirStatementFacts() throws {
    let stack = try TestSupport.makeStack()
    let hidden = UUID()
    let visible = UUID()
    let check = StatementCheck(kind: .footerTotals, passed: false, blocking: true)
    let reviews = try [hidden, visible].map { account in
      try #require(
        StatementReview.make(
          importID: UUID().uuidString, accountID: account,
          fileName: "synthetic.pdf", checks: [check]))
    }
    try stack.writer.write { db in
      try db.execute(
        sql:
          "INSERT INTO payment_methods (id, name, kind, hidden) VALUES (?, 'Hidden', 'card', 1), (?, 'Visible', 'card', 0)",
        arguments: [hidden.uuidString, visible.uuidString])
      try db.execute(
        sql: "INSERT INTO settings (key, value) VALUES (?, ?)",
        arguments: [StatementReview.settingsKey, try StatementReview.encode(reviews)])
      try ExportCopyMaker.cut(
        ExportCopyRequest(includeHidden: false, password: "synthetic"), db: db)
      let text = try String.fetchOne(
        db, sql: "SELECT value FROM settings WHERE key = ?",
        arguments: [StatementReview.settingsKey])
      #expect(StatementReview.decode(text).map(\.accountID) == [visible])
    }
  }

  @Test func aPeriodCopyDoesNotCarryChecksForTheWholeOriginalStatement() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(
        sql: "INSERT INTO settings (key, value) VALUES (?, '[]')",
        arguments: [StatementReview.settingsKey])
      let day = DateOnly(year: 2026, month: 9, day: 15)
      try ExportCopyMaker.cut(
        ExportCopyRequest(scope: .period(DayRange(day, day)), password: "synthetic"), db: db)
      let value = try String.fetchOne(
        db, sql: "SELECT value FROM settings WHERE key = ?",
        arguments: [StatementReview.settingsKey])
      #expect(value == nil)
    }
  }
}
