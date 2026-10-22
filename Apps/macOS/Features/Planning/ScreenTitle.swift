import AppCore
import SwiftUI

/// How the screens of Planning, Calendar, Capital and a trip adapt to the width they are given.
/// `windowWidth` is the width of the whole window (0 while unknown): on the phone it is the screen,
/// on the Mac the window, so one rule serves both.
enum ScreenWidth {
  /// Below this the screen is a phone's: actions fold into one menu, controls take a full line.
  static let compactBelow: CGFloat = 640

  static func isCompact(_ width: CGFloat) -> Bool { width > 0 && width < compactBelow }
}

/// The title of a screen and its one-line subtitle. Touch devices show the large title of the
/// design (the navigation bar then keeps no title of its own, see `screenNavigationTitle`); the
/// Mac keeps the compact one its window already has.
struct ScreenTitleBlock: View {
  let title: String
  var subtitle: String?
  var identifier: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: title)
        .appFont(Self.titleStyle)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(identifier ?? "screen.title")
      if let subtitle {
        Text(verbatim: subtitle)
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private static var titleStyle: AppFont {
    #if os(iOS)
      .largeTitle.bold()
    #else
      .title2.bold()
    #endif
  }
}

extension View {
  /// The title of the screen in the Mac window's title bar; on touch devices the screen draws the
  /// large title itself, so the navigation bar's own is left empty instead of saying it twice.
  func screenNavigationTitle(_ title: String) -> some View {
    #if os(iOS)
      navigationTitle("")
    #else
      navigationTitle(title)
    #endif
  }
}
