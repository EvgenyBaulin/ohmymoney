import AppCore
import Foundation
@preconcurrency import UserNotifications

@MainActor
protocol NotificationPermissionCenter: AnyObject {
  func permission() async -> NotificationPlan.Permission
  func requestPermission() async -> Bool
}

/// Reading status never asks the system. Only an explicit affirmative answer may do that.
@MainActor
struct NotificationPermissionGate {
  enum Step: Equatable { case explanation, allowed, settings }
  let center: any NotificationPermissionCenter

  func step() async -> Step {
    switch await center.permission() {
    case .undetermined: .explanation
    case .allowed: .allowed
    case .denied: .settings
    }
  }

  func answer(allow: Bool) async -> Bool {
    guard allow else { return false }
    switch await step() {
    case .allowed: return true
    case .settings: return false
    case .explanation: return await center.requestPermission()
    }
  }
}

@MainActor
final class SystemPermissionCenter: NotificationPermissionCenter {
  func permission() async -> NotificationPlan.Permission {
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .authorized, .provisional, .ephemeral: .allowed
    case .notDetermined: .undetermined
    default: .denied
    }
  }

  func requestPermission() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]))
      ?? false
  }
}
