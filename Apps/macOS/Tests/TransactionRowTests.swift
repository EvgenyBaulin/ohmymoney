import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The mark a row in the list carries for its parts paid for somebody else. It follows what
/// became of the money, so a returned part no longer reads as one still waiting.
@MainActor
final class TransactionRowTests: XCTestCase {
  private func part(_ status: ReimbursementStatus?) -> TransactionPart {
    TransactionPart(
      transactionId: UUID(), amountE4: AmountE4(whole: 100), reimbursable: status != nil,
      reimbursementStatus: status)
  }

  private func status(
    _ statuses: ReimbursementStatus?..., kind: TransactionKind = .expense
  ) -> ReimbursementStatus? {
    let id = UUID()
    return TransactionListing.owedMark(
      of: TransactionEntry(
        transaction: Transaction(
          id: id, kind: kind, occurredAt: Date(), amountE4: AmountE4(whole: 100)),
        parts: statuses.map(part)))
  }

  func testAPartStillWaitingMarksTheWholeRowAsWaiting() {
    XCTAssertEqual(status(.returned, .expected), .expected)
    XCTAssertEqual(status(.writtenOff, .expected, nil), .expected)
  }

  /// Money that came back, or was given up on, is no longer waited for.
  func testAReturnedOrWrittenOffRowNoLongerSaysWaiting() {
    XCTAssertEqual(status(nil, .returned), .returned)
    XCTAssertEqual(status(.writtenOff, .returned), .returned)
    XCTAssertEqual(status(.writtenOff), .writtenOff)
  }

  func testARowWithNothingPaidForOthersHasNoMark() {
    XCTAssertNil(status(nil))
    XCTAssertNil(status())
  }

  /// Only a purchase is waited for: a friend's ticket taken back in a refund keeps the
  /// status its part was written with, and must not read «waiting».
  func testARefundOfAPartForSomebodyElseCarriesNoMark() {
    XCTAssertNil(status(.expected, kind: .refund))
    XCTAssertEqual(status(.expected, kind: .expense), .expected)
  }

  /// A row of the list of days shows the quality the table of Transactions shows: the rules'
  /// quality of each part — the category's own when the part stores none — and «several»
  /// when the parts of a split disagree. It used to show the first part's stored quality.
  func testTheListOfDaysShowsTheQualityOfEveryPartAsTheTableDoes() {
    let treats = CoreKit.Category(kind: .expense, name: "Treats", quality: .bad)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .good)
    let splitId = UUID()
    let split = TransactionEntry(
      transaction: Transaction(
        id: splitId, kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 300)),
      parts: [
        TransactionPart(
          transactionId: splitId, categoryId: groceries.id, quality: .good,
          qualitySource: .category, amountE4: AmountE4(whole: 200)),
        TransactionPart(
          transactionId: splitId, categoryId: treats.id, quality: .bad,
          qualitySource: .category, amountE4: AmountE4(whole: 100)),
      ])
    let unratedId = UUID()
    let unrated = TransactionEntry(
      transaction: Transaction(
        id: unratedId, kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 100)),
      parts: [
        TransactionPart(
          transactionId: unratedId, categoryId: treats.id, amountE4: AmountE4(whole: 100))
      ])
    let ledger = Ledger(
      dataset: Dataset(entries: [split, unrated], categories: [treats, groceries]),
      calendar: .utc)

    XCTAssertEqual(TransactionListing.quality(of: split, ledger: ledger), .several)
    XCTAssertEqual(TransactionListing.quality(of: unrated, ledger: ledger), .one(.bad))
    // Before the data has come: what the parts store, compared the same way.
    XCTAssertEqual(TransactionListing.quality(of: split, ledger: nil), .several)
  }

  /// A day of Overview lists every kind in one line-up, so each row's symbol says its kind in
  /// words — to VoiceOver and on hover — in both languages, and no two kinds read alike.
  func testTheKindSymbolIsSpoken() {
    let environment = AppEnvironment()
    let expected: [AppLanguage.Choice: [TransactionKind: String]] = [
      .russian: [
        .income: "Доход", .expense: "Расход", .refund: "Возврат покупки",
        .reimbursement: "Возврат денег",
      ],
      .english: [
        .income: "Income", .expense: "Expense", .refund: "Refund", .reimbursement: "Money back",
      ],
    ]
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for (choice, words) in expected {
      environment.language.choice = choice
      for kind in TransactionKind.allCases {
        XCTAssertEqual(
          TransactionRow.kindWords(kind, language: environment.language), words[kind],
          "\(kind), \(choice)")
      }
    }
    // Every kind has a symbol of its own, the words only confirm it.
    XCTAssertEqual(
      Set(TransactionKind.allCases.map(Palette.kindSymbol)).count, TransactionKind.allCases.count)
  }

  /// Each status has its own symbol, so the three can be told apart without colour.
  func testEveryStatusHasASymbolOfItsOwn() {
    let symbols = Set(ReimbursementStatus.allCases.map(Palette.reimbursementSymbol))
    XCTAssertEqual(symbols.count, ReimbursementStatus.allCases.count)
  }

  /// A drawn row says its kind to VoiceOver together with its title, as one element: a day of
  /// Overview mixes purchases and refunds under no «Расходы» heading, so without the words on
  /// the symbol «кофе» and a refunded «наушники» would be heard alike. Read from the
  /// accessibility tree the window builds; a runner without an assistive client builds none.
  func testADrawnRowIsHeardWithItsKindAndItsTitle() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let environment = AppEnvironment()
    let before = environment.language.choice
    environment.language.choice = .russian
    defer { environment.language.choice = before }
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    func entry(_ kind: TransactionKind, _ note: String) -> TransactionEntry {
      let id = UUID()
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: kind, occurredAt: Date(), amountE4: AmountE4(whole: 250), note: note),
        parts: [TransactionPart(transactionId: id, amountE4: AmountE4(whole: 250))])
    }
    let rows: [(title: String, kind: TransactionKind)] = [
      ("кофе с собой", .expense), ("наушники", .refund),
    ]
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: VStack {
          ForEach(rows, id: \.title) { row in
            TransactionRow(entry: entry(row.kind, row.title), names: CategoryTree(), quality: .none)
          }
        }
        .padding()
        .frame(width: 560)
        .appDependencies(deps)))
    window.setContentSize(CGSize(width: 560, height: 200))
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    defer { window.close() }

    var heard: [String] = []
    let deadline = Date().addingTimeInterval(5)
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      heard = Self.everything(in: window).map(Self.spoken)
    } while !rows.allSatisfy({ row in heard.contains { $0.contains(row.title) } })
      && Date() < deadline

    for row in rows {
      let kind = TransactionRow.kindWords(row.kind, language: environment.language)
      XCTAssertTrue(
        heard.contains { $0.contains(row.title) && $0.contains(kind) },
        "«\(row.title)» is not heard with «\(kind)» as one: \(heard)")
    }
    // The same words come on hover: the help of the row, which VoiceOver also reads.
    let helped = Self.everything(in: window).map {
      (spoken: Self.spoken($0), help: Self.attribute($0, "accessibilityHelp") as? String ?? "")
    }
    for row in rows {
      let kind = TransactionRow.kindWords(row.kind, language: environment.language)
      XCTAssertTrue(
        helped.contains { $0.spoken.contains(row.title) && $0.help.contains(kind) },
        "«\(row.title)» has no help «\(kind)»: \(helped)")
    }
    // The purchase is not heard as a refund, nor the refund as a purchase.
    let expense = TransactionRow.kindWords(.expense, language: environment.language)
    let refund = TransactionRow.kindWords(.refund, language: environment.language)
    XCTAssertFalse(
      heard.contains { $0.contains("кофе с собой") && $0.contains(refund) }, "\(heard)")
    XCTAssertFalse(
      heard.contains { $0.contains("наушники") && $0.contains(expense) }, "\(heard)")
  }

  /// Every element of the window's accessibility tree, in the order VoiceOver reads them.
  private static func everything(in window: NSWindow) -> [NSObject] {
    var found: [NSObject] = []
    func walk(_ element: Any, depth: Int) {
      guard depth < 60, let object = element as? NSObject else { return }
      found.append(object)
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    if let root = window.contentView { walk(root, depth: 0) }
    return found
  }

  private static func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  /// What VoiceOver says for an element: its label, its title and its value.
  private static func spoken(_ object: NSObject) -> String {
    ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
      .compactMap { attribute(object, $0) as? String }
      .filter { !$0.isEmpty }
      .joined(separator: " | ")
  }
}
