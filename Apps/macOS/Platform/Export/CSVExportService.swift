import AppCore
import AppDatabase
import Foundation

/// Writes every table into a folder the owner picked. The format is the one the
/// format demands — UTF-8, headers, amounts as decimal strings with a dot, dates in
/// ISO 8601 — so `pandas.read_csv` reads the files without any parameters.
///
/// Before exporting, the application warns that the files contain names of people and
/// amounts: they leave the sandbox and land wherever the owner points.
public struct CSVExportService: Sendable {
  private let repository: ExportRepository

  public init(repository: ExportRepository) {
    self.repository = repository
  }

  /// Writes every export file, whole or not at all. A disk that fills after the third file
  /// used to leave three new files among those of an earlier export, and nothing said so; now a
  /// failure leaves the folder as it was, is written in the journal with the error's type, and
  /// is thrown for the File menu to tell the owner.
  @discardableResult
  public func export(to directory: URL) throws -> [URL] {
    AppLog.info("export.started", .archive, "the data is being written out as CSV")
    let written: [URL]
    let records: Int
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let tables = try repository.tables()
      // «Число записей» of the spec: the rows of the files written, not a second read of the
      // database that the rate step may have written to meanwhile.
      records = tables.reduce(0) { $0 + ArchiveOpener.countCSVRows($1.data) }
      written = try Self.write(tables, into: directory)
    } catch {
      AppLog.error(
        "export.failed", .archive, "the CSV export did not finish; the folder is as it was",
        [LogPair("error", .error(error))])
      throw error
    }
    AppLog.info(
      "export.done", .archive, "the data was written out",
      [
        LogPair("files", .count(written.count)),
        LogPair("rows", .count(records)),
        LogPair(
          "bytes",
          .bytes(
            written.reduce(0) {
              $0
                + (((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size]) as? Int)
                  ?? 0)
            })),
      ])
    return written
  }

  /// Every file is written first into a hidden folder beside the ones it replaces, and only a
  /// whole set is put in place: renames within one folder, which a full disk does not stop. A
  /// file of an earlier export is set aside before its name is taken, so a set that still cannot
  /// be put in place whole is taken back and the earlier files return. What could not be
  /// returned stays in the hidden folder rather than being deleted with it.
  private static func write(
    _ tables: [ExportRepository.Table], into directory: URL
  ) throws -> [URL] {
    let manager = FileManager.default
    let staging = directory.appendingPathComponent(
      ".ohmymoney-export-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false)
    var keepStaging = false
    defer { if !keepStaging { try? manager.removeItem(at: staging) } }

    for table in tables {
      try table.data.write(to: staging.appendingPathComponent(table.fileName))
    }

    var placed: [URL] = []
    var setAside: [(place: URL, aside: URL)] = []
    do {
      for table in tables {
        let place = directory.appendingPathComponent(table.fileName)
        // Only a file is set aside: something else under the name is the owner's and is left
        // where it is — the rename below then fails and the set is taken back.
        if isReplaceable(place) {
          let aside = staging.appendingPathComponent("earlier-" + table.fileName)
          try manager.putInPlace(place, at: aside)
          setAside.append((place, aside))
        }
        try manager.putInPlace(staging.appendingPathComponent(table.fileName), at: place)
        placed.append(place)
      }
    } catch {
      for url in placed { try? manager.removeItem(at: url) }
      for (place, aside) in setAside {
        do { try manager.putInPlace(aside, at: place) } catch { keepStaging = true }
      }
      throw error
    }
    return placed
  }

  /// The files of `directory` an export would replace: the names the spec fixes, present
  /// there as files. The File menu asks before it replaces them: the folder is the owner's,
  /// and a `people.csv` in it may be theirs rather than an earlier export's.
  public func filesItWouldReplace(in directory: URL) -> [String] {
    ExportTables.all.map(\.fileName).filter {
      Self.isReplaceable(directory.appendingPathComponent($0))
    }
  }

  /// Only a file is replaced: something else under the name is the owner's and is left where
  /// it is — the export then fails and the folder stays as it was.
  private static func isReplaceable(_ place: URL) -> Bool {
    let type = (try? FileManager.default.attributesOfItem(atPath: place.path))?[.type]
    return (type as? FileAttributeType).map { $0 == .typeRegular || $0 == .typeSymbolicLink }
      ?? false
  }

  public func tables() throws -> [ExportRepository.Table] {
    try repository.tables()
  }

  public func rowCounts() throws -> [String: Int] {
    try repository.rowCounts()
  }
}
