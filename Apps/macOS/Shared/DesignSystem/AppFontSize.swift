import Foundation
import SwiftUI

/// The size of the text of the whole app (Settings → Appearance → «Размер шрифта»): every window,
/// the secondary ones and the settings included, and every sheet the app hands its
/// dependencies to (`AppTheming`).
///
/// macOS draws the text styles of SwiftUI at one size whatever `dynamicTypeSize` says, so the
/// size is given twice: as the dynamic type size — the system's own way, for whatever honours
/// it — and as the font every text without one of its own is written in, at the point size of
/// the body for the choice. «Обычный» changes nothing at all: no font is set, and the app looks
/// exactly as before. Amounts keep `.monospacedDigit()` at any size: the digit width is a
/// property of the font, not of its size.
///
/// A habit of this Mac: kept in `UserDefaults` (`app.fontSize`), never in the archive.
public enum AppFontSize: String, CaseIterable, Sendable {
  case small
  case regular
  case large
  case xlarge

  /// The key of `UserDefaults`; this Mac only.
  public static let key = "app.fontSize"

  public var settingsKey: String { "settings.appearance.fontSize.\(rawValue)" }

  /// The body of the system on macOS, in points.
  public static let regularBodyPoints: CGFloat = 13

  /// The point size of a text without a font of its own; nil for «Обычный», which leaves the
  /// system's font in place.
  public var bodyPoints: CGFloat? {
    switch self {
    case .small: 11
    case .regular: nil
    case .large: 15
    case .xlarge: 17
    }
  }

  /// How much larger than the system's body the text is: 1 for «Обычный».
  public var scale: CGFloat { (bodyPoints ?? Self.regularBodyPoints) / Self.regularBodyPoints }

  /// The dynamic type size of the choice; «Обычный» is the system's default, `.large`.
  public var dynamicTypeSize: DynamicTypeSize {
    switch self {
    case .small: .small
    case .regular: .large
    case .large: .xLarge
    case .xlarge: .xxLarge
    }
  }

  /// The font of every text that does not name one; nil leaves the system's.
  public var bodyFont: Font? { bodyPoints.map { Font.system(size: $0) } }

  /// The size kept in `defaults`; «Обычный» for nothing or a word this build does not know.
  public static func stored(in defaults: UserDefaults?) -> AppFontSize {
    defaults?.string(forKey: key).flatMap(AppFontSize.init(rawValue:)) ?? .regular
  }
}

/// The size of the text, applied: the dynamic type size, and the font of everything below that
/// names none — nil for «Обычный», the system's own. One shape for every choice, so a new size
/// redraws the windows and resets nothing in them.
struct AppFontSizing: ViewModifier {
  let size: AppFontSize

  func body(content: Content) -> some View {
    content
      .dynamicTypeSize(size.dynamicTypeSize)
      // Read by every `.appFont(_:)` below: the styles named in the views grow with the body.
      .environment(\.appFontSize, size)
      .font(size.bodyFont)  // font-fixed: the body of every text without a font of its own
  }
}
