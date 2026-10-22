import AppCore
import Foundation
import Testing

@testable import AppDatabase

// Synthetic data only.

@Suite("The shared folder holds journal files and nothing else")
struct SyncFolderTests {
  private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func aWholeExchangeLeavesOnlyJournalFilesInTheFolder() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let mac = try SyncExchange(writer: stack.writer, deviceId: "mac", deviceName: "Mac")
    try mac.setRecording(true)
    try stack.writer.write { db in
      try db.execute(sql: "INSERT INTO people (id, name) VALUES ('p1', 'Alex')")
    }
    _ = try mac.exchange(with: DirectoryJournalFolder(url: shared))
    let names = try FileManager.default.contentsOfDirectory(atPath: shared.path)
    #expect(names == [SyncFormat.fileName(deviceId: "mac", sequence: 0)])
    for name in names {
      #expect(!name.hasSuffix(".sqlite") && !name.hasSuffix("-wal") && !name.hasSuffix("-shm"))
    }
    // The live database and its companions stay where they were.
    let live = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(live.contains("finance.sqlite"))
  }

  @Test func theFolderWritesNothingThatIsNotAJournalFile() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let folder = DirectoryJournalFolder(url: shared)
    for name in ["finance.sqlite", "finance.sqlite-wal", "backup 2026.sqlite", "notes.txt"] {
      #expect(throws: SyncFolderError.refusedName) {
        try folder.put(temporaryName: name, data: Data("x".utf8))
      }
    }
    try folder.put(temporaryName: ".writing-journal-mac-0000000000.json", data: Data("{}".utf8))
    for name in ["finance.sqlite", "../escape.json", "journal-x.json"] {
      #expect(throws: SyncFolderError.refusedName) {
        try folder.rename(temporaryName: ".writing-journal-mac-0000000000.json", to: name)
      }
    }
    #expect(throws: SyncFolderError.refusedName) { try folder.read(name: "finance.sqlite") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).count == 1)
  }

  @Test func aJournalFileIsNeverReplaced() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let folder = DirectoryJournalFolder(url: shared)
    let name = SyncFormat.fileName(deviceId: "mac", sequence: 0)
    try folder.put(temporaryName: ".writing-\(name)", data: Data("one".utf8))
    try folder.rename(temporaryName: ".writing-\(name)", to: name)
    try folder.put(temporaryName: ".writing-\(name)", data: Data("two".utf8))
    #expect(throws: SyncFolderError.refusedName) {
      try folder.rename(temporaryName: ".writing-\(name)", to: name)
    }
    #expect(String(decoding: try folder.read(name: name), as: UTF8.self) == "one")
  }

  @Test func aMissingFolderAndAFileInsteadOfAFolderAreMissing() throws {
    let gone = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-gone-\(UUID().uuidString)")
    #expect(throws: SyncFolderError.missing) {
      try DirectoryJournalFolder(url: gone).listNames()
    }
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-file-\(UUID().uuidString)")
    try Data("x".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(throws: SyncFolderError.missing) {
      try DirectoryJournalFolder(url: file).listNames()
    }
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let device = try SyncExchange(writer: stack.writer, deviceId: "mac", deviceName: "Mac")
    #expect(throws: SyncFailure.folderMissing) {
      try device.exchange(with: DirectoryJournalFolder(url: gone))
    }
  }

  @Test func theDatabaseAndTheBackupFoldersAreNotAllowedAsTheExchangeFolder() {
    let support = URL(fileURLWithPath: "/tmp/ohmymoney-policy/Application Support/OhMyMoney/Real")
    let backups = URL(fileURLWithPath: "/tmp/ohmymoney-policy/Backups")
    let mirror = URL(fileURLWithPath: "/tmp/ohmymoney-policy/iCloud/OhMyMoney Backups")
    let protected = [support, backups, mirror]
    #expect(!SyncFolderPolicy.allows(support, protecting: protected))
    #expect(!SyncFolderPolicy.allows(support.appendingPathComponent("Logs"), protecting: protected))
    #expect(!SyncFolderPolicy.allows(backups, protecting: protected))
    #expect(!SyncFolderPolicy.allows(mirror, protecting: protected))
    #expect(
      !SyncFolderPolicy.allows(
        URL(fileURLWithPath: "/tmp/ohmymoney-policy"), protecting: protected),
      "a folder that holds the database is as bad as the database folder")
    #expect(
      SyncFolderPolicy.allows(
        URL(fileURLWithPath: "/tmp/ohmymoney-policy/iCloud/OhMyMoney/Sync"), protecting: protected))
    #expect(
      SyncFolderPolicy.allows(
        URL(fileURLWithPath: "/tmp/ohmymoney-policy/Backups-other"), protecting: protected),
      "a name that merely starts the same is another folder")
  }
}
