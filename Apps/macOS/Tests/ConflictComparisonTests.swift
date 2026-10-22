import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The comparison of a conflict: what the owner reads before choosing. Synthetic data only.
@MainActor
final class ConflictComparisonTests: XCTestCase {
  private func side(
    _ fields: [String: SyncValue], deleted: Bool = false
  ) -> SyncConflict.Side {
    SyncConflict.Side(
      fields: fields, isDeleted: deleted, madeAt: SyncInstant("2026-10-22T10:00:00Z")!)
  }

  private func conflict(
    table: String = "transactions", mine: [String: SyncValue], theirs: [String: SyncValue],
    mineDeleted: Bool = false, theirsDeleted: Bool = false
  ) -> SyncConflict {
    SyncConflict(
      key: RecordKey(table: table, uuid: "u1"), mine: side(mine, deleted: mineDeleted),
      theirs: side(theirs, deleted: theirsDeleted), differingFields: [])
  }

  func testTheDifferingFieldsAreMarkedAndTheSameOnesAreShownQuietly() {
    let comparison = ConflictComparison.make(
      conflict(
        mine: [
          "note": .string("кофе"), "amount_e4": .int(2_500_000), "currency": .string("RUB"),
          "occurred_at": .string("2026-10-12 10:00:00.000"), "updated_at": .string("x"),
        ],
        theirs: [
          "note": .string("кофе"), "amount_e4": .int(3_000_000), "currency": .string("RUB"),
          "occurred_at": .string("2026-10-12 10:00:00.000"), "updated_at": .string("y"),
        ]))
    XCTAssertEqual(comparison.title, "кофе")
    XCTAssertEqual(comparison.rows.map(\.id), ["note", "amount_e4", "currency", "occurred_at"])
    XCTAssertEqual(comparison.rows.map(\.differs), [false, true, false, false])
    XCTAssertEqual(comparison.rows[1].mine, .value("250"))
    XCTAssertEqual(comparison.rows[1].theirs, .value("300"))
    XCTAssertEqual(comparison.rows[3].mine, .value("2026-10-12"))
    XCTAssertEqual(comparison.tableKey, "sync.table.transactions")
  }

  func testAReferenceThatDiffersSaysOtherAndOneThatMatchesIsLeftOut() {
    let comparison = ConflictComparison.make(
      conflict(
        mine: ["note": .string("a"), "category_id": .string("c1"), "place_id": .string("p1")],
        theirs: ["note": .string("a"), "category_id": .string("c2"), "place_id": .string("p1")]))
    XCTAssertEqual(comparison.rows.map(\.id), ["note", "category_id"])
    XCTAssertEqual(comparison.rows[1].mine, .other)
    XCTAssertEqual(comparison.rows[1].theirs, .other)
  }

  func testColumnsWithoutALabelBecomeOneRowOfOtherDetails() {
    let comparison = ConflictComparison.make(
      conflict(
        table: "cards", mine: ["name": .string("Black"), "fx_fee_e4": .int(15), "sort": .int(1)],
        theirs: ["name": .string("Black"), "fx_fee_e4": .int(20), "sort": .int(2)]))
    XCTAssertEqual(comparison.rows.map(\.id), ["name", "other"])
    XCTAssertEqual(comparison.tableKey, "sync.table.cards")
  }

  func testADeleteIsShownOnItsSideAndAnUnknownTableIsJustARecord() {
    let comparison = ConflictComparison.make(
      conflict(
        table: "cashback_rules", mine: ["percent_e4": .int(1)], theirs: [:], theirsDeleted: true))
    XCTAssertFalse(comparison.mineDeleted)
    XCTAssertTrue(comparison.theirsDeleted)
    XCTAssertEqual(comparison.tableKey, "sync.table.other")
    XCTAssertNil(comparison.title)
  }

  func testMoneyIsWrittenLikeTheRestOfTheApp() {
    XCTAssertEqual(ConflictComparison.money(2_500_000), "250")
    XCTAssertEqual(ConflictComparison.money(12_345_678), "1,234.57")
    XCTAssertEqual(ConflictComparison.money(-5_000_000), "\u{2212}500")
    XCTAssertEqual(ConflictComparison.money(9_999_950), "1,000")
    XCTAssertEqual(ConflictComparison.money(0), "0")
    XCTAssertEqual(ConflictComparison.money(1_000_050), "100.01")
  }

  /// Every word the screens look up exists in both languages, in the table `Sync`.
  func testEveryLabelTheComparisonCanAskForIsInTheCatalogInBothLanguages() {
    let keys =
      ConflictComparison.labelled.map { "sync.field.\($0)" } + ["sync.field.other"]
      + ConflictComparison.known.map { "sync.table.\($0)" } + ["sync.table.other"]
    let language = AppLanguage()
    let original = language.choice
    defer { language.choice = original }
    for code in ["en", "ru"] {
      language.choice = AppLanguage.Choice(rawValue: code) ?? .system
      for key in keys {
        XCTAssertNotEqual(language(key, table: "Sync"), key, "\(code): \(key)")
      }
    }
  }
}
