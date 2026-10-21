import AppCore
import AppDatabase
import Foundation
import Synchronization

/// Step 4 of the pipeline: «обучение модели категорий».
///
/// Training is done here, off the main thread, and the model is published into a box the
/// entry line reads. Typing must never wait on a pipeline step, so the box is what the ↓
/// panel asks — never the step.
///
/// «Обучение — в конвейере, если данные менялись»: what the model was trained on is
/// fingerprinted, and an unchanged fingerprint with a file that still checks out means there
/// is nothing to do.
final class CategoryModelService: Sendable {
  static let kind = "category"
  static let fileName = "category-model-v1.json"

  private let box: CategoryModelBox
  private let models: ModelRepository
  private let directory: URL

  init(box: CategoryModelBox, models: ModelRepository, directory: URL) {
    self.box = box
    self.models = models
    self.directory = directory
  }

  private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

  /// The service the application runs with: the environment's box, the database's row, and
  /// the models folder of this data set.
  @MainActor
  static func live(stack: DatabaseStack, environment: AppEnvironment) -> CategoryModelService {
    CategoryModelService(
      box: environment.categoryModel, models: ModelRepository(writer: stack.writer),
      directory: AppPaths.modelsDirectory)
  }

  /// What the step reports: enough for «Качество модели» and for the journal, and nothing of
  /// the owner's.
  struct Result: Sendable, Equatable {
    var readiness: CategoryModelReadiness
    var summary: CategoryModel.Summary?
    var retrained: Bool
  }

  func refresh(examples: [CategoryExample], anchor: DateOnly, now: Date = Date()) -> Result {
    let fingerprint = CategoryTraining.fingerprint(of: examples)
    if let loaded = loadIfUnchanged(fingerprint: fingerprint) {
      box.hold(loaded, trainedOn: examples)
      return Result(readiness: loaded.readiness, summary: loaded.summary, retrained: false)
    }

    let model = CategoryModel.train(on: examples, anchor: anchor)
    box.hold(model, trainedOn: examples)
    save(model, fingerprint: fingerprint, now: now)
    AppLog.info(
      "model.trained", .compute, "the category model was trained",
      [
        LogPair("examples", .count(model.summary.examples)),
        LogPair("classes", .count(model.summary.classes)),
        LogPair("ready", .count(model.summary.classesReady)),
        LogPair("features", .count(model.summary.features)),
      ])
    return Result(readiness: model.readiness, summary: model.summary, retrained: true)
  }

  /// The file is a cache: anything wrong with it means training again, and the reason goes in
  /// the journal as a code — never a path and never a count of the owner's operations.
  private func loadIfUnchanged(fingerprint: String) -> CategoryModel? {
    guard let row = try? models.row(kind: Self.kind),
      Metadata.read(row.metricsJSON)?.fingerprint == fingerprint
    else {
      return nil
    }
    // The size is asked before a byte is read: a file larger than any model of ours is not
    // read into memory — and hashed — to find out (`CategoryModelFile.maximumBytes`).
    guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
      return nil
    }
    guard size <= CategoryModelFile.maximumBytes else {
      AppLog.warning(
        "model.rejected", .compute, "the model file was refused",
        [LogPair("reason", .token(CategoryModelFile.Refusal.tooLarge.rawValue))])
      return nil
    }
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    guard CategoryModelFile.checksum(of: data) == row.checksum else {
      AppLog.warning(
        "model.rejected", .compute, "the model file did not match its checksum",
        [LogPair("reason", .token("checksum"))])
      return nil
    }
    do {
      return try CategoryModelFile.model(from: data)
    } catch let refusal as CategoryModelFile.Refusal {
      AppLog.warning(
        "model.rejected", .compute, "the model file was refused",
        [LogPair("reason", .token(refusal.rawValue))])
      return nil
    } catch {
      return nil
    }
  }

  /// A save that fails costs nothing but time — the box already holds the model, and the next
  /// run trains again — yet a failure that repeats would retrain on every run with nobody told
  /// why. So each failure is a journal line naming the stage and the kind of error, never a
  /// path.
  private func save(_ model: CategoryModel, fingerprint: String, now: Date) {
    let data: Data
    let metadata: String
    do {
      data = try CategoryModelFile.data(of: model, trainedAt: now)
      metadata = try Metadata(fingerprint: fingerprint, summary: model.summary).json()
    } catch {
      Self.logSaveFailure(stage: "encode", error)
      return
    }
    // The file first, the row second: this way the worst that can be left is a file nobody
    // points at, never a row pointing at a file that is not there.
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      Self.logSaveFailure(stage: "file", error)
      return
    }
    do {
      try models.save(
        ModelRepository.Row(
          kind: Self.kind, version: CategoryModel.formatVersion, trainedAt: now,
          metricsJSON: metadata, file: Self.fileName,
          checksum: CategoryModelFile.checksum(of: data)))
    } catch {
      Self.logSaveFailure(stage: "row", error)
    }
  }

  /// What `ml_models.metrics_json` holds for the category model: what it was trained on — the
  /// fingerprint that tells whether the data has changed since — and what it holds, counts only.
  /// The scores «Качество модели» shows are not kept here: they are measured on the ledger when
  /// that section is opened, not with every write.
  struct Metadata: Codable, Equatable {
    var fingerprint: String
    var summary: CategoryModel.Summary

    /// Keys in a fixed order, so the same model writes the same text on every platform.
    func json() throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// `nil` for anything else — a row of an older build held the bare fingerprint — which
    /// means training again, as for any cache that cannot be trusted.
    static func read(_ text: String?) -> Metadata? {
      guard let text else { return nil }
      return try? JSONDecoder().decode(Metadata.self, from: Data(text.utf8))
    }
  }

  private static func logSaveFailure(stage: String, _ error: any Error) {
    AppLog.error(
      "model.saveFailed", .compute, "the trained model was not saved; the next run trains again",
      [
        LogPair("stage", .token(stage)),
        LogPair("error", .error(error)),
        LogPair("code", .count((error as NSError).code)),
      ])
  }
}

/// What becomes of an operation the owner saved, for the model: the choice of a category made
/// against what the model offered is written down («мой выбор пишется в `category_feedback`»), and
/// the model learns the operation at once instead of at the next run of the pipeline.
@MainActor
enum CategoryLearning {
  /// `entry` is the operation as written, `before` the one it replaced when it was edited.
  /// Neither half is the owner's business if it fails: the operation is saved either way, so
  /// a choice that could not be written goes to the journal and nowhere else.
  static func saved(
    _ entry: TransactionEntry, replacing before: TransactionEntry? = nil,
    choice: CategoryFeedback?, environment: AppEnvironment
  ) {
    if let choice, let stack = environment.stack,
      entry.parts.contains(where: { $0.id == choice.partId })
    {
      do {
        try ModelRepository(writer: stack.writer).record(choice)
      } catch {
        AppLog.error(
          "model.choiceNotWritten", .db, "a choice of a category was not written down",
          [LogPair("error", .error(error))])
      }
    }
    // Taught the way the pipeline teaches it: the same rows, the same rule of what counts.
    let categories = (try? environment.references?.categories(includeArchived: true)) ?? []
    let examples = LedgerTraining.examples(
      of: Dataset(entries: [entry], categories: categories), calendar: environment.calendar)
    let parts = Set(entry.parts.map(\.id)).union(before?.parts.map(\.id) ?? [])
    environment.categoryModel.relearn(parts: parts, from: examples)
  }
}

/// Where the trained model waits for whoever asks. Read from the main actor by the entry
/// line, written from the pipeline off it — so it is behind a lock, like `LatestSnapshot`.
///
/// It keeps, by part, the examples the model it holds has learned. A correction takes back
/// exactly what the model learned of that part and learns what the part says now: the model
/// stays the one a full training on the same examples gives, to the last count
/// — never a count taken back that was not there.
final class CategoryModelBox: Sendable {
  private struct Held {
    var model: CategoryModel
    var examples: [UUID: CategoryExample]
  }

  private let storage = Mutex<Held?>(nil)

  /// `examples` is what `model` was trained on.
  func hold(_ model: CategoryModel, trainedOn examples: [CategoryExample]) {
    let byPart = Dictionary(examples.map { ($0.partId, $0) }, uniquingKeysWith: { _, last in last })
    storage.withLock { $0 = Held(model: model, examples: byPart) }
  }

  var model: CategoryModel? { storage.withLock { $0?.model } }

  /// A correction, felt at once: the next suggestion is made by a model that already knows.
  /// Every part of `parts` is taken back and the ones in `examples` learned — an operation
  /// saved, edited or removed is its parts as they were and as they are. The file catches up
  /// at the next run of the pipeline — it is a cache, and the database holds the truth.
  func relearn(parts: Set<UUID>, from examples: [CategoryExample]) {
    let now = Dictionary(examples.map { ($0.partId, $0) }, uniquingKeysWith: { _, last in last })
    storage.withLock { held in
      guard var current = held else { return }
      for part in parts.union(now.keys) {
        if let old = current.examples[part] { current.model.unlearn(old) }
        current.examples[part] = now[part]
        if let new = now[part] { current.model.learn(new) }
      }
      held = current
    }
  }

  func predict(_ query: CategoryQuery, among candidates: [UUID]) -> CategoryPrediction {
    guard let model else {
      return CategoryPrediction(readiness: .tooFewExamples(have: 0, needed: 50))
    }
    return model.predict(query, among: candidates)
  }
}
