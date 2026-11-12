import SwiftUI

/// Keeps measured widths from feeding floating-point drift back into layout.
enum MeasuredWidth {
  static func resolve(_ proposed: CGFloat, previous: CGFloat) -> CGFloat {
    guard proposed.isFinite, abs(proposed - previous) >= 0.5 else { return previous }
    return max(0, proposed.rounded(.down))
  }
}

extension View {
  /// Store whole points only; sub-half-point changes do not invalidate layout.
  func measuredWidth(_ width: Binding<CGFloat>, inset: CGFloat = 0) -> some View {
    onGeometryChange(for: CGFloat.self) {
      $0.size.width - inset
    } action: { proposed in
      let next = MeasuredWidth.resolve(proposed, previous: width.wrappedValue)
      if next != width.wrappedValue { width.wrappedValue = next }
    }
  }
}
