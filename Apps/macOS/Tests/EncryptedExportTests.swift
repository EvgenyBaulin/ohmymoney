import AppCore
import CoreKit
import XCTest

@testable import OhMyMoney

/// «Зашифровать» of the exports of a table — «Отчёты», «Итог поездки», «Банкам за год»: the box
/// is on every time, a locked file opens with its password and with nothing else, and a box taken
/// off leaves the CSV exactly as it was before the box existed.
final class EncryptedExportTests: XCTestCase {
  /// Few rounds keep the test fast; the derivation is the same code at any count.
  private let rounds = 1_000
  private let cipher = CryptoKitArchiveCipher()

  private let byDay = PersonalDataExport.File(
    name: "trip-turkey-by-day.csv", data: Data("row_type,name\nitem,2026-10-06\n".utf8))
  private let byCategory = PersonalDataExport.File(
    name: "trip-turkey-by-category.csv", data: Data("row_type,name\nitem,Еда\n".utf8))

  // MARK: The form

  func testTheBoxIsOnByDefault() {
    let form = EncryptedExportForm()
    XCTAssertTrue(form.encrypt, "every export starts locked")
    XCTAssertEqual(form.password, "")
    XCTAssertEqual(form.confirmation, "")
  }

  func testAnEmptyPasswordIsRefused() {
    var form = EncryptedExportForm()
    XCTAssertEqual(form.problem, .passwordEmpty)
    XCTAssertNil(form.answer, "no answer while the password is empty")
    form.confirmation = "secret"
    XCTAssertEqual(form.problem, .passwordEmpty)
    XCTAssertNil(form.answer)
  }

  func testTwoDifferentPasswordsAreRefused() {
    var form = EncryptedExportForm()
    form.password = "secret"
    form.confirmation = "secreT"
    XCTAssertEqual(form.problem, .passwordMismatch)
    XCTAssertNil(form.answer)
  }

  func testTheSamePasswordTwiceLocksTheFile() {
    var form = EncryptedExportForm()
    form.password = "secret"
    form.confirmation = "secret"
    XCTAssertNil(form.problem)
    XCTAssertEqual(form.answer, .locked(password: "secret"))
  }

  /// The key is derived from the NFC form, so «ё» typed as one letter or as «е» with its mark is
  /// one password, and the two fields agree.
  func testCanonicallyEqualPasswordsAgree() {
    var form = EncryptedExportForm()
    form.password = "\u{0451}лка"
    form.confirmation = "\u{0435}\u{0308}лка"
    XCTAssertNil(form.problem)
  }

  func testABoxTakenOffAsksForNoPassword() {
    var form = EncryptedExportForm()
    form.encrypt = false
    XCTAssertNil(form.problem)
    XCTAssertEqual(form.answer, .plain)
  }

  func testEmptyFieldsAreNotScoldedBeforeTyping() {
    var form = EncryptedExportForm()
    XCTAssertNil(form.problemShown())
    form.password = "a"
    XCTAssertEqual(form.problemShown(), .passwordMismatch)
  }

  func testTheProblemsHaveWordsInBothLanguages() {
    for problem in [EncryptedExportForm.Problem.passwordEmpty, .passwordMismatch] {
      for language in ["ru", "en"] {
        let text = Self.text(problem.messageKey, table: "PrivacyExport", language: language)
        XCTAssertNotEqual(text, problem.messageKey, "\(problem) has no \(language) words")
      }
    }
  }

  func testTheBoxHasWordsInBothLanguages() {
    XCTAssertEqual(
      Self.text(EncryptedExportForm.boxKey, table: "Reports", language: "ru"), "Зашифровать")
    XCTAssertEqual(
      Self.text(EncryptedExportForm.boxKey, table: "Reports", language: "en"), "Encrypt")
  }

  func testForgettingThePasswordLeavesNothingBehind() {
    var form = EncryptedExportForm()
    form.password = "secret"
    form.confirmation = "secret"
    form.encrypt = false
    form.reset()
    XCTAssertEqual(form, EncryptedExportForm(), "the next export starts locked and empty")
  }

  // MARK: The locked file

  func testALockedFileOpensWithItsPasswordOnly() throws {
    let data = try EncryptedExport.lockedData(
      [byDay, byCategory], password: "secret", appVersion: "2.6.1", schemaVersion: 19,
      cipher: cipher, iterations: rounds)

    XCTAssertTrue(ArchiveOpener.isEncrypted(data), "the file starts with the locked header")
    XCTAssertEqual(try EncryptionHeader.decode(data).iterations, rounds, "the rounds asked for")
    XCTAssertNil(
      data.range(of: Data("Еда".utf8)), "no word of the tables lies in the open")

    let back = try EncryptedExport.read(data, password: "secret", schemaVersion: 19, cipher: cipher)
    XCTAssertEqual(back.sorted { $0.name < $1.name }, [byCategory, byDay])

    XCTAssertThrowsError(
      try EncryptedExport.read(data, password: "other", schemaVersion: 19, cipher: cipher),
      "a stranger's password does not open it")
    XCTAssertThrowsError(
      try ArchiveOpener.open(data, supportedSchemaVersion: 20), "without a password it is shut")
  }

  func testOneTableGoesInUnderItsOwnName() throws {
    let csv = Data("month,fees_rub\n2026-01,100\n".utf8)
    let file = PersonalDataExport.File(name: "bank-fees-2026.csv", data: csv)
    let data = try EncryptedExport.lockedData(
      [file], password: "secret", appVersion: "2.6.1", schemaVersion: 19, cipher: cipher,
      iterations: rounds)
    let opened = try ArchiveOpener.open(
      data, password: "secret", cipher: cipher, supportedSchemaVersion: 20)
    XCTAssertEqual(opened.csvTables, ["bank-fees-2026"], "no «.csv.csv» inside")
    XCTAssertEqual(opened.csv(table: "bank-fees-2026"), csv, "the same bytes as the plain CSV")
  }

  func testAnEmptyPasswordLocksNothing() {
    XCTAssertThrowsError(
      try EncryptedExport.lockedData(
        [byDay], password: "", appVersion: "2.6.1", schemaVersion: 19, cipher: cipher,
        iterations: rounds)
    ) { error in
      XCTAssertEqual(error as? EncryptedExport.Failure, .passwordMissing)
    }
  }

  func testTheFileOnDiskIsReadBackBeforeItIsDone() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("encrypted-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent(EncryptedExport.fileName("trip-turkey"))
    XCTAssertEqual(url.pathExtension, ArchiveService.fileExtension)

    try EncryptedExport.write(
      [byDay, byCategory], password: "secret", to: url, appVersion: "2.6.1", schemaVersion: 19,
      cipher: cipher, iterations: rounds)

    let back = try EncryptedExport.read(
      try Data(contentsOf: url), password: "secret", schemaVersion: 19, cipher: cipher)
    XCTAssertEqual(Set(back.map(\.name)), [byDay.name, byCategory.name])
  }

  // MARK: What the exporter is handed

  func testABoxTakenOffHandsOverTheSameCSV() async throws {
    let export = PersonalDataExport(defaultName: "bank-fees-2026", files: [byDay])
    let prepared = try await export.prepared(
      for: .plain, appVersion: "2.6.1", schemaVersion: 19, cipher: cipher, iterations: rounds)
    XCTAssertEqual(prepared.contentType, .commaSeparatedText)
    XCTAssertEqual(prepared.defaultName, "bank-fees-2026")
    XCTAssertEqual(prepared.document.payload, .plain(export), "the CSV as it always was")
  }

  func testABoxTakenOffHandsOverTheSameFolder() async throws {
    let export = PersonalDataExport(defaultName: "trip-turkey", files: [byDay, byCategory])
    let prepared = try await export.prepared(
      for: .plain, appVersion: "2.6.1", schemaVersion: 19, cipher: cipher, iterations: rounds)
    XCTAssertEqual(prepared.contentType, .folder)
    XCTAssertEqual(prepared.document.payload, .plain(export))
  }

  func testATickedBoxHandsOverOneLockedFile() async throws {
    let export = PersonalDataExport(defaultName: "trip-turkey", files: [byDay, byCategory])
    let prepared = try await export.prepared(
      for: .locked(password: "secret"), appVersion: "2.6.1", schemaVersion: 19, cipher: cipher,
      iterations: rounds)
    XCTAssertEqual(prepared.contentType, EncryptedExport.contentType)
    XCTAssertEqual(prepared.defaultName, "trip-turkey")
    guard case .locked(let data) = prepared.document.payload else {
      return XCTFail("a locked file was expected")
    }
    let back = try EncryptedExport.read(data, password: "secret", schemaVersion: 19, cipher: cipher)
    XCTAssertEqual(Set(back.map(\.name)), [byDay.name, byCategory.name])
  }

  func testTheLockedTypeCarriesTheExtensionOfACopy() {
    XCTAssertEqual(
      EncryptedExport.contentType.preferredFilenameExtension, ArchiveService.fileExtension)
  }

  // MARK: Helpers

  private static func text(_ key: String, table: String, language: String) -> String {
    guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else { return key }
    return bundle.localizedString(forKey: key, value: key, table: table)
  }
}
