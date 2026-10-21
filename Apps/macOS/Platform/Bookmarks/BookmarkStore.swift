import AppCore
import Foundation

/// Remembers folders the owner picked, so the sandbox can reach them again after a
/// restart. Only bookmarks are stored — never absolute paths, and never inside the
/// database or the transfer archive.
public struct BookmarkStore: Sendable {
  private let defaultsKey: String
  /// Opens access to the folder a bookmark resolved to. The app asks the sandbox; a test
  /// stands in for it, to see what the store does before access is open and when it is
  /// refused.
  var startAccess: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }

  /// A security-scoped bookmark is a macOS sandbox notion; on iOS the plain bookmark of a
  /// picked folder is what `startAccessingSecurityScopedResource` opens.
  #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
  #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
  #endif

  public init(key: String) {
    self.defaultsKey = key
  }

  /// The key the bookmark is kept under in the defaults.
  public var key: String { defaultsKey }

  /// Whether a folder was ever chosen — whether or not its bookmark still opens.
  public var isStored: Bool {
    UserDefaults.standard.data(forKey: defaultsKey) != nil
  }

  public func save(_ url: URL) throws {
    let data = try url.bookmarkData(
      options: Self.creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }

  /// Resolves the bookmark and starts access. The caller must balance it with `release`,
  /// so this is called once, when the folder starts being used — never from a view that
  /// can appear again and again.
  ///
  /// A stale bookmark — the folder was renamed or moved — still finds the folder, but only for
  /// a while, so it is written again from the folder it found. Only once access is open: in
  /// the sandbox a security-scoped bookmark can be made only for a folder the app may reach,
  /// and written before, the new one failed and the stale one stayed until it stopped
  /// resolving, and the mirroring with it.
  public func resolve() -> URL? {
    guard let (url, isStale) = decode() else { return nil }
    guard startAccess(url) else { return nil }
    if isStale { refresh(url) }
    return url
  }

  /// A new bookmark in place of a stale one. When it cannot be written, the stale one is kept —
  /// it still opens today — and the journal says so.
  private func refresh(_ url: URL) {
    do {
      try save(url)
      AppLog.info("bookmark.refreshed", .backup, "a stale bookmark was written again")
    } catch {
      AppLog.warning(
        "bookmark.refreshFailed", .backup, "a stale bookmark could not be written again",
        [LogPair("error", .error(error))])
    }
  }

  private func decode() -> (url: URL, isStale: Bool)? {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data, options: Self.resolutionOptions, relativeTo: nil,
        bookmarkDataIsStale: &stale)
    else { return nil }
    return (url, stale)
  }

  public func release(_ url: URL) {
    url.stopAccessingSecurityScopedResource()
  }

  public func clear() {
    UserDefaults.standard.removeObject(forKey: defaultsKey)
  }
}
