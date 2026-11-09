import AppCore
import CoreKit
import Foundation
import GRDB

/// The English names of the categories, made in the background: every category without one, or
/// with one made of a name it no longer has, gets it from the translator. One pass covers every
/// way a name comes in — a new category, a rename, an undo, a row from another device or an
/// older build, a restored copy — and the first launch after the update, which finds all of them
/// without one.
///
/// It writes only the two columns of the English name, straight to the database: it is not the
/// owner's step, so it never lands on the undo stack, and the owner's name is never touched. A
/// name the translator cannot make now stays empty and is tried on the next pass.
///
/// The writes stay out of the exchange journal: every device makes its own English names, and a
/// background write recorded beside the owner's rename of the same category on another device
/// would be a conflict about a name nobody touched here. The English name travels with the
/// owner's next edit of the category (the row goes whole) and in the seed of a new device, and
/// two devices wording it apart is never a conflict (`SyncConflict.isService`).
public struct CategoryEnglishNames: Sendable {
  private let writer: any DatabaseWriter
  private let translator: any CategoryNameTranslating

  public init(writer: any DatabaseWriter, translator: any CategoryNameTranslating) {
    self.writer = writer
    self.translator = translator
  }

  public init(stack: DatabaseStack, translator: any CategoryNameTranslating) {
    self.init(writer: stack.writer, translator: translator)
  }

  /// What a pass did, in counts only.
  public struct Pass: Hashable, Sendable {
    /// Categories that had no English name of their current name before the pass.
    public var due = 0
    /// English names made and written.
    public var made = 0
    /// Names the translator could not make (or that were renamed meanwhile): tried next time.
    public var left = 0
    /// Nothing could be translated on the device: the pass did not ask for a single name.
    public var unavailable = false

    public init(due: Int = 0, made: Int = 0, left: Int = 0, unavailable: Bool = false) {
      self.due = due
      self.made = made
      self.left = left
      self.unavailable = unavailable
    }
  }

  /// A category whose English name is to be made: its id and its name now.
  public struct Due: Hashable, Sendable {
    public var id: String
    public var name: String
  }

  /// The categories, archived ones too, with no English name or one of another name; by order of
  /// the tree.
  public func due() throws -> [Due] {
    try writer.read { db in
      // A database of an older schema has no such columns: nothing is due there.
      guard try db.columns(in: "categories").contains(where: { $0.name == "name_en" }) else {
        return []
      }
      return try Row.fetchAll(
        db,
        sql: """
          SELECT id, name FROM categories
          WHERE trim(name) <> ''
            AND (name_en IS NULL OR trim(name_en) = '' OR name_en_source IS NOT name)
          ORDER BY parent_id IS NOT NULL, sort, rowid
          """
      ).map { Due(id: $0["id"], name: $0["name"]) }
    }
  }

  /// Writes the English name of the category, only if it still has the name it was made of.
  /// Whether it landed.
  @discardableResult
  public func write(_ english: String, of id: String, madeOf name: String) throws -> Bool {
    try writer.write { db in
      try Self.unrecorded(db) {
        try db.execute(
          sql: """
            UPDATE categories SET name_en = ?, name_en_source = ?
            WHERE id = ? AND name = ?
            """, arguments: [english, name, id, name])
        return db.changesCount > 0
      }
    }
  }

  /// Runs the writes with the journal of the exchange off, and puts it back as it was, inside the
  /// caller's transaction: a write that fails rolls the switch back with the rows, and no other
  /// connection ever sees it off.
  static func unrecorded<T>(_ db: Database, _ body: () throws -> T) throws -> T {
    let previous = try String.fetchOne(
      db, sql: "SELECT value FROM sync_meta WHERE key = 'recording'")
    let recording = previous == "1"
    if recording {
      try db.execute(sql: "UPDATE sync_meta SET value = '0' WHERE key = 'recording'")
    }
    let result = try body()
    if recording, let previous {
      try db.execute(
        sql: "UPDATE sync_meta SET value = ? WHERE key = 'recording'", arguments: [previous])
    }
    return result
  }

  /// One pass over every category due. The names are asked one after another, off any
  /// transaction, and written together in one: the app recounts and copies once, not once per
  /// category. A refused write (read-only mode, a closed database) leaves them for the next pass.
  public func run() async -> Pass {
    guard let due = try? due(), !due.isEmpty else { return Pass() }
    var pass = Pass(due: due.count)
    guard await translator.isAvailable() else {
      pass.left = due.count
      pass.unavailable = true
      return pass
    }
    var made: [(category: Due, english: String)] = []
    for category in due {
      if Task.isCancelled { break }
      if let answer = await translator.english(for: category.name),
        let english = CategoryTranslation.cleaned(answer)
      {
        made.append((category: category, english: english))
      }
    }
    let found = made
    let written =
      (try? await writer.write { db -> Int in
        try Self.unrecorded(db) {
          var count = 0
          for (category, english) in found {
            try db.execute(
              sql: """
                UPDATE categories SET name_en = ?, name_en_source = ?
                WHERE id = ? AND name = ?
                """, arguments: [english, category.name, category.id, category.name])
            count += db.changesCount
          }
          return count
        }
      }) ?? 0
    pass.made = written
    pass.left = due.count - written
    return pass
  }
}
