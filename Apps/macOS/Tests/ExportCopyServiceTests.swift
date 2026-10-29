import AppCore
import AppDatabase
import CoreKit
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// «Экспорт копии»: a locked copy made from a copy of the data. The live database never changes;
/// the span of days, the hidden accounts and the names are cut or replaced in the copy only.
final class ExportCopyServiceTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private let shown = PaymentMethod(name: "Дебетовая", isDefault: true)
  private let other = PaymentMethod(name: "Запасная")
  private let hidden = PaymentMethod(name: "СекретныйСейф", hidden: true)
  private let cipher = CryptoKitArchiveCipher()

  private static func day(_ month: Int, _ day: Int) -> Date {
    CalendarContext.moscow.noon(of: DateOnly(year: 2026, month: month, day: day))
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-copy-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    try seed()
  }

  override func tearDownWithError() throws {
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func spend(
    on account: PaymentMethod, _ amount: Int64, month: Int, day: Int, note: String? = nil
  ) throws {
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: Self.day(month, day), amountE4: AmountE4(whole: amount),
      note: note, paymentMethodId: account.id)
    let part = TransactionPart(
      transactionId: transaction.id, amountE4: AmountE4(whole: amount))
    try TransactionRepository(writer: stack.writer).insert([
      TransactionEntry(transaction: transaction, parts: [part])
    ])
  }

  private func seed() throws {
    let references = ReferenceRepository(writer: stack.writer)
    for account in [shown, other, hidden] { try references.save(account) }
    try spend(on: shown, 100, month: 3, day: 10, note: "кофе")
    try spend(on: shown, 200, month: 9, day: 10)
    try spend(on: hidden, 300, month: 9, day: 11, note: "СекретнаяПокупка")
    try spend(on: other, 400, month: 9, day: 12)
    let planning = PlanningRepository(writer: stack.writer)
    let visibleTransfer = Transfer(
      occurredAt: Self.day(9, 13), fromAccountId: shown.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 50), toAccountId: other.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 50))
    let toHidden = Transfer(
      occurredAt: Self.day(9, 14), fromAccountId: shown.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 70), toAccountId: hidden.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 70))
    let early = Transfer(
      occurredAt: Self.day(3, 15), fromAccountId: shown.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 10), toAccountId: other.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 10))
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(transfers: [visibleTransfer, toHidden, early])))
  }

  private func service(anonymizer: (any ExportCopyAnonymizing)? = nil) -> ExportCopyService {
    ExportCopyService(
      stack: stack, appVersion: "2.6.0", cipher: cipher, iterations: 1_000, anonymizer: anonymizer)
  }

  /// Opens the copy with its password and returns what it holds.
  private func open(
    _ report: ExportCopyReport, password: String = "correct horse"
  ) throws
    -> (archive: ArchiveOpener.OpenedArchive, dataset: Dataset?)
  {
    let opened = try ArchiveOpener.open(
      try Data(contentsOf: report.url), password: password, cipher: cipher,
      supportedSchemaVersion: stack.applied.onDisk)
    guard let database = opened.database else { return (opened, nil) }
    let file = directory.appendingPathComponent("opened-\(UUID().uuidString).sqlite")
    try database.write(to: file)
    return (opened, try DatabaseStack.dataset(fileAt: file))
  }

  private func accountNames() throws -> [String] {
    try ReferenceRepository(writer: stack.writer).paymentMethods(includeArchived: true)
      .map(\.name).sorted()
  }

  private func liveCounts() throws -> [String: Int] {
    try ExportRepository(writer: stack.writer).rowCounts()
  }

  // MARK: Refusals

  func testACopyWithoutAPasswordIsNotMade() {
    let target = directory.appendingPathComponent("a.ohmymoneyarchive")
    XCTAssertThrowsError(try service().export(ExportCopyRequest(password: ""), to: target)) {
      XCTAssertEqual($0 as? ExportCopyError, .passwordMissing)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  func testNamesCannotBeReplacedWithoutAWayToReplaceThem() {
    let target = directory.appendingPathComponent("a.ohmymoneyarchive")
    let request = ExportCopyRequest(anonymize: true, password: "correct horse")
    XCTAssertThrowsError(try service().export(request, to: target)) {
      XCTAssertEqual($0 as? ExportCopyError, .anonymizerMissing)
    }
  }

  func testAnEmptySpanOfDaysIsRefused() {
    let target = directory.appendingPathComponent("a.ohmymoneyarchive")
    let range = DayRange(
      DateOnly(year: 2026, month: 9, day: 2), DateOnly(year: 2026, month: 9, day: 1))
    let request = ExportCopyRequest(scope: .period(range), password: "correct horse")
    XCTAssertThrowsError(try service().export(request, to: target)) {
      XCTAssertEqual($0 as? ExportCopyError, .periodEmpty)
    }
  }

  // MARK: The whole history

  func testTheWholeCopyOpensOnlyWithItsPasswordAndHoldsEverything() throws {
    let target = directory.appendingPathComponent("whole.ohmymoneyarchive")
    let report = try service().export(
      ExportCopyRequest(password: "correct horse"), to: target)
    XCTAssertTrue(report.encrypted)
    XCTAssertEqual(report.operationsLeftOut, 0)
    XCTAssertEqual(report.transfersLeftOut, 0)
    XCTAssertEqual(report.accountsLeftOut, 0)
    XCTAssertThrowsError(try open(report, password: "wrong")) {
      XCTAssertEqual($0 as? CoreError, .invalidArchive(reason: .wrongPassword))
    }
    let copy = try open(report)
    XCTAssertEqual(copy.dataset?.entries.count, 4)
    XCTAssertEqual(copy.dataset?.transfers.count, 3)
    XCTAssertEqual(copy.dataset?.paymentMethods.filter(\.hidden).count, 1, "the flag travels")
  }

  func testTheLiveDatabaseIsTheSameAfterEveryKindOfCopy() throws {
    let before = try liveCounts()
    let names = try accountNames()
    let range = DayRange(
      DateOnly(year: 2026, month: 9, day: 1), DateOnly(year: 2026, month: 9, day: 30))
    for (index, request) in [
      ExportCopyRequest(scope: .period(range), includeHidden: false, password: "correct horse"),
      ExportCopyRequest(includeHidden: false, includeAttachments: true, password: "correct horse"),
      ExportCopyRequest(includeHidden: false, password: "correct horse", format: .csvOnly),
    ].enumerated() {
      _ = try service().export(
        request, to: directory.appendingPathComponent("copy-\(index).ohmymoneyarchive"))
    }
    XCTAssertEqual(try liveCounts(), before, "no row of the live database was touched")
    XCTAssertEqual(try accountNames(), names)
  }

  // MARK: The hidden accounts

  func testWithoutTheHiddenAccountsNothingOfThemIsInTheCopy() throws {
    let target = directory.appendingPathComponent("visible.ohmymoneyarchive")
    let report = try service().export(
      ExportCopyRequest(includeHidden: false, password: "correct horse"), to: target)
    XCTAssertEqual(report.accountsLeftOut, 1)
    XCTAssertEqual(report.operationsLeftOut, 1)
    XCTAssertEqual(report.transfersLeftOut, 1, "the transfer to the hidden account goes too")
    let copy = try open(report)
    let dataset = try XCTUnwrap(copy.dataset)
    XCTAssertEqual(dataset.paymentMethods.map(\.name).sorted(), ["Дебетовая", "Запасная"])
    XCTAssertEqual(dataset.entries.count, 3)
    XCTAssertFalse(
      dataset.entries.contains { $0.transaction.paymentMethodId == hidden.id })
    XCTAssertEqual(dataset.transfers.count, 2)
    // Nothing deleted stays readable in a free page of the file or in a CSV file.
    let database = try XCTUnwrap(copy.archive.database)
    for secret in ["СекретныйСейф", "СекретнаяПокупка"] {
      XCTAssertNil(database.range(of: Data(secret.utf8)), "\(secret) is in the database file")
      for name in copy.archive.csvTables {
        XCTAssertNil(
          copy.archive.csv(table: name)?.range(of: Data(secret.utf8)), "\(secret) in \(name)")
      }
    }
  }

  func testWithTheHiddenAccountsTheyAreInTheCopyAsHidden() throws {
    let target = directory.appendingPathComponent("all.ohmymoneyarchive")
    let report = try service().export(
      ExportCopyRequest(includeHidden: true, password: "correct horse"), to: target)
    let dataset = try XCTUnwrap(try open(report).dataset)
    XCTAssertEqual(dataset.paymentMethods.first { $0.id == hidden.id }?.hidden, true)
    XCTAssertEqual(dataset.entries.count, 4)
  }

  // MARK: The span of days

  func testASpanOfDaysKeepsOnlyItsOperationsAndTransfers() throws {
    let range = DayRange(
      DateOnly(year: 2026, month: 9, day: 1), DateOnly(year: 2026, month: 9, day: 30))
    let target = directory.appendingPathComponent("september.ohmymoneyarchive")
    let report = try service().export(
      ExportCopyRequest(scope: .period(range), password: "correct horse"), to: target)
    XCTAssertEqual(report.operationsLeftOut, 1)
    XCTAssertEqual(report.transfersLeftOut, 1)
    let dataset = try XCTUnwrap(try open(report).dataset)
    XCTAssertEqual(dataset.entries.count, 3)
    XCTAssertTrue(
      dataset.entries.allSatisfy {
        range.contains(
          TravelDay.day(of: $0.transaction.occurredAt, zoneId: $0.transaction.timeZoneId))
      })
    XCTAssertEqual(dataset.transfers.count, 2)
    XCTAssertEqual(dataset.paymentMethods.count, 3, "the accounts are not cut by a span of days")
  }

  // MARK: The form

  func testCSVOnlyHasNoDatabaseAndCarriesTheHiddenColumn() throws {
    let target = directory.appendingPathComponent("csv.ohmymoneyarchive")
    let report = try service().export(
      ExportCopyRequest(password: "correct horse", format: .csvOnly), to: target)
    let copy = try open(report)
    XCTAssertNil(copy.archive.database)
    XCTAssertEqual(copy.archive.csvTables.count, 49)
    let header = try XCTUnwrap(copy.archive.csv(table: "payment_methods"))
    XCTAssertTrue(String(decoding: header, as: UTF8.self).hasPrefix("id,name,"))
    XCTAssertTrue(String(decoding: header, as: UTF8.self).contains(",hidden\n"))
  }

  // MARK: The names

  func testTheAnonymizerSeesTheCopyAndNotTheLiveDatabase() throws {
    struct Renamer: ExportCopyAnonymizing {
      func anonymize(copy: ExportCopyDatabase) throws {
        try copy.execute("UPDATE payment_methods SET name = 'Счёт ' || rowid")
      }
    }
    let target = directory.appendingPathComponent("names.ohmymoneyarchive")
    let report = try service(anonymizer: Renamer()).export(
      ExportCopyRequest(anonymize: true, password: "correct horse"), to: target)
    let copy = try open(report)
    let names = try XCTUnwrap(copy.dataset).paymentMethods.map(\.name)
    XCTAssertTrue(names.allSatisfy { $0.hasPrefix("Счёт ") })
    XCTAssertNil(try XCTUnwrap(copy.archive.database).range(of: Data("СекретныйСейф".utf8)))
    XCTAssertEqual(try accountNames(), ["Дебетовая", "Запасная", "СекретныйСейф"])
  }
}
