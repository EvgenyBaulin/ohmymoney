import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// The kinds of the form at the side of the window, in a window: all five always in sight, in one
/// track of equal segments as the design draws it; a segment switches the fields to its kind, and
/// «Перевод» to the fields of a transfer, written by «Записать» in the form itself.
@MainActor
final class EntryKindTilesFormTests: XCTestCase {
  private var host: EntryHost?
  private let wages = CoreKit.Category(kind: .income, name: "Wages", quality: .neutral)
  private let cash = PaymentMethod(name: "Cash", currency: .rub, isDefault: true)
  private let savings = PaymentMethod(name: "Savings", currency: .rub)

  override func tearDown() async throws {
    if let sheet = host?.window.attachedSheet { host?.window.endSheet(sheet) }
    host?.close()
    host = nil
  }

  private static let identifiers = [
    "entry.kind.expense", "entry.kind.income", "entry.kind.reimbursement", "entry.kind.refund",
    "entry.kind.transfer",
  ]

  private func tiles(of host: EntryHost) throws -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    for identifier in Self.identifiers {
      let tile = try XCTUnwrap(
        WindowAccessibility.element(identified: identifier, in: host.window),
        "«\(identifier)» is not in sight")
      frames[identifier] = WindowAccessibility.frame(of: tile)
    }
    return frames
  }

  /// `incomes` incomes and one expense in the book before the form appears.
  private func openForm(incomes: Int) async throws -> EntryHost {
    let wages = wages
    let accounts = [cash, savings]
    let host = try await EntryHost(opensDetails: false, style: .form) { environment in
      try environment.references!.save(wages)
      for account in accounts { try environment.references!.save(account) }
      for index in 0...incomes {
        var draft = TransactionDraft(
          kind: index == 0 ? .expense : .income, amount: AmountE4(whole: 100))
        draft.normalizeSinglePart()
        try environment.transactions!.save(try draft.materialize())
      }
    }
    self.host = host
    return host
  }

  /// The design's track: all five in one row, each of one width, none lit before the kind is
  /// chosen.
  func testTheFiveKindsStandInOneRowOfOneWidth() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm(incomes: 0)
    let frames = try tiles(of: host)
    let expense = try XCTUnwrap(frames["entry.kind.expense"])
    for (identifier, frame) in frames {
      XCTAssertEqual(frame.midY, expense.midY, accuracy: 2, "«\(identifier)» in the one row")
      XCTAssertEqual(frame.width, expense.width, accuracy: 2, "«\(identifier)» of one width")
    }
  }

  /// The kind used most no longer stretches: the order and the widths are the design's whatever
  /// the book holds.
  func testTheKindUsedMostKeepsItsPlace() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm(incomes: 3)
    let frames = try tiles(of: host)
    let expense = try XCTUnwrap(frames["entry.kind.expense"])
    let income = try XCTUnwrap(frames["entry.kind.income"])
    XCTAssertEqual(income.width, expense.width, accuracy: 2)
    XCTAssertLessThan(expense.minX, income.minX, "«Расход» first, as the design draws it")
  }

  /// «Доход» makes the fields the fields of an income: its categories are offered, and what is
  /// saved is an income.
  func testATileSwitchesTheFieldsToItsKind() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm(incomes: 0)
    let income = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.kind.income", in: host.window))
    WindowAccessibility.press(income)
    host.settle()
    try host.type("500", into: try host.field(prompt: "0"))
    try WindowAccessibility.choose("Wages", inMenu: "entry.category", of: host.window)
    let save = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.form.save", in: host.window))
    WindowAccessibility.press(save)
    host.settle()
    let saved = try XCTUnwrap(
      try host.transactions.recentEntries(limit: 10).first {
        $0.transaction.amountE4 == AmountE4(whole: 500)
      }, "the income was not saved")
    XCTAssertEqual(saved.transaction.kind, .income)
    XCTAssertEqual(saved.parts.first?.categoryId, wages.id)
  }

  func testTheTransferTileShowsTheTransferFieldsAndSaveWritesIt() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm(incomes: 0)
    let transfer = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.kind.transfer", in: host.window))
    WindowAccessibility.press(transfer)
    host.settle()
    XCTAssertNil(host.window.attachedSheet, "a transfer opens no window of its own")
    XCTAssertNotNil(
      WindowAccessibility.element(identified: "transfer.from", in: host.window),
      "the fields of a transfer are not in the form")
    XCTAssertNil(
      WindowAccessibility.element(identified: "entry.category", in: host.window),
      "the fields of an operation stayed")

    // The amounts of the transfer, top to bottom: sent, then the fee.
    let sent = try XCTUnwrap(
      host.textFields().filter { $0.placeholderString == "0" }
        .max { $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY })
    _ = try host.type("700", into: sent)
    try WindowAccessibility.choose("Savings", inMenu: "transfer.to", of: host.window)
    host.settle()
    let save = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.form.save", in: host.window))
    WindowAccessibility.press(save)
    var written: [Transfer] = []
    let deadline = Date().addingTimeInterval(3)
    while written.isEmpty, Date() < deadline {
      host.settle(0.1)
      let books = await TransferActions(environment: host.environment, store: host.store).books()
      written = try XCTUnwrap(books).dataset.transfers
    }
    let refusal = WindowAccessibility.element(identified: "transfer.refusal", in: host.window)
      .map(WindowAccessibility.text(of:))
    let saved = try XCTUnwrap(
      written.first, "«Сохранить» did not write the transfer: \(refusal ?? "")")
    XCTAssertEqual(saved.fromAccountId, cash.id, "the main account is where the money leaves")
    XCTAssertEqual(saved.toAccountId, savings.id)
    XCTAssertEqual(saved.fromAmountE4, AmountE4(whole: 700))
    XCTAssertEqual(try host.transactions.count(), 1, "only the expense of the book")
    // The form starts again from the kinds.
    host.settle()
    XCTAssertNotNil(
      WindowAccessibility.element(identified: "entry.form.chooseKind", in: host.window),
      "the form did not start over")
  }
}
