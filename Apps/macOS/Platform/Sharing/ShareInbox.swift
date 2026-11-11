import AppCore
import Foundation

/// A durable, transient inbox in the App Group. No database is shared with an extension.
/// The capability and activation rule are deliberately off in unsigned/local builds.
struct ShareInbox: Sendable {
  static let isEnabled = false
  static var groupIdentifier: String {
    #if DEBUG
      "group.io.github.EvgenyBaulin.ohmymoney.debug"
    #else
      "group.io.github.EvgenyBaulin.ohmymoney"
    #endif
  }

  static func configured() -> ShareInbox? {
    guard isEnabled,
      let group = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupIdentifier)
    else { return nil }
    return ShareInbox(directory: group.appendingPathComponent("ShareInbox", isDirectory: true))
  }

  let directory: URL

  @discardableResult
  func enqueue(_ item: SharedImportItem) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(UUID().uuidString + ".ommshare")
    #if os(iOS)
      try item.encoded().write(to: file, options: [.atomic, .completeFileProtection])
    #else
      try item.encoded().write(to: file, options: .atomic)
    #endif
    return file
  }

  func pending() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey]
    )
    .filter { file in
      file.pathExtension == "ommshare"
        && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
        && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    .sorted {
      let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      return (a, $0.lastPathComponent) < (b, $1.lastPathComponent)
    }
  }

  func read(_ file: URL) throws -> SharedImportItem {
    try check(file)
    return try SharedImportItem.decode(Data(contentsOf: file))
  }

  func acknowledge(_ file: URL) throws {
    try check(file)
    try FileManager.default.removeItem(at: file)
  }

  private func check(_ file: URL) throws {
    guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
      file.pathExtension == "ommshare",
      UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
      !(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false)
    else { throw SharedImportItem.Failure.invalid }
  }
}
