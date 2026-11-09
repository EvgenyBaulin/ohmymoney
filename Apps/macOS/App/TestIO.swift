import Foundation

/// The test folder `--test-io` turns on (Debug only, `LaunchOptions`): a UI test cannot drive
/// the file panels of a sandboxed app reliably, so the places that would open one take their
/// answer from a file of this folder instead. The folder is the app's own, in its caches; the
/// files a test needs (`--test-io-file`) are written there the first time it is asked.
enum TestIO {
  static var folder: URL? {
    guard LaunchOptions.current.usesTestIO else { return nil }
    return prepared
  }

  private static let prepared: URL? = {
    guard
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let folder = caches.appendingPathComponent("e2e-io", isDirectory: true)
    try? FileManager.default.removeItem(at: folder)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, data) in LaunchOptions.current.testIOFiles {
      try? data.write(to: folder.appendingPathComponent(name))
    }
    return folder
  }()

  /// `name` inside the folder.
  static func url(_ name: String) -> URL? {
    folder?.appendingPathComponent(name)
  }
}
