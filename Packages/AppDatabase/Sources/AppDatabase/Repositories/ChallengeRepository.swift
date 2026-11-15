import AppCore
import CoreKit
import Foundation
import GRDB

/// The challenges of the owner. They are one text under a key of the `settings` table
/// (`ChallengeBook.storageKey`), so no schema changed: they go with the archive and the CSV of
/// the settings like the other settings of the app. Like every setting they stay on the device
/// (`settings` is not followed by the journal of changes).
public struct ChallengeRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public init(stack: DatabaseStack) {
    self.writer = stack.writer
  }

  /// The book, inside a read the caller already holds; a text that does not read is no book.
  static func book(_ db: Database) throws -> ChallengeBook {
    let stored = try SettingsRepository.values(of: [ChallengeBook.storageKey], db: db)
    return ChallengeBook(storedText: stored[ChallengeBook.storageKey])
  }

  public func book() throws -> ChallengeBook {
    try writer.read { try Self.book($0) }
  }

  /// Writes the book. Nothing is written when it reads as it is already kept, so a screen that
  /// saves what it just read does not touch the file.
  public func save(_ book: ChallengeBook) throws {
    try writer.write { db in
      let current = try Self.book(db)
      guard current != book else { return }
      try SettingsRepository.set(ChallengeBook.storageKey, to: book.storedText, in: db)
    }
  }

  /// Starts a challenge.
  public func add(_ challenge: Challenge) throws {
    var book = try book()
    book.items.removeAll { $0.id == challenge.id }
    book.items.append(challenge)
    try save(book)
  }

  /// Changes a challenge; one that is not there is not added.
  public func update(_ challenge: Challenge) throws {
    var book = try book()
    guard let index = book.items.firstIndex(where: { $0.id == challenge.id }) else { return }
    book.items[index] = challenge
    try save(book)
  }

  /// Gives a challenge up on `day`: it stays in the list, finished.
  public func stop(_ id: UUID, on day: DateOnly) throws {
    var book = try book()
    guard let index = book.items.firstIndex(where: { $0.id == id }),
      book.items[index].stoppedOn == nil
    else { return }
    book.items[index].stoppedOn = day
    try save(book)
  }

  /// Removes a challenge from the list.
  public func remove(_ id: UUID) throws {
    var book = try book()
    book.items.removeAll { $0.id == id }
    try save(book)
  }
}
