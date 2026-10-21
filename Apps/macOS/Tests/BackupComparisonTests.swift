import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Сравнить с текущей»: counts, balances, categories, operations added and vanished, and the
/// changed ones folded into one line (1.12, part 2).
final class BackupComparisonTests: XCTestCase {
  private func operation(
    _ id: UUID = UUID(), amount: Int64 = 1_000_000, categories: [UUID?] = [],
    note: String? = nil, day: Int = 1
  ) -> BackupSnapshot.Operation {
    BackupSnapshot.Operation(
      id: id, occurredAt: Date(timeIntervalSince1970: Double(day) * 86_400), kind: "expense",
      amountE4: amount, currency: "RUB", note: note, accountId: nil, categoryIds: categories,
      categoryNames: categories.map { $0 == nil ? "" : "name" })
  }

  private func snapshot(
    _ operations: [BackupSnapshot.Operation], balances: [BackupSnapshot.Balance] = [],
    categories: [UUID: String] = [:]
  ) -> BackupSnapshot {
    BackupSnapshot(
      operations: Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0) }),
      balances: balances, categories: categories)
  }

  func testTheSameBaseIsIdentical() {
    let one = operation()
    let comparison = BackupComparison(copy: snapshot([one]), current: snapshot([one]))
    XCTAssertTrue(comparison.isIdentical)
    XCTAssertEqual(comparison.operationsInCopy, 1)
    XCTAssertEqual(comparison.operationsNow, 1)
  }

  func testAnOperationOnlyTheDatabaseHasIsAdded() {
    let kept = operation(day: 1)
    let new = operation(day: 2)
    let comparison = BackupComparison(copy: snapshot([kept]), current: snapshot([kept, new]))
    XCTAssertEqual(comparison.added.map(\.id), [new.id])
    XCTAssertTrue(comparison.vanished.isEmpty)
    XCTAssertTrue(comparison.changed.isEmpty)
    XCTAssertEqual(comparison.operationsNow - comparison.operationsInCopy, 1)
  }

  func testAnOperationOnlyTheCopyHasHasVanished() {
    let kept = operation(day: 1)
    let gone = operation(day: 2)
    let comparison = BackupComparison(copy: snapshot([kept, gone]), current: snapshot([kept]))
    XCTAssertEqual(comparison.vanished.map(\.id), [gone.id])
    XCTAssertTrue(comparison.added.isEmpty)
  }

  func testAChangedAmountIsOneChangeFromWasToNow() {
    let id = UUID()
    let comparison = BackupComparison(
      copy: snapshot([operation(id, amount: 1_000_000)]),
      current: snapshot([operation(id, amount: 2_500_000)]))
    XCTAssertEqual(comparison.changed.count, 1)
    XCTAssertEqual(comparison.changed[0].was.amountE4, 1_000_000)
    XCTAssertEqual(comparison.changed[0].now.amountE4, 2_500_000)
    XCTAssertTrue(comparison.added.isEmpty)
    XCTAssertTrue(comparison.vanished.isEmpty)
  }

  func testAChangedCategoryIsAChange() {
    let id = UUID()
    let food = UUID()
    let home = UUID()
    let comparison = BackupComparison(
      copy: snapshot([operation(id, categories: [food])]),
      current: snapshot([operation(id, categories: [home])]))
    XCTAssertEqual(comparison.changed.count, 1)
    XCTAssertEqual(comparison.changed[0].was.categoryIds, [food])
    XCTAssertEqual(comparison.changed[0].now.categoryIds, [home])
  }

  func testAMassEditFoldsIntoOneCountOfChanges() {
    let ids = (0..<120).map { _ in UUID() }
    let before = ids.map { operation($0, categories: [UUID()]) }
    let target = UUID()
    let after = ids.map { operation($0, categories: [target]) }
    let comparison = BackupComparison(copy: snapshot(before), current: snapshot(after))
    // One line for the lot: «изменено 120», opening to «было → стало».
    XCTAssertEqual(comparison.changed.count, 120)
    XCTAssertTrue(comparison.added.isEmpty)
    XCTAssertTrue(comparison.vanished.isEmpty)
    XCTAssertEqual(Set(comparison.changed.map(\.now.id)), Set(ids))
  }

  func testTheMatchIsById_aMovedDayWithTheSameIdIsAChangeNotAnAddAndAVanish() {
    let id = UUID()
    let comparison = BackupComparison(
      copy: snapshot([operation(id, day: 1)]), current: snapshot([operation(id, day: 9)]))
    XCTAssertEqual(comparison.changed.count, 1)
    XCTAssertTrue(comparison.added.isEmpty && comparison.vanished.isEmpty)
  }

  func testBalancesAreSetSideBySideAndFlagTheDifferentOnes() {
    let main = UUID()
    let cash = UUID()
    let new = UUID()
    func balance(_ id: UUID, _ name: String, _ amount: Int64) -> BackupSnapshot.Balance {
      BackupSnapshot.Balance(accountId: id, account: name, currency: "RUB", amountE4: amount)
    }
    let comparison = BackupComparison(
      copy: snapshot([], balances: [balance(main, "Main", 100), balance(cash, "Cash", 50)]),
      current: snapshot(
        [],
        balances: [balance(main, "Main", 100), balance(cash, "Cash", 70), balance(new, "New", 5)]
      ))
    XCTAssertEqual(comparison.balances.map(\.account), ["Cash", "Main", "New"])
    XCTAssertEqual(comparison.balances.map(\.isDifferent), [true, false, true])
    XCTAssertEqual(comparison.balances[0].copyE4, 50)
    XCTAssertEqual(comparison.balances[0].currentE4, 70)
    XCTAssertNil(comparison.balances[2].copyE4)
    XCTAssertFalse(comparison.isIdentical)
  }

  func testCategoriesAreCountedAndTheAddedAndGoneAreNamed() {
    let kept = UUID()
    let gone = UUID()
    let added = UUID()
    let comparison = BackupComparison(
      copy: snapshot([], categories: [kept: "Food", gone: "Old"]),
      current: snapshot([], categories: [kept: "Food", added: "New"]))
    XCTAssertEqual(comparison.categoriesInCopy, 2)
    XCTAssertEqual(comparison.categoriesNow, 2)
    XCTAssertEqual(comparison.categoriesAdded, ["New"])
    XCTAssertEqual(comparison.categoriesVanished, ["Old"])
  }

  func testTheListsRunNewestFirst() {
    let older = operation(day: 1)
    let newer = operation(day: 5)
    let comparison = BackupComparison(copy: snapshot([]), current: snapshot([older, newer]))
    XCTAssertEqual(comparison.added.map(\.id), [newer.id, older.id])
  }

  // MARK: Against real files

  /// A copy on disk against a database that moved on: one operation added, one deleted, one
  /// edited — and neither the copy nor the database is written by the comparison.
  func testAFileCopyAgainstTheLiveDatabaseAndNothingIsWritten() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-compare-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    defer { try? stack.close() }
    let repository = TransactionRepository(writer: stack.writer)
    var saved: [TransactionEntry] = []
    for (index, note) in ["rent", "coffee", "taxi"].enumerated() {
      var draft = TransactionDraft(
        occurredAt: Date(timeIntervalSince1970: Double(1_790_000_000 + index * 3_600)),
        amount: AmountE4(whole: Int64(100 * (index + 1))), note: note)
      draft.normalizeSinglePart()
      saved.append(try repository.save(try draft.materialize()))
    }
    let copy = directory.appendingPathComponent("copy.sqlite")
    try stack.backup(to: copy)
    let before = try Data(contentsOf: copy)

    var edited = saved[0]
    edited.transaction.amountE4 = AmountE4(whole: 999)
    edited.parts[0].amountE4 = AmountE4(whole: 999)
    edited.parts[0].amountRubE4 = AmountE4(whole: 999)
    edited.transaction.amountRubE4 = AmountE4(whole: 999)
    _ = try repository.save(edited)
    _ = try repository.softDelete(id: saved[1].id)
    var added = TransactionDraft(
      occurredAt: Date(timeIntervalSince1970: 1_790_100_000), amount: AmountE4(whole: 7),
      note: "new")
    added.normalizeSinglePart()
    let newEntry = try repository.save(try added.materialize())

    let current = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let comparison = try BackupComparison.of(copyAt: copy, with: current)

    XCTAssertEqual(comparison.operationsInCopy, 3)
    XCTAssertEqual(comparison.operationsNow, 3)
    XCTAssertEqual(comparison.added.map(\.id), [newEntry.id])
    XCTAssertEqual(comparison.vanished.map(\.id), [saved[1].id])
    XCTAssertEqual(comparison.changed.map(\.now.id), [saved[0].id])
    XCTAssertEqual(comparison.changed.first?.was.amountE4, AmountE4(whole: 100).raw)
    XCTAssertEqual(comparison.changed.first?.now.amountE4, AmountE4(whole: 999).raw)
    // Read, not written: the file of the copy is byte for byte what it was.
    XCTAssertEqual(try Data(contentsOf: copy), before)
    XCTAssertEqual(try Data(contentsOf: copy).count, before.count)
  }

  /// Every text of the list and the comparison exists in Russian and in English.
  func testTheTextsOfTheListAndTheComparisonAreInBothLanguages() throws {
    let keys = [
      "backups.summary", "backups.row.operations", "backups.row.last",
      "backups.row.noDescription", "backups.row.describe", "backups.row.compare",
      "backups.row.showInFinder", "backups.compare.title", "backups.compare.failed",
      "backups.compare.identical", "backups.compare.operations", "backups.compare.categories",
      "backups.compare.categoriesAdded", "backups.compare.categoriesVanished",
      "backups.compare.balances", "backups.compare.added", "backups.compare.vanished",
      "backups.compare.changed", "backups.compare.more",
    ]
    for language in ["ru", "en"] {
      let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
      let bundle = try XCTUnwrap(Bundle(path: path))
      for key in keys {
        let text = bundle.localizedString(forKey: key, value: key, table: "Settings")
        XCTAssertNotEqual(text, key, "\(key) in \(language)")
      }
    }
    let russian = try XCTUnwrap(
      Bundle(path: try XCTUnwrap(Bundle.main.path(forResource: "ru", ofType: "lproj"))))
    XCTAssertEqual(
      russian.localizedString(forKey: "backups.compare.changed", value: nil, table: "Settings"),
      "изменено %lld")
  }
}
