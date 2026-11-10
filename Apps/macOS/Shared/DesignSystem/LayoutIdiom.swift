import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// Which design a screen is laid out by: the Mac's, the phone's or the tablet's. The frames of the
/// three differ in their margins, gaps and type, so a screen reads the numbers of its own.
enum LayoutIdiom: String, Sendable, Hashable, CaseIterable {
  case mac
  case phone
  case pad

  /// The device the app runs on.
  @MainActor
  static var current: LayoutIdiom {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    #else
      .mac
    #endif
  }

  /// The idiom a view lays itself out by: the one a host or a test set, else the device's.
  @MainActor
  static func resolved(_ chosen: LayoutIdiom?) -> LayoutIdiom { chosen ?? current }
}

extension EnvironmentValues {
  /// The design to lay the screens below out by, when it is not the device's own: a test draws
  /// the tablet's frame on a phone with it. `nil` — the ordinary case — is the device's.
  @Entry var layoutIdiom: LayoutIdiom? = nil
}
