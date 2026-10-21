import Foundation

/// The copies of a folder as the Backups tab lists them: each with what its name says, its
/// description when one lies beside it, its size — the file and the folder of readable files
/// beside it, when there is one — and the count and size of all. Built from the names, the
/// sizes and the small description files alone; no copy is ever opened to build it (a copy
/// with no description gets one on demand, `BackupDescription.compute`).
struct BackupList: Equatable, Sendable {
  struct Item: Equatable, Sendable, Identifiable {
    var url: URL
    var copy: BackupCopy
    var description: BackupDescription?
    /// The file of the database.
    var fileBytes: Int64
    /// The folder with the same name that holds the readable version, when there is one.
    var readableFolder: URL?
    var readableBytes: Int64

    var id: URL { url }
    var totalBytes: Int64 { fileBytes + readableBytes }
  }

  var items: [Item]

  var count: Int { items.count }
  var totalBytes: Int64 { items.reduce(0) { $0 + $1.totalBytes } }

  /// How many copies were written before updates.
  var beforeUpdateCount: Int { items.filter { $0.copy.isBeforeMigration }.count }

  /// What the copies written before updates take — kept for ever (decision 0219).
  var beforeUpdateBytes: Int64 {
    items.filter { $0.copy.isBeforeMigration }.reduce(0) { $0 + $1.totalBytes }
  }

  /// Newest first by the moment the copies were taken, old names and new together. Files that
  /// are not copies of ours are not in the list.
  static func load(in directory: URL, manager: FileManager = .default) -> BackupList {
    let urls =
      (try? manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    let items: [Item] =
      urls
      .filter { $0.pathExtension == "sqlite" }
      .compactMap { url in
        guard let copy = BackupCopy.parse(url.lastPathComponent) else { return nil }
        let folder = url.deletingPathExtension()
        var isFolder: ObjCBool = false
        let hasFolder =
          manager.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
        return Item(
          url: url, copy: copy, description: BackupDescription.read(forCopyAt: url),
          fileBytes: size(of: url, manager: manager), readableFolder: hasFolder ? folder : nil,
          readableBytes: hasFolder ? size(ofFolder: folder, manager: manager) : 0)
      }
      .sorted { BackupCopy.newerFirst($0.copy, $1.copy) }
    return BackupList(items: items)
  }

  /// What a copy takes on disk: the file, the description beside it and the readable folder.
  static func bytes(ofCopyAt url: URL, manager: FileManager = .default) -> Int64 {
    let folder = url.deletingPathExtension()
    var isFolder: ObjCBool = false
    let hasFolder =
      manager.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
    return size(of: url, manager: manager)
      + size(of: BackupDescription.url(forCopyAt: url), manager: manager)
      + (hasFolder ? size(ofFolder: folder, manager: manager) : 0)
  }

  private static func size(of url: URL, manager: FileManager) -> Int64 {
    ((try? manager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
  }

  private static func size(ofFolder url: URL, manager: FileManager) -> Int64 {
    guard
      let walker = manager.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in walker {
      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
    }
    return total
  }
}
