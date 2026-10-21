import Foundation
import SwiftUI

/// The screens that are windows of their own on the Mac and covers on the phone.
enum AppScreen: String, Hashable, Sendable, CaseIterable {
  case analytics, reports, whatIf
  /// The settings: a window of the `Settings` scene on the Mac, the list in «Ещё» on the phone.
  case settings

  /// The id of the window scene on the Mac.
  var sceneId: String {
    switch self {
    case .analytics: "analytics"
    case .reports: "reports"
    case .whatIf: "whatif"
    case .settings: "settings"
    }
  }
}

extension Notification.Name {
  /// Asks the phone's root to cover itself with a screen; the object is the `AppScreen`.
  static let openAppScreen = Notification.Name("io.github.EvgenyBaulin.ohmymoney.openAppScreen")
}

enum AppScreens {
  /// Opens `screen` the way the platform shows it: the window on the Mac, a cover on the phone.
  @MainActor
  static func open(_ screen: AppScreen, with openWindow: OpenWindowAction) {
    #if os(macOS)
      openWindow(id: screen.sceneId)
    #else
      NotificationCenter.default.post(name: .openAppScreen, object: screen)
    #endif
  }
}

extension View {
  /// The size of a sheet: fixed on the Mac, where a sheet is a panel of its own; on a phone the
  /// sheet is as wide as the screen and as tall as its content, so none of these numbers apply.
  @ViewBuilder
  func sheetFrame(
    width: CGFloat? = nil, height: CGFloat? = nil,
    minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
    minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil
  ) -> some View {
    #if os(macOS)
      if let width {
        self.frame(width: width, height: height)
      } else {
        self.frame(
          minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth, minHeight: minHeight,
          idealHeight: idealHeight)
      }
    #else
      self
    #endif
  }
}
