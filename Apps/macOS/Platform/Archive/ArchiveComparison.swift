import AppCore
import AppDatabase
import Foundation

/// «Сравнить с архивом…»: what an archive of the transfer holds against the database now, by the
/// same reading as «Сравнить с текущей» of a copy (`BackupComparison`). The archive is opened in
/// memory — with its password when it has one — and only the database inside it is put in a
/// scratch folder, which goes at the end whatever came of the comparison. Nothing is written to
/// the database, to the archive or to the settings.
enum ArchiveComparison {
  /// The scratch folders are made here, one per comparison.
  static var scratchRoot: URL { FileManager.default.temporaryDirectory }

  /// Whether the file needs a password before it can be read.
  static func needsPassword(_ url: URL, archives: ArchiveService) -> Bool {
    archives.isEncryptedSafely(at: url)
  }

  /// Compares the archive at `url` with `current`. A wrong password and an archive that does not
  /// read are thrown as the opening throws them; no scratch folder is left in any case.
  static func compare(
    archiveAt url: URL, password: String?, with current: Dataset, archives: ArchiveService,
    scratch: URL = scratchRoot, now: Date = Date(), schema: any SchemaSource = BundleSchemaSource()
  ) throws -> BackupComparison {
    let opened = try archives.openArchive(at: url, password: password)
    guard let database = opened.database else {
      throw CoreError.invalidArchive(reason: .manifestUnreadable)
    }
    let manager = FileManager.default
    let folder = scratch.appendingPathComponent(
      "ohmymoney-archive-compare-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: folder) }
    let file = folder.appendingPathComponent("archive.sqlite")
    try database.write(to: file, options: .atomic)
    return BackupComparison(
      copy: try BackupSnapshot.of(fileAt: file, now: now, schema: schema),
      current: BackupSnapshot(dataset: current, now: now))
  }
}
