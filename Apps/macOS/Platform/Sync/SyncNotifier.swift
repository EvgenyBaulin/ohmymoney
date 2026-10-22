import Foundation
@preconcurrency import UserNotifications

/// Tells the owner that a record is waiting for a choice. A seam: the app posts a system
/// notification, a test counts calls.
@MainActor
protocol SyncNotifying: AnyObject {
  /// `count` records wait in the list of conflicts, more than before.
  func conflictsAppeared(count: Int, title: String, body: String)
}

/// The system notification. It asks for permission the first time there is something to say,
/// and says nothing when the owner declined: the banner and the list are there either way.
@MainActor
final class SystemSyncNotifier: SyncNotifying {
  func conflictsAppeared(count: Int, title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      // One notification for the list: a new one replaces the old.
      let request = UNNotificationRequest(
        identifier: "sync.conflicts", content: content, trigger: nil)
      center.add(request)
    }
  }
}
