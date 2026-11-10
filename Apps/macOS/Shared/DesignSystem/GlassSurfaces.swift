import SwiftUI

/// Liquid Glass lives only in the navigation and control layer that floats above the
/// content: the entry capsule, floating buttons, the toolbar. Lists, tables, charts and
/// report cards stay plain, and glass is never stacked on glass.
///
/// Every use of `glassEffect` in the app goes through this file, so the whole look can be
/// adjusted — or dropped to plain system materials — in one place.
public struct GlassCapsule<Content: View>: View {
  private let content: Content
  private let insets: EdgeInsets

  /// `insets`: the room inside the capsule around its content — the entry line's are the design's
  /// for each device; the bar of a selection keeps 14 × 10.
  public init(
    insets: EdgeInsets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14),
    @ViewBuilder content: () -> Content
  ) {
    self.insets = insets
    self.content = content()
  }

  public var body: some View {
    content
      .padding(insets)
      .glassEffect(.regular, in: .capsule)
  }
}

/// A floating panel that grows out of the entry capsule. It shares the capsule's
/// `GlassEffectContainer`, so the two morph into one another instead of stacking.
public struct GlassPanel<Content: View>: View {
  private let content: Content
  private let padding: CGFloat

  /// `padding`: the room inside the panel — the ↓ panel's is the design's 20.
  public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
    self.padding = padding
    self.content = content()
  }

  public var body: some View {
    content
      .padding(padding)
      .glassEffect(.regular, in: .rect(cornerRadius: 22))
  }
}
