import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Step 4 on disk: the model file in the models folder and the row of `ml_models` that
/// points at it («Модель — в `models/`, метаданные — в `ml_models`. Загружать только свои
/// файлы с проверкой контрольной суммы»).
final class CategoryModelServiceTests: XCTestCase {
  private var stack: DatabaseStack!
  private var folder: URL!
  private var logs: URL!

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let temporary = FileManager.default.temporaryDirectory
    folder = temporary.appendingPathComponent(
      "ohmymoney-models-\(UUID().uuidString)", isDirectory: true)
    logs = temporary.appendingPathComponent(
      "ohmymoney-model-log-\(UUID().uuidString)", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
  }

  override func tearDown() async throws {
    Logbook.shared.close()
    try? FileManager.default.removeItem(at: folder)
    try? FileManager.default.removeItem(at: logs)
  }

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }
  private let trainedAt = Date(timeIntervalSince1970: 1_790_000_000)
  private let groceries = UUID()
  private let transport = UUID()

  private func service(in directory: URL? = nil) -> CategoryModelService {
    CategoryModelService(
      box: CategoryModelBox(), models: ModelRepository(writer: stack.writer),
      directory: directory ?? folder)
  }

  private func examples() -> [CategoryExample] {
    [("milk", groceries, 300), ("bread", groceries, 120), ("taxi", transport, 900)]
      .enumerated()
      .map { index, example in
        let day = DateOnly(year: 2026, month: 9, day: 10 + index)
        return CategoryExample(
          query: CategoryQuery(
            day: day, weekday: 1 + index, kind: .expense, text: example.0,
            amountWhole: Int64(example.2)),
          partId: UUID(), categoryId: example.1)
      }
  }

  private var fileURL: URL { folder.appendingPathComponent(CategoryModelService.fileName) }

  /// The lines of the journal named `name`, waiting a little: `AppLog` hands every line to
  /// the journal on a task of its own.
  private func journal(_ name: String, atLeast count: Int = 1) async throws -> [String] {
    var lines: [String] = []
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      lines = Logbook.shared.lines().filter { $0.contains(" \(name) ") }
      if lines.count >= count { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    return lines
  }

  /// «A model larger than this is not one of ours, and is not read into memory to find out»
  /// (`CategoryModelFile.maximumBytes`). The size is asked before anything is read: a file
  /// that was read — and hashed — first would be refused for its checksum instead.
  func testAFileLargerThanAModelCanBeIsRefusedBeforeItIsRead() async throws {
    let examples = examples()
    XCTAssertTrue(service().refresh(examples: examples, anchor: today, now: trainedAt).retrained)

    // Something else put a file of more than 16 MiB where the model was.
    try FileManager.default.removeItem(at: fileURL)
    XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.truncate(atOffset: UInt64(CategoryModelFile.maximumBytes + 1))
    try handle.close()

    let result = service().refresh(examples: examples, anchor: today, now: trainedAt)

    XCTAssertTrue(result.retrained, "a refused file means training again")
    let rejected = try await journal("model.rejected")
    XCTAssertEqual(rejected.count, 1)
    XCTAssertTrue(
      rejected.first?.contains("reason=tooLarge") ?? false, rejected.first ?? "no line")
    // Training again wrote a model of the right size back in its place.
    let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int
    XCTAssertLessThan(size ?? .max, CategoryModelFile.maximumBytes)
  }

  /// A models folder nobody may write to means training again on every run; the journal says
  /// why, or the owner's report shows the same training over and over with no reason.
  func testAModelThatCouldNotBeWrittenSaysSoInTheJournal() async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }

    let result = service().refresh(examples: examples(), anchor: today, now: trainedAt)

    XCTAssertTrue(result.retrained)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    let failed = try await journal("model.saveFailed")
    XCTAssertEqual(failed.count, 1)
    XCTAssertTrue(failed.first?.contains("stage=file") ?? false, failed.first ?? "no line")
  }

  /// The file was written but its row was not: the next run cannot trust the file and trains
  /// again, and the journal says the row is why.
  func testARowThatCouldNotBeWrittenSaysSoInTheJournal() async throws {
    // A closed database refuses the write the way a full disk or a locked file would.
    try stack.close()

    let result = service().refresh(examples: examples(), anchor: today, now: trainedAt)

    XCTAssertTrue(result.retrained)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    let failed = try await journal("model.saveFailed")
    XCTAssertEqual(failed.count, 1)
    XCTAssertTrue(failed.first?.contains("stage=row") ?? false, failed.first ?? "no line")
  }
}

extension CategoryModelServiceTests {
  /// «Метаданные — в `ml_models`»: `metrics_json` holds JSON — what the model was trained
  /// on (its fingerprint) and what it holds (the summary) — not a bare checksum of the examples.
  func testTheRowOfTheModelHoldsItsMetadataAsJSON() throws {
    let examples = examples()
    let trained = service().refresh(examples: examples, anchor: today, now: trainedAt)

    let row = try XCTUnwrap(try ModelRepository(writer: stack.writer).row(kind: "category"))
    let text = try XCTUnwrap(row.metricsJSON)
    let object = try XCTUnwrap(
      try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      "metrics_json is not a JSON object: \(text)")
    XCTAssertEqual(
      object["fingerprint"] as? String, CategoryTraining.fingerprint(of: examples))
    let summary = try XCTUnwrap(object["summary"] as? [String: Any])
    XCTAssertEqual(summary["examples"] as? Int, trained.summary?.examples)
    XCTAssertEqual(summary["classes"] as? Int, 2)
    XCTAssertEqual(summary["features"] as? Int, trained.summary?.features)

    // The same examples find the file theirs and do not train again.
    XCTAssertFalse(service().refresh(examples: examples, anchor: today, now: trainedAt).retrained)
  }

  /// A row written before the metadata was JSON — the bare fingerprint — is not trusted: the
  /// model is trained once more and the row written the new way.
  func testARowWithTheBareFingerprintOfBeforeTrainsOnceMore() throws {
    let examples = examples()
    XCTAssertTrue(service().refresh(examples: examples, anchor: today, now: trainedAt).retrained)
    let models = ModelRepository(writer: stack.writer)
    var row = try XCTUnwrap(try models.row(kind: "category"))
    row.metricsJSON = CategoryTraining.fingerprint(of: examples)
    try models.save(row)

    XCTAssertTrue(service().refresh(examples: examples, anchor: today, now: trainedAt).retrained)
    XCTAssertFalse(service().refresh(examples: examples, anchor: today, now: trainedAt).retrained)
  }
}
