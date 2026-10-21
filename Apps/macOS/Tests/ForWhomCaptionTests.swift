import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Для кого» reads «На кого» in every caption of the Russian interface; English stays «For
/// whom». Money back names the person it came from: «От кого» over its picker and «от: Аня» in
/// the column of the list.
@MainActor
final class ForWhomCaptionTests: XCTestCase {
  private let captions: [(key: String, table: String)] = [
    ("entry.forWhom", "Entry"), ("transactions.column.forWhom", "Transactions"),
    ("bulk.forWhom", "Transactions"), ("analytics.section.forWhom", "Analytics"),
    ("reports.grouping.forWhom", "Reports"), ("form.forWhom", "Planning"),
    ("form.limit.scope.forWhom", "Planning"),
  ]

  func testRussianCaptionsSayOnWhomAndEnglishStaysForWhom() {
    let language = AppLanguage()
    language.choice = .russian
    for caption in captions {
      XCTAssertEqual(language(caption.key, table: caption.table), "На кого", caption.key)
    }
    XCTAssertEqual(language("analytics.block.forWhomValues", table: "Analytics"), "По «на кого»")
    XCTAssertEqual(language("reports.by.forWhom", table: "Reports"), "по «на кого»")
    language.choice = .english
    for caption in captions {
      XCTAssertEqual(language(caption.key, table: caption.table), "For whom", caption.key)
    }
  }

  /// The person of money back is «От кого» — in the sheet of money back and in the panel of an
  /// operation of that kind.
  func testMoneyBackAsksFromWhom() {
    let language = AppLanguage()
    language.choice = .russian
    XCTAssertEqual(language("entry.fromWhom", table: "Entry"), "От кого")
    language.choice = .english
    XCTAssertEqual(language("entry.fromWhom", table: "Entry"), "From")
    XCTAssertEqual(DetailsPanel.forWhomKey(of: .reimbursement), "entry.fromWhom")
    for kind in [TransactionKind.expense, .income, .refund] {
      XCTAssertEqual(DetailsPanel.forWhomKey(of: kind), "entry.forWhom", kind.rawValue)
    }
  }

  /// The column shows «от: Аня» for money back and the bare name for money spent on someone.
  /// A name is stored as it is said on its own, and «от» wants it declined — «от Ани» — which
  /// no rule gets right for every name; after a colon it is right as it is.
  func testTheColumnNamesWhoGaveTheMoneyBack() throws {
    let language = AppLanguage()
    language.choice = .russian
    XCTAssertEqual(
      ForWhomValue.personText("Аня", kind: .reimbursement, language: language), "от: Аня")
    XCTAssertEqual(ForWhomValue.personText("Аня", kind: .expense, language: language), "Аня")
    language.choice = .english
    XCTAssertEqual(
      ForWhomValue.personText("Anna", kind: .reimbursement, language: language), "from Anna")

    // The row of money back carries the person who gave it, and its kind says how to read it.
    let anna = Person(name: "Anna", relation: .friend)
    let id = UUID()
    let when = Date(timeIntervalSince1970: 1_790_000_000)
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .reimbursement, occurredAt: when, amountE4: AmountE4(whole: 500),
        createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(transactionId: id, amountE4: AmountE4(whole: 500), forPersonId: anna.id)
      ])
    let ledger = Ledger(dataset: Dataset(entries: [entry], people: [anna]), calendar: .utc)
    let row = try XCTUnwrap(
      TransactionListing.build([entry.id], ledger: ledger).sections.first?.rows.first)
    XCTAssertEqual(row.kind, .reimbursement)
    XCTAssertEqual(row.forWhom, .one(.person("Anna")))
    // What the cell of that row says: the words of its person for its kind.
    guard case .one(.person(let name)) = row.forWhom else { return XCTFail("no person") }
    language.choice = .english
    XCTAssertEqual(
      ForWhomValue.personText(name, kind: row.kind, language: language), "from Anna")
    language.choice = .russian
    XCTAssertEqual(ForWhomValue.personText(name, kind: row.kind, language: language), "от: Anna")
  }
}
