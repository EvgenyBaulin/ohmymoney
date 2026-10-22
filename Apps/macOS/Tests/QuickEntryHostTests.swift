import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// Quick entry in the entry bar as the window shows it: a text of a bank pasted into the line, a
/// line of several operations, a bill with a tip, and a correction that waits for its answer.
@MainActor
final class QuickEntryHostTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  /// A category and one operation for each of `words`, so history files the next line of those
  /// words there and Enter does not stop for a category.
  @discardableResult
  private static func history(
    _ words: [String], in environment: AppEnvironment
  ) throws
    -> CoreKit.Category
  {
    let category = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
    try environment.references!.save(category)
    for word in words {
      var earlier = TransactionDraft(amount: AmountE4(whole: 100), note: word)
      earlier.normalizeSinglePart()
      earlier.parts[0].categoryId = category.id
      try environment.transactions!.save(try earlier.materialize())
    }
    return category
  }

  private func operations(of host: EntryHost, amount: Int64) throws -> [TransactionEntry] {
    try host.transactions.recentEntries(limit: 50).filter {
      $0.transaction.amountE4 == AmountE4(whole: amount) && !$0.transaction.isDeleted
    }
  }

  // MARK: Paste

  func testATextOfABankPastedIntoTheLineBecomesTheLineItSays() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let field = try host.line()
    try host.type("MIR-3230 12:45 Покупка 1250р PYATEROCHKA Баланс: 52340.11р", into: field)
    let line = field.stringValue
    XCTAssertTrue(line.contains("1250"), line)
    XCTAssertFalse(line.contains("Баланс"), line)
    XCTAssertFalse(line.contains("MIR"), line)
    XCTAssertEqual(try host.transactions.count(), 0, "a paste writes nothing")
  }

  func testAPasteThatIsNoBankTextStaysAsPasted() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let field = try host.line()
    let text = "купить хлеб, молоко и сыр в магазине рядом с домом"
    try host.type(text, into: field)
    XCTAssertEqual(field.stringValue, text)
  }

  // MARK: Several operations

  func testALineOfSeveralOperationsIsWrittenPartByPart() async throws {
    let host = try await EntryHost(opensDetails: false) {
      try Self.history(["coffee", "metro"], in: $0)
    }
    self.host = host
    let editor = try host.type("coffee 250; metro 62", into: try host.line())
    editor.insertNewline(nil)
    XCTAssertTrue(
      host.settle(until: {
        ((try? self.operations(of: host, amount: 250).count) ?? 0) == 1
          && ((try? self.operations(of: host, amount: 62).count) ?? 0) == 1
      }),
      "both parts were written")
    XCTAssertEqual(try host.line().stringValue, "", "the line is clear once the last part is in")
  }

  // MARK: A tip

  func testABillWithATipIsOneOperationOfTwoParts() async throws {
    let host = try await EntryHost(opensDetails: false) {
      try Self.history(["coffee"], in: $0)
    }
    self.host = host
    let editor = try host.type("coffee 2000 чай 200", into: try host.line())
    editor.insertNewline(nil)
    XCTAssertTrue(
      host.settle(until: { ((try? self.operations(of: host, amount: 2200).count) ?? 0) == 1 }),
      "the bill and the tip are one operation of 2200")
    let written = try XCTUnwrap(try operations(of: host, amount: 2200).first)
    XCTAssertEqual(written.parts.map(\.amountE4), [AmountE4(whole: 2000), AmountE4(whole: 200)])
    let tipCategory = try XCTUnwrap(written.parts[1].categoryId)
    let categories = try host.references.categories(includeArchived: true)
    XCTAssertEqual(categories.first { $0.id == tipCategory }?.name, "Чаевые")
    XCTAssertEqual(
      categories.first { $0.id == tipCategory }?.parentId,
      categories.first { $0.id == written.parts[0].categoryId }?.parentId
        ?? written.parts[0].categoryId, "under the category of the bill")
  }

  // MARK: A correction

  func testACorrectionLineWritesNothingUntilTheOwnerAgrees() async throws {
    let host = try await EntryHost(opensDetails: false) {
      try Self.history(["coffee"], in: $0)
    }
    self.host = host
    let editor = try host.type("ой 350", into: try host.line())
    editor.insertNewline(nil)
    host.settle(0.5)
    XCTAssertEqual(try operations(of: host, amount: 350).count, 0)
    XCTAssertEqual(
      try operations(of: host, amount: 100).count, 1, "the last operation is as it was")
    XCTAssertEqual(try host.transactions.count(), 1, "the correction line is no new operation")
  }
}
