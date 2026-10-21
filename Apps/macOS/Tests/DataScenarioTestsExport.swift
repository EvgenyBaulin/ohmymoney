import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The CSV export of the File menu into a folder of the owner's: a fresh folder, a folder with an
/// earlier export, a folder where one name is the owner's own folder, an empty database. Every
/// file reads back in the reader of the app, and the folder is either whole or as it was.
final class DataScenarioCSVExportTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private var service: CSVExportService!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-f-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    service = CSVExportService(repository: ExportRepository(writer: stack.writer))
  }

  override func tearDownWithError() throws {
    service = nil
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private var target: URL { directory.appendingPathComponent("export", isDirectory: true) }

  private func save(_ raw: Int64, note: String, kind: TransactionKind = .expense) throws {
    var draft = TransactionDraft(kind: kind, amount: AmountE4(raw: raw), note: note)
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
  }

  private func rows(_ file: String) throws -> [[String: String]] {
    try CSVReader.dictionaries(from: Data(contentsOf: target.appendingPathComponent(file)))
  }

  func testAnEmptyDatabaseWritesEveryFileWithItsHeader() throws {
    let written = try service.export(to: target)
    XCTAssertEqual(written.count, ExportTables.all.count)
    for table in ExportTables.all {
      let data = try Data(contentsOf: target.appendingPathComponent(table.fileName))
      XCTAssertEqual(try CSVReader.rows(from: data).first, table.columns, table.fileName)
    }
  }

  /// No byte-order mark, a line feed at the end of every file, no `_e4` in any header.
  func testEveryFileIsPlainUTF8WithoutE4Columns() throws {
    try save(12_345, note: "чай")
    for url in try service.export(to: target) {
      let data = try Data(contentsOf: url)
      XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]), url.lastPathComponent)
      XCTAssertEqual(data.last, 0x0A, url.lastPathComponent)
      let header = try XCTUnwrap(try CSVReader.rows(from: data).first)
      XCTAssertFalse(header.contains { $0.hasSuffix("_e4") }, url.lastPathComponent)
    }
  }

  /// Amounts are decimal strings with a dot and no more digits than they have.
  func testAmountsAreDecimalStrings() throws {
    try save(12_345, note: "a")
    try save(10_000_000, note: "b")
    try save(1, note: "c")
    _ = try service.export(to: target)
    let amounts = Set(try rows("transactions.csv").compactMap { $0["amount"] })
    XCTAssertEqual(amounts, ["1.2345", "1000", "0.0001"])
  }

  /// A note of every awkward kind comes back from the file as it was written.
  func testAwkwardNotesComeBackFromTheFile() throws {
    let notes = [
      "comma, inside", "quote \"inside\"", "line\nfeed", "carriage\r\nreturn", "😀",
      "е\u{0308}лка", "=1+1", "",
    ]
    for (index, note) in notes.enumerated() { try save(Int64(index + 1) * 10_000, note: note) }
    _ = try service.export(to: target)
    let read = try rows("transactions.csv").compactMap { $0["note"] }
    XCTAssertEqual(Set(read), Set(notes))
  }

  /// A second export replaces the files of the first.
  func testASecondExportReplacesTheFirst() throws {
    try save(10_000, note: "first")
    _ = try service.export(to: target)
    try save(20_000, note: "second")
    _ = try service.export(to: target)
    XCTAssertEqual(try rows("transactions.csv").count, 2)
    let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
    XCTAssertEqual(names.count, ExportTables.all.count, "a hidden folder was left: \(names)")
  }

  /// A folder of the owner's under the name of a file stops the export; the files of an earlier
  /// export are as they were, and the owner's folder too.
  func testAFolderOfTheOwnersStopsTheExportAndChangesNothing() throws {
    try save(10_000, note: "earlier")
    _ = try service.export(to: target)
    let before = try Data(contentsOf: target.appendingPathComponent("transactions.csv"))
    let owners = target.appendingPathComponent("settings.csv", isDirectory: true)
    try FileManager.default.removeItem(at: owners)
    try FileManager.default.createDirectory(at: owners, withIntermediateDirectories: false)
    try Data("mine".utf8).write(to: owners.appendingPathComponent("note.txt"))
    try save(20_000, note: "later")

    XCTAssertThrowsError(try service.export(to: target))
    XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("transactions.csv")), before)
    XCTAssertEqual(
      try String(contentsOf: owners.appendingPathComponent("note.txt"), encoding: .utf8), "mine")
    let hidden = try FileManager.default.contentsOfDirectory(atPath: target.path)
      .filter { $0.hasPrefix(".ohmymoney-export-") }
    XCTAssertEqual(hidden, [])
  }

  /// The question before replacing names only files of the export that are there as files.
  func testTheFilesItWouldReplace() throws {
    XCTAssertEqual(service.filesItWouldReplace(in: target), [])
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: target.appendingPathComponent("people.csv"))
    try Data("x".utf8).write(to: target.appendingPathComponent("my-notes.csv"))
    try FileManager.default.createDirectory(
      at: target.appendingPathComponent("places.csv"), withIntermediateDirectories: true)
    XCTAssertEqual(service.filesItWouldReplace(in: target), ["people.csv"])
  }

  /// The files of an export sit beside the owner's own, which stay.
  func testTheOwnersOtherFilesStay() throws {
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("mine".utf8).write(to: target.appendingPathComponent("budget-2025.numbers"))
    _ = try service.export(to: target)
    let mine = target.appendingPathComponent("budget-2025.numbers")
    XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path))
  }

  /// The counts the File menu reports are the rows of the files written.
  func testTheCountsAreTheRowsOfTheFiles() throws {
    for index in 0..<5 { try save(Int64(index + 1) * 10_000, note: "row") }
    let counts = try service.rowCounts()
    XCTAssertEqual(counts["transactions"], 5)
    XCTAssertEqual(counts["transaction_parts"], 5)
    let tables = try service.tables()
    let transactions = try XCTUnwrap(tables.first { $0.name == "transactions" })
    XCTAssertEqual(ArchiveOpener.countCSVRows(transactions.data), 5)
  }

  /// Income and expense are told by the kind, never by a sign: every amount is above zero.
  func testTheKindNotTheSignTellsIncomeFromExpense() throws {
    try save(50_000, note: "salary", kind: .income)
    try save(30_000, note: "lunch")
    _ = try service.export(to: target)
    let read = try rows("transactions.csv")
    XCTAssertEqual(Set(read.compactMap { $0["kind"] }), ["income", "expense"])
    XCTAssertTrue(read.allSatisfy { !($0["amount"] ?? "-").hasPrefix("-") })
  }
}

/// The CSV of the app read and written at its edges: line endings of every tool, a byte-order
/// mark, quotes, blank lines, a row of the wrong length, a header naming a column twice, bytes
/// that are not UTF-8; and the values of dates, instants and amounts written for pandas.
final class DataScenarioCSVFormatTests: XCTestCase {
  func testEveryLineEndingReadsTheSame() throws {
    let lf = try CSVReader.rows(from: Data("a,b\n1,2\n".utf8))
    XCTAssertEqual(try CSVReader.rows(from: Data("a,b\r\n1,2\r\n".utf8)), lf)
    XCTAssertEqual(try CSVReader.rows(from: Data("a,b\r1,2\r".utf8)), lf)
    XCTAssertEqual(try CSVReader.rows(from: Data("a,b\n1,2".utf8)), lf)
  }

  func testAByteOrderMarkOfNumbersIsSkippedOnce() throws {
    let marked = Data([0xEF, 0xBB, 0xBF]) + Data("name\nЧай\n".utf8)
    XCTAssertEqual(try CSVReader.rows(from: marked), [["name"], ["Чай"]])
  }

  func testBlankLinesAreNoRecordsButAQuotedEmptyFieldIs() throws {
    XCTAssertEqual(try CSVReader.rows(from: Data("a\n\n1\n\n".utf8)), [["a"], ["1"]])
    XCTAssertEqual(try CSVReader.rows(from: Data("a\n\"\"\n".utf8)), [["a"], [""]])
  }

  func testARowOfTheWrongLengthIsNamed() {
    XCTAssertThrowsError(try CSVReader.dictionaries(from: Data("a,b\n1,2\n3\n".utf8))) {
      XCTAssertEqual($0 as? CSVError, .columnCountMismatch(expected: 2, found: 1, row: 1))
    }
  }

  func testAColumnNamedTwiceIsRefused() {
    XCTAssertThrowsError(try CSVReader.dictionaries(from: Data("id,id\n1,2\n".utf8))) {
      XCTAssertEqual($0 as? CSVError, .duplicateColumn(name: "id"))
    }
  }

  func testBytesThatAreNotUTF8AreRefused() {
    let cp1251 = "Чай".data(using: .windowsCP1251)!
    XCTAssertThrowsError(try CSVReader.rows(from: Data("a\n".utf8) + cp1251)) {
      XCTAssertEqual($0 as? CSVError, .invalidEncoding)
    }
  }

  func testAnEmptyFileHasNoRows() throws {
    XCTAssertEqual(try CSVReader.rows(from: Data()), [])
    XCTAssertEqual(try CSVReader.dictionaries(from: Data()), [])
  }

  /// What the writer writes the reader reads back, whatever the field holds.
  func testWrittenFieldsReadBackAsTheyWere() throws {
    let fields = [
      ["", "plain", "a,b", "\"", "x\ny", "x\r\ny", "\r", "е\u{0308}", ",\u{0301}", "  ", "🙂,🙃"]
    ]
    var writer = CSVWriter(columns: (0..<fields[0].count).map { "c\($0)" })
    for row in fields { writer.append(row) }
    let read = try CSVReader.rows(from: writer.data())
    XCTAssertEqual(Array(read.dropFirst()), fields)
  }

  /// A row of one empty field is written quoted, so it is not taken for a blank line.
  func testARowOfOneEmptyFieldSurvives() throws {
    var writer = CSVWriter(columns: ["note"])
    writer.append([""])
    writer.append(["x"])
    XCTAssertEqual(try CSVReader.rows(from: writer.data()), [["note"], [""], ["x"]])
  }

  func testAmountsAreWrittenPlain() {
    XCTAssertEqual(CSVValue.string(amount: AmountE4(raw: 12_345)), "1.2345")
    XCTAssertEqual(CSVValue.string(amount: AmountE4(raw: -5_000)), "-0.5")
    XCTAssertEqual(CSVValue.string(amount: AmountE4(whole: 1_000_000)), "1000000")
    XCTAssertEqual(CSVValue.string(amount: AmountE4(raw: 0)), "0")
    XCTAssertEqual(CSVValue.string(amount: nil as AmountE4?), "")
  }

  func testBooleansAreWordsAndNothingIsEmpty() {
    XCTAssertEqual(CSVValue.string(bool: true), "true")
    XCTAssertEqual(CSVValue.string(bool: false), "false")
    XCTAssertEqual(CSVValue.string(bool: nil as Bool?), "")
    XCTAssertEqual(CSVValue.string(nil as UUID?), "")
  }

  func testDaysAndMonthsAreISO() {
    XCTAssertEqual(CSVValue.string(day: DateOnly(year: 2028, month: 2, day: 29)), "2028-02-29")
    XCTAssertEqual(CSVValue.string(month: MonthKey(year: 2026, month: 1)), "2026-01")
  }

  /// An instant is UTC to the second, the last second of a year included, and reads back.
  func testInstantsAreUTCAndReadBack() {
    let last = Date(timeIntervalSince1970: 1_798_761_599)
    XCTAssertEqual(CSVValue.string(instant: last), "2026-12-31T23:59:59Z")
    XCTAssertEqual(CSVValue.instant("2026-12-31T23:59:59Z"), last)
    let leap = Date(timeIntervalSince1970: 1_835_395_200)
    XCTAssertEqual(CSVValue.string(instant: leap), "2028-02-29T00:00:00Z")
    XCTAssertEqual(CSVValue.instant(CSVValue.string(instant: leap)), leap)
  }

  func testWhatIsNoInstantReadsAsNone() {
    for text in [
      "", "2026-12-31", "2026-12-31 23:59:59Z", "2026-13-01T00:00:00Z", "2026-12-31T24:00:00Z",
      "2026-12-31T23:59:59+03:00", "abcd-ef-ghTij:kl:mnZ",
    ] {
      XCTAssertNil(CSVValue.instant(text), text)
    }
  }

  func testRowsAreCountedNotLines() {
    XCTAssertEqual(ArchiveOpener.countCSVRows(Data("a\n1\n2\n".utf8)), 2)
    XCTAssertEqual(ArchiveOpener.countCSVRows(Data("a\n\"x\ny\"\n".utf8)), 1)
    XCTAssertEqual(ArchiveOpener.countCSVRows(Data("a\n".utf8)), 0)
  }
}

/// The values a line of the journal may carry: our own short words, counts, ids — and nothing
/// that could be a note, a name, a place or an amount, whichever way it is handed in.
final class DataScenarioLogValueTests: XCTestCase {
  private let secrets = [
    "Кофе с булочкой", "Александра", "Пятёрочка на Невском", "12 345,67", "12345.67 ₽",
    "/Users/someone/Library/finance.sqlite", "a note with spaces", "",
    String(repeating: "a", count: 25),
  ]

  func testNoSecretPassesForAToken() {
    for secret in secrets {
      XCTAssertEqual(LogValue.token(secret).text, "<not-a-token>", secret)
    }
  }

  func testNoSecretPassesForAVersionOrAFile() {
    for secret in secrets where secret != "a note with spaces" {
      XCTAssertNotEqual(LogValue.version(secret).text, secret, secret)
    }
    for secret in ["Кофе", "a b", "~/x", "x:y", String(repeating: "f", count: 65)] {
      XCTAssertEqual(LogValue.file(secret).text, "<not-a-file>", secret)
    }
  }

  func testOurOwnWordsPass() {
    for word in ["backup.started", "before-restore", "official", "2026-10-14", "csv/a_b"] {
      XCTAssertEqual(LogValue.token(word).text, word)
    }
    XCTAssertEqual(LogValue.version("macOS 26.0").text, "macOS 26.0")
    let copy = "finance-2026-10-14T101500+0300.sqlite"
    XCTAssertEqual(LogValue.file(copy).text, copy)
  }

  func testNumbersAreWrittenWithTheirUnit() {
    XCTAssertEqual(LogValue.count(-3).text, "-3")
    XCTAssertEqual(LogValue.bytes(2_048).text, "2048b")
    XCTAssertEqual(LogValue.milliseconds(15).text, "15ms")
    XCTAssertEqual(LogValue.flag(true).text, "yes")
    XCTAssertEqual(LogValue.flag(false).text, "no")
  }

  /// An error is written by its type, never by what it says: a description may quote a path or
  /// the owner's note.
  func testAnErrorIsWrittenByItsTypeOnly() {
    struct NoteError: Error, CustomStringConvertible {
      var description: String { "Кофе с булочкой 12 345,67" }
    }
    XCTAssertEqual(LogValue.error(NoteError()).text, "NoteError")
    XCTAssertEqual(LogValue.error(RateFetchError.unavailable(status: 503)).text, "RateFetchError")
    // A Foundation error arrives bridged: its type, never its path or its words.
    let bridged = LogValue.error(
      CocoaError(
        .fileNoSuchFile,
        userInfo: [
          NSFilePathErrorKey: "/Users/someone/finance.sqlite"
        ])
    ).text
    XCTAssertEqual(bridged, "NSError")
  }

  func testAKeyThatIsNoTokenIsHidden() {
    XCTAssertEqual(LogPair("сумма", .count(1)).text, "<not-a-key>=1")
    XCTAssertEqual(LogPair("copies", .count(3)).text, "copies=3")
  }
}
