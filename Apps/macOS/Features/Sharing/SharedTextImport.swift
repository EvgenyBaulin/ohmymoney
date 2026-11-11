import Foundation

/// Sharing an SMS always offers a draft, on both platforms. It never writes an operation
/// silently and never retains the original bank text in the books.
@MainActor
enum SharedTextImport {
  static func propose(_ text: String, deps: AppDependencies) -> String {
    let environment = deps.environment
    guard !environment.lock.isCovered else { return "autoEntry.locked" }
    guard !environment.shield.isReadOnly else { return "autoEntry.readOnly" }
    guard let snapshot = deps.compute.wholeSnapshot else { return "autoEntry.notReady" }
    guard let reading = AutoEntryReading(text, environment: environment, snapshot: snapshot) else {
      return "autoEntry.notBank"
    }
    if reading.isInBooks || reading.isWaiting(environment: environment) {
      return "autoEntry.duplicate"
    }
    guard reading.keepDraft(environment: environment, now: environment.now()) != nil else {
      return "share.failed"
    }
    return "share.draftSaved"
  }
}
