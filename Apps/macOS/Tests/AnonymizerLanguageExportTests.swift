import AppCore
import AppDatabase
import CoreKit
import GRDB
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The neutral words of an anonymized «Экспорт копии» are in the language of the interface:
/// «Счёт 1» in Russian, «Account 1» in English. The words of a way to replace names handed in by
/// a caller are its own.
final class AnonymizerLanguageExportTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private let cipher = CryptoKitArchiveCipher()

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-copy-language-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    try references.save(PaymentMethod(name: "Дебетовая", isDefault: true))
    try references.save(Person(name: "Маша"))
    try references.save(Place(name: "Кофейня у дома"))
  }

  override func tearDownWithError() throws {
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func copy(english: Bool) throws -> Dataset {
    let service = ExportCopyService(
      stack: stack, appVersion: "2.6.1", cipher: cipher, iterations: 1_000)
    let target = directory.appendingPathComponent("copy-\(english).ohmymoneyarchive")
    let report = try service.export(
      ExportCopyRequest(anonymize: true, password: "correct horse"), to: target,
      english: english)
    let opened = try ArchiveOpener.open(
      try Data(contentsOf: report.url), password: "correct horse", cipher: cipher,
      supportedSchemaVersion: stack.applied.onDisk)
    let file = directory.appendingPathComponent("opened-\(english).sqlite")
    try XCTUnwrap(opened.database).write(to: file)
    return try DatabaseStack.dataset(fileAt: file)
  }

  func testMigrationMemoriesAreAbsentFromAnonymizedDatabaseAndArchiveSettings() throws {
    let memories = [
      MigrationSettings.accountMapKey: MigrationSettings.text(["sample visa 4276": UUID()]),
      MigrationSettings.categoryMapKey: MigrationSettings.text(["expense|sample|cafe": UUID()]),
      MigrationSettings.mappingsKey: MigrationSettings.text([
        "sample layout": MigrationMapping(roles: [0: .date, 1: .amount])
      ]),
    ]
    try stack.writer.write { db in
      for (key, value) in memories {
        try db.execute(
          sql: "INSERT INTO settings (key, value) VALUES (?, ?)", arguments: [key, value])
      }
    }
    let service = ExportCopyService(
      stack: stack, appVersion: "2.6.1", cipher: cipher, iterations: 1_000)
    let target = directory.appendingPathComponent("migration.ohmymoneyarchive")
    _ = try service.export(
      ExportCopyRequest(anonymize: true, password: "correct horse"), to: target,
      settings: ["theme.scheme": "dark"])
    let opened = try ArchiveOpener.open(
      Data(contentsOf: target), password: "correct horse", cipher: cipher,
      supportedSchemaVersion: stack.applied.onDisk)
    let settings = try XCTUnwrap(opened.settings)
    let portable = try XCTUnwrap(
      JSONSerialization.jsonObject(with: settings) as? [String: String])
    XCTAssertEqual(portable["theme.scheme"], "dark")
    let file = directory.appendingPathComponent("migration-copy.sqlite")
    try XCTUnwrap(opened.database).write(to: file)
    let copy = try DatabaseQueue(path: file.path)
    for key in memories.keys {
      XCTAssertNil(portable[key])
      let copied = try copy.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
      }
      XCTAssertNil(copied)
      let original = try stack.writer.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
      }
      XCTAssertEqual(original, memories[key])
    }
  }

  func testAnEnglishInterfaceGetsEnglishWords() throws {
    let data = try copy(english: true)
    XCTAssertEqual(data.paymentMethods.map(\.name), ["Account 1"])
    XCTAssertEqual(data.people.map(\.name), ["Person 1"])
    XCTAssertEqual(data.places.map(\.name), ["Place 1"])
  }

  func testARussianInterfaceGetsRussianWords() throws {
    let data = try copy(english: false)
    XCTAssertEqual(data.paymentMethods.map(\.name), ["Счёт 1"])
    XCTAssertEqual(data.people.map(\.name), ["Человек 1"])
    XCTAssertEqual(data.places.map(\.name), ["Место 1"])
  }

  func testTheLanguageCodeOfTheInterfacePicksTheWords() {
    XCTAssertTrue(ExportCopyModel.isEnglish("en"))
    XCTAssertFalse(ExportCopyModel.isEnglish("ru"))
  }

  /// A way to replace names that a caller handed in is used as it is, whatever the language.
  func testAnAnonymizerHandedInIsNotReplaced() {
    struct Spy: ExportCopyAnonymizing {
      func anonymize(copy: ExportCopyDatabase) throws {}
    }
    let service = ExportCopyService(
      stack: stack, appVersion: "2.6.1", cipher: cipher, iterations: 1_000, anonymizer: Spy())
    XCTAssertTrue(service.anonymizer(english: true) is Spy)
    XCTAssertTrue(service.anonymizer(english: false) is Spy)
    let own = ExportCopyService(stack: stack, appVersion: "2.6.1", cipher: cipher)
    XCTAssertTrue(own.anonymizer(english: true) is SQLAnonymizer)
  }
}
