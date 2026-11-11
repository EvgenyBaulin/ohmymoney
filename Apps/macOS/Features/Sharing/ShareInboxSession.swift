import Foundation
import Observation

/// Only one window may present an inbox item. A lock releases the claim without deleting
/// anything; an unreadable item can be postponed until the next launch.
@MainActor
@Observable
final class ShareInboxSession {
  static let shared = ShareInboxSession()
  private(set) var file: URL?
  private var postponed: Set<URL> = []

  func claimNext(in inbox: ShareInbox) throws -> URL? {
    guard file == nil else { return nil }
    file = try inbox.pending().first { !postponed.contains($0) }
    return file
  }

  func release(_ file: URL) {
    if self.file == file { self.file = nil }
  }

  func postpone(_ file: URL) {
    postponed.insert(file)
    release(file)
  }
}
