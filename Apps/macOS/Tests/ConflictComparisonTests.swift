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

  func testEveryDifferingColumnIsARowOfItsOwnAndTheOrderInAListIsNotCompared() {
    let comparison = ConflictComparison.make(
      conflict(
        table: "cards", mine: ["name": .string("Black"), "fx_fee_e4": .int(15), "sort": .int(1)],
        theirs: ["name": .string("Black"), "fx_fee_e4": .int(20), "sort": .int(2)]))
    XCTAssertEqual(comparison.rows.map(\.id), ["name", "fx_fee_e4"])
    XCTAssertFalse(comparison.rows.map(\.id).contains("other"))
    XCTAssertEqual(comparison.rows[1].mine, .value("0.0015"))
    XCTAssertEqual(comparison.rows[1].theirs, .value("0.002"))
    XCTAssertEqual(comparison.tableKey, "sync.table.cards")
  }

  /// The owner's account: the same name and currency on both devices, one build wrote the new
  /// columns empty and the other with their defaults, the moments of the save differ. Nothing
  /// to choose — no «другое | другое».
  func testAnAccountThatDiffersOnlyInBookkeepingShowsNoDifference() {
    let mine: [String: SyncValue] = [
      "name": .string("Райффайзен банк"), "currency": .string("RUB"), "hidden": .null,
      "cashback_monthly_cap_e4": .null, "updated_at": .string("2026-11-01 10:00:00"),
      "sort": .int(3), "archived": .int(0),
    ]
    let theirs: [String: SyncValue] = [
      "name": .string("Райффайзен банк"), "currency": .string("RUB"), "hidden": .int(0),
      "cashback_monthly_cap_e4": .int(0), "cashback_choice_day": .null,
      "updated_at": .string("2026-11-02 04:00:00"), "sort": .int(5), "archived": .bool(false),
    ]
    let raw = conflict(table: "payment_methods", mine: mine, theirs: theirs)
    XCTAssertTrue(raw.isOnlyBookkeeping)
    let comparison = ConflictComparison.make(raw)
    XCTAssertEqual(comparison.rows.map(\.id), ["name", "currency"])
    XCTAssertEqual(comparison.rows.map(\.differs), [false, false])
  }

  func testABankAFlagAndAColourReadByTheirMeaning() {
    let raw = conflict(
      table: "payment_methods",
      mine: [
        "name": .string("Card"), "bank_id": .string("b1"), "hidden": .int(0),
        "accent": .string("01"), "deposit_ends_on": .string("2026-12-31"),
      ],
      theirs: [
        "name": .string("Card"), "bank_id": .string("b2"), "hidden": .int(1),
        "accent": .string("08"), "deposit_ends_on": .string("2027-01-31"),
      ])
    XCTAssertEqual(ConflictComparison.referencedIds(raw), ["b1", "b2"])
    let comparison = ConflictComparison.make(raw, names: ["b1": "Т-Банк", "b2": "Сбер"])
    let rows = Dictionary(uniqueKeysWithValues: comparison.rows.map { ($0.id, $0) })
    XCTAssertEqual(rows["bank_id"]?.mine, .value("Т-Банк"))
    XCTAssertEqual(rows["bank_id"]?.theirs, .value("Сбер"))
    XCTAssertEqual(rows["hidden"]?.mine, .flag(false))
    XCTAssertEqual(rows["hidden"]?.theirs, .flag(true))
    XCTAssertEqual(rows["accent"]?.mine, .color("01"))
    XCTAssertEqual(rows["deposit_ends_on"]?.theirs, .value("2027-01-31"))
    // Without the names a reference still says "other", never an id.
    XCTAssertEqual(ConflictComparison.make(raw).rows.first { $0.id == "bank_id" }?.mine, .other)
  }

  /// Each column is named in both languages: by its own label, or — for a column this build
  /// does not know — by «Поле «x»», never «Другие данные».
  func testEachColumnIsLabelledInBothLanguages() {
    let environment = AppEnvironment()
    let language = environment.language
    let original = language.choice
    defer { language.choice = original }
    language.choice = AppLanguage.Choice(rawValue: "ru") ?? .system
    XCTAssertEqual(ConflictText.label("bank_id", environment), "Банк")
    XCTAssertEqual(ConflictText.label("hidden", environment), "Скрыт")
    XCTAssertEqual(ConflictText.label("brand_new_column", environment), "Поле «brand new column»")
    XCTAssertEqual(ConflictText.cell(.flag(true), environment), "Да")
    XCTAssertEqual(ConflictText.cell(.color("01"), environment), "Красный")
    language.choice = AppLanguage.Choice(rawValue: "en") ?? .system
    XCTAssertEqual(ConflictText.label("bank_id", environment), "Bank")
    XCTAssertEqual(ConflictText.cell(.flag(false), environment), "No")
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
