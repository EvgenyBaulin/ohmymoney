import AppCore
import AppDatabase
import Foundation

extension AppEnvironment {
  /// The daily upkeep of the attached files: at the launch and then at every 03:00 while the app
  /// stays open, like the copy of the day. Receipt photos that are not kept for good go to the
  /// trash, the trash is emptied after its days, and files nobody names are taken away once they
  /// are old. Warranties and documents are never touched.
  func startAttachmentUpkeep() {
    Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let environment = self else { return }
        await environment.sweepAttachments()
        let next = BackupSpace.nextDailyRun(after: Date(), calendar: .current)
        try? await Task.sleep(for: .seconds(max(60, next.timeIntervalSinceNow)))
      }
    }
  }

  /// One sweep, off the main thread. Returns what it did, `nil` when there is nothing to sweep
  /// or the sweep failed (the failure is in the journal; the next day tries again).
  @discardableResult
  func sweepAttachments(now: Date = Date()) async -> AttachmentService.SweepReport? {
    guard let service = attachments else { return nil }
    let outcome = await Task.detached(priority: .utility) {
      Result { try service.dailySweep(now: now) }
    }.value
    switch outcome {
    case .success(let report):
      if !report.isEmpty {
        AppLog.info(
          "attachments.swept", .db, "the attached files were swept",
          [
            LogPair("trashed", .count(report.movedToTrash)),
            LogPair("deleted", .count(report.deleted)),
            LogPair("orphans", .count(report.orphanFiles)),
          ])
      }
      return report
    case .failure(let error):
      AppLog.warning(
        "attachments.sweepFailed", .db, "the sweep of attached files failed",
        [LogPair("error", .error(error))])
      return nil
    }
  }
}
