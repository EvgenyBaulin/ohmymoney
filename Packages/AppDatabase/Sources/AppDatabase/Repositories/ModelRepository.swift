import CoreKit
import Foundation
import GRDB

/// The one row that says which model file is the current one, and what it was trained on
/// (`ml_models`). The model itself is a file in `models/`, and only the app's own files are
/// loaded, each with its checksum checked.
public struct ModelRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public struct Row: Hashable, Sendable {
    public var id: UUID
    public var kind: String
    public var version: Int
    public var trainedAt: Date
    /// What the model was trained on and what it holds, as JSON — the kind's own shape
    /// (for the category model: its fingerprint and summary). The scores of
    /// «Качество модели» are measured when that section is opened and are not kept here.
    public var metricsJSON: String?
    /// The file's name, never a path: a path of this Mac has no business in the database.
    public var file: String
    public var checksum: String

    public init(
      id: UUID = UUID(), kind: String, version: Int, trainedAt: Date, metricsJSON: String? = nil,
      file: String, checksum: String
    ) {
      self.id = id
      self.kind = kind
      self.version = version
      self.trainedAt = trainedAt
      self.metricsJSON = metricsJSON
      self.file = file
      self.checksum = checksum
    }
  }

  public func row(kind: String) throws -> Row? {
    try writer.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM ml_models WHERE kind = ?", arguments: [kind])
    }
  }

  /// One row per kind: a new training replaces the one before it.
  public func save(_ row: Row) throws {
    try writer.write { db in
      try db.execute(sql: "DELETE FROM ml_models WHERE kind = ?", arguments: [row.kind])
      try db.execute(
        sql: """
          INSERT INTO ml_models (id, kind, version, trained_at, metrics_json, file, checksum)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          row.id.uuidString.lowercased(), row.kind, row.version,
          StoredInstant.databaseValue(row.trainedAt),
          row.metricsJSON, row.file, row.checksum,
        ])
    }
  }
}

// MARK: - The owner's choices

extension ModelRepository {
  /// Writes down one choice of a category made against what the model offered, in
  /// `category_feedback`.
  public func record(_ choice: CategoryFeedback) throws {
    try writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO category_feedback
            (id, text, predicted_category_id, chosen_category_id, at, part_id, confidence_bp)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        // Ids as every other table keeps them (`RowMapping`): the foreign keys compare text.
        arguments: [
          choice.id.uuidString, choice.text, choice.predictedCategoryId?.uuidString,
          choice.chosenCategoryId?.uuidString, StoredInstant.databaseValue(choice.at),
          choice.partId?.uuidString, choice.confidenceBp,
        ])
    }
  }

  /// Every choice written down, oldest first.
  public func feedback() throws -> [CategoryFeedback] {
    try writer.read { db in try Self.feedback(db) }
  }

  static func feedback(_ db: Database) throws -> [CategoryFeedback] {
    try CategoryFeedback.fetchAll(db, sql: "SELECT * FROM category_feedback ORDER BY at, rowid")
  }
}

extension CategoryFeedback: @retroactive FetchableRecord {
  public init(row: GRDB.Row) {
    self.init(
      id: UUID(uuidString: row["id"]) ?? UUID(),
      text: row["text"] ?? "",
      predictedCategoryId: (row["predicted_category_id"] as String?).flatMap(
        UUID.init(uuidString:)),
      chosenCategoryId: (row["chosen_category_id"] as String?).flatMap(UUID.init(uuidString:)),
      partId: (row["part_id"] as String?).flatMap(UUID.init(uuidString:)),
      confidenceBp: row["confidence_bp"],
      at: RowMapping.readableInstant(row, "at") ?? Date(timeIntervalSince1970: 0))
  }
}

extension ModelRepository.Row: FetchableRecord {
  public init(row: GRDB.Row) {
    self.init(
      id: UUID(uuidString: row["id"]) ?? UUID(), kind: row["kind"], version: row["version"],
      trainedAt: RowMapping.readableInstant(row, "trained_at") ?? Date(timeIntervalSince1970: 0),
      metricsJSON: row["metrics_json"], file: row["file"], checksum: row["checksum"])
  }
}
