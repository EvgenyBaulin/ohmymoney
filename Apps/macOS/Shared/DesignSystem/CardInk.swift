import SwiftUI

/// How much a line of text on a coloured card gives way to the main figure. Named levels keep
/// the numbers out of the money views, which must not hold a `Double`.
enum CardInkLevel {
  case caption, line, note

  fileprivate var strength: Double {
    switch self {
    case .caption: 0.88
    case .line: 0.9
    case .note: 0.75
    }
  }
}

/// The depth of the shadow under a card of the overview.
enum CardShadowDepth {
  case soft, deep

  fileprivate var strength: Double {
    switch self {
    case .soft: 0.16
    case .deep: 0.22
    }
  }
}

extension View {
  /// A line of text on a coloured card, a little behind the main figure.
  func cardInk(_ level: CardInkLevel) -> some View {
    opacity(level.strength)
  }

  /// The shadow under a card of the overview.
  func cardShadow(_ depth: CardShadowDepth, radius: CGFloat, y: CGFloat) -> some View {
    shadow(color: .black.opacity(depth.strength), radius: radius, y: y)
  }
}
