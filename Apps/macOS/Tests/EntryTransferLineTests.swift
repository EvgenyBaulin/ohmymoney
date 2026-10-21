import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// «перевод 5000 сбер т-банк» in the line: the word «перевод» and two accounts are a transfer
/// from the first to the second, written at Enter, and no operation; «перевод маше 500» — a
/// person, not an account — stays the operation it always was.
@MainActor
final class EntryTransferLineTests: XCTestCase {
  private var host: EntryHost?
  private let sber = PaymentMethod(name: "Сбер", isDefault: true)
  private let tBank = PaymentMethod(name: "Т-Банк")

  override func tearDown() async throws {
    if let sheet = host?.window.attachedSheet { host?.window.endSheet(sheet) }
    host?.close()
    host = nil
  }

  private func openLine() async throws -> EntryHost {
    let (sber, tBank) = (sber, tBank)
    let host = try await EntryHost(opensDetails: false) { environment in
      try environment.references!.save(sber)
      try environment.references!.save(tBank)
      try environment.references!.save(Person(name: "Маша"))
      try EntryHost.history("кофе", in: environment)
      environment.refreshVocabulary()
    }
    self.host = host
    return host
  }

  private func transfers(of host: EntryHost) async throws -> [Transfer] {
    let stack = try XCTUnwrap(host.environment.stack)
    return try await DatasetRepository(writer: stack.writer).load(version: 0).transfers
  }

  func testTheWordAndTwoAccountsWriteATransfer() async throws {
    let host = try await openLine()
    let editor = try host.type("перевод 5000 сбер т-банк", into: try host.line())
    editor.insertNewline(nil)
    var written: [Transfer] = []
    let deadline = Date().addingTimeInterval(5)
    while written.isEmpty, Date() < deadline {
      host.settle(0.1)
      written = try await transfers(of: host)
    }
    let transfer = try XCTUnwrap(written.first, "no transfer was written")
    XCTAssertEqual(written.count, 1)
    XCTAssertEqual(transfer.fromAccountId, sber.id)
    XCTAssertEqual(transfer.toAccountId, tBank.id)
    XCTAssertEqual(transfer.fromAmountE4, AmountE4(whole: 5000))
    XCTAssertEqual(try host.transactions.count(), 1, "no operation, only the one of the history")
  }

  func testAPersonIsNoAccount() async throws {
    let host = try await openLine()
    let editor = try host.type("перевод маше 500", into: try host.line())
    editor.insertNewline(nil)
    host.settle(0.5)
    let written = try await transfers(of: host)
    XCTAssertTrue(written.isEmpty, "a person is not an account")
    XCTAssertNil(host.window.attachedSheet, "no transfer sheet")
  }
}
