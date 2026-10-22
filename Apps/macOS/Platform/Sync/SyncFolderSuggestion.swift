import Foundation

/// The folder the app proposes for the exchange: iCloud Drive → OhMyMoney → Sync (0518). The
/// owner confirms it or picks another one; the live database never goes there, only journal
/// files do.
enum SyncFolderSuggestion {
  static let folderNames = ["OhMyMoney", "Sync"]

  #if os(macOS)
    /// Where the picker starts on a Mac. The sandbox cannot make the folder by itself — the
    /// owner's confirmation in the picker grants the access — so this is only a place to open.
    static var startingPoint: URL {
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
  #endif

  /// The name shown for a chosen folder: the last two parts, «OhMyMoney › Sync».
  static func displayName(of url: URL) -> String {
    let parts = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
    return parts.suffix(2).joined(separator: " › ")
  }
}
