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
///
/// On iPhone and iPad there is a fifth choice, `system` («Как в системе»), the default there: the
/// app follows the Dynamic Type size of the device, accessibility sizes up to AX5 included. Its
/// type is the system's own at the default size and grows with `dynamicTypeSize` (`systemScale`).
public enum AppFontSize: String, CaseIterable, Sendable {
  case small
  case regular
  case large
  case xlarge
  case system

  /// The four fixed sizes of the Mac. `system` is not among them: it is offered on iPhone and iPad
  /// only (`choices`).
  public static var allCases: [AppFontSize] { [.small, .regular, .large, .xlarge] }

  /// What the picker in Settings offers on this platform.
  public static var choices: [AppFontSize] {
    #if os(iOS)
      [.system] + allCases
    #else
      allCases
    #endif
  }

  /// The size nothing was chosen for: the system's own on iPhone and iPad, «Обычный» on the Mac.
  public static var platformDefault: AppFontSize {
    #if os(iOS)
      .system
    #else
      .regular
    #endif
  }

  /// How much larger than at the default size (`.large`) the text is drawn at a Dynamic Type size:
  /// the body of iOS at that size over its body at the default, 17 pt.
  public static func systemScale(for size: DynamicTypeSize) -> CGFloat {
    let body: CGFloat =
      switch size {
      case .xSmall: 14
      case .small: 15
      case .medium: 16
      case .large: 17
      case .xLarge: 19
      case .xxLarge: 21
      case .xxxLarge: 23
      case .accessibility1: 28
      case .accessibility2: 33
      case .accessibility3: 40
      case .accessibility4: 47
      case .accessibility5: 53
      @unknown default: 17
      }
    return body / 17
  }

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
    case .regular, .system: nil
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
    case .regular, .system: .large
    case .large: .xLarge
    case .xlarge: .xxLarge
    }
  }

  /// The font of every text that does not name one; nil leaves the system's.
  public var bodyFont: Font? { bodyPoints.map { Font.system(size: $0) } }

  /// The size kept in `defaults`; «Обычный» for nothing or a word this build does not know.
  /// «Как в системе» is read on iPhone and iPad only: the Mac has no such choice.
  public static func stored(in defaults: UserDefaults?) -> AppFontSize {
    guard let stored = defaults?.string(forKey: key).flatMap(AppFontSize.init(rawValue:)) else {
      return platformDefault
    }
    #if os(iOS)
      return stored
    #else
      return stored == .system ? .regular : stored
    #endif
  }
}

/// The size of the text, applied: the dynamic type size, and the font of everything below that
/// names none — nil for «Обычный», the system's own. One shape for every choice, so a new size
/// redraws the windows and resets nothing in them.
struct AppFontSizing: ViewModifier {
  let size: AppFontSize
  /// What the device (or a test) asks for; kept as it is for `system`.
  @Environment(\.dynamicTypeSize) private var inherited

  private var textScale: CGFloat {
    size == .system ? AppFontSize.systemScale(for: inherited) : 1
  }

  func body(content: Content) -> some View {
    content
      .dynamicTypeSize(size == .system ? inherited : size.dynamicTypeSize)
      // Read by every `.appFont(_:)` below: the styles named in the views grow with the body.
      .environment(\.appFontSize, size)
      .environment(\.appTextScale, textScale)
      .font(size.bodyFont)  // font-fixed: the body of every text without a font of its own
  }
}
