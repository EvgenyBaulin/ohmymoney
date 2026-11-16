import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// A reason has its own explanation and a synthetic example with no personal data.
enum NotificationPermissionReason: String {
  case evening, place, sync, mac
}

@MainActor
struct NotificationPermissionSheet: View {
  let reason: NotificationPermissionReason
  let settings: Bool
  let answer: (Bool) -> Void
  private let language = AppLanguage()
  private func t(_ key: String) -> String {
    language(key, table: "MacFeatures")
  }

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "bell.badge").appFont(.largeTitle)
      Text(
        verbatim: t(
          settings
            ? "notify.permission.settings.title" : "notify.permission.\(reason.rawValue).title")
      )
      .appFont(.title2)
      Text(
        verbatim: t(
          settings ? "notify.permission.settings.body" : "notify.permission.\(reason.rawValue).body"
        ))
      if !settings {
        GroupBox {
          Text(verbatim: t("notify.permission.\(reason.rawValue).example"))
        }
      }
      Button(t(settings ? "notify.permission.settings.open" : "notify.permission.allow")) {
        answer(true)
      }
      .buttonStyle(.borderedProminent)
      Button(role: .cancel) {
        answer(false)
      } label: {
        #if os(iOS)
          Text(verbatim: t("notify.permission.later")).frame(minHeight: 44)
        #else
          Text(verbatim: t("notify.permission.later"))
        #endif
      }
    }
    #if os(iOS)
      // A finger needs 44 pt; the regular size of the prominent button is 34.
      .controlSize(.large)
    #endif
    .appFont(.body)
    .padding(24)
    .frame(idealWidth: 420)
  }
}

@MainActor
enum NotificationPermissionPrompt {
  private static var presenting = false
  private static var waiting: [CheckedContinuation<Void, Never>] = []

  static func request(
    _ reason: NotificationPermissionReason,
    center: any NotificationPermissionCenter = SystemPermissionCenter()
  ) async -> Bool {
    let gate = NotificationPermissionGate(center: center)
    let step = await gate.step()
    if step == .allowed { return true }
    if presenting {
      await withCheckedContinuation { waiting.append($0) }
      return await request(reason, center: center)
    }
    presenting = true
    defer {
      presenting = false
      let pending = waiting
      waiting.removeAll()
      for continuation in pending { continuation.resume() }
    }
    let allow = await show(reason, settings: step == .settings)
    if step == .settings {
      if allow { openSettings() }
      return false
    }
    return await gate.answer(allow: allow)
  }

  private static func openSettings() {
    #if os(iOS)
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
    #else
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
      {
        NSWorkspace.shared.open(url)
      }
    #endif
  }

  private static func show(_ reason: NotificationPermissionReason, settings: Bool) async -> Bool {
    #if os(iOS)
      guard
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .first(where: { $0.activationState == .foregroundActive }),
        var parent = scene.windows.first(where: \.isKeyWindow)?.rootViewController
      else { return false }
      while let next = parent.presentedViewController { parent = next }
      return await withCheckedContinuation { continuation in
        let controller = UIViewController()
        let host = UIHostingController(
          rootView: NotificationPermissionSheet(
            reason: reason, settings: settings,
            answer: { allow in
              controller.dismiss(animated: true) { continuation.resume(returning: allow) }
            }))
        controller.addChild(host)
        controller.view = host.view
        host.didMove(toParent: controller)
        controller.isModalInPresentation = true
        parent.present(controller, animated: true)
      }
    #else
      guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
      return await withCheckedContinuation { continuation in
        let sheet = NSWindow()
        // dependencies: none — handed its reason and answer, it reads its language itself.
        sheet.contentViewController = NSHostingController(
          rootView: NotificationPermissionSheet(
            reason: reason, settings: settings,
            answer: { allow in
              parent.endSheet(sheet)
              continuation.resume(returning: allow)
            }))
        if let view = sheet.contentView { sheet.setContentSize(view.fittingSize) }
        parent.beginSheet(sheet)
      }
    #endif
  }
}
