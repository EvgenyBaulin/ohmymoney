import CoreKit
import Foundation
import Testing

@testable import AppDatabase

/// Closing the database is part of quitting: the files must be let go of before anything
/// removes them, or SQLite reads a file nobody can reach any more.
@Suite("The database closes when it is asked to")
struct CloseTests {
  @Test func closingLetsGoOfTheFileAndTheFolderCanGo() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-close-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("finance.sqlite")
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    #expect(try stack.appliedMigrations().isEmpty == false)

    try stack.close()

    // A closed connection answers nothing, and the files are the test's to remove.
    #expect(throws: (any Error).self) { try stack.appliedMigrations() }
    try FileManager.default.removeItem(at: directory)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
  }

  @Test func closingAnInMemoryStackIsHarmless() throws {
    let stack = try DatabaseStack(inMemory: TestSupport.schemaSource)
    try stack.close()
  }
}
