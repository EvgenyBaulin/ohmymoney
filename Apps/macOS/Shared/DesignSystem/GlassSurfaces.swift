import SwiftUI

/// Liquid Glass lives only in the navigation and control layer that floats above the
/// content: the entry capsule, floating buttons, the toolbar. Lists, tables, charts and
/// report cards stay plain, and glass is never stacked on glass.
///
/// Every use of `glassEffect` in the app goes through this file, so the whole look can be
/// adjusted — or dropped to plain system materials — in one place.
public struct GlassCapsule<Content: View>: View {
  private let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    content
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .glassEffect(.regular, in: .capsule)
  }
}

/// A floating panel that grows out of the entry capsule. It shares the capsule's
/// `GlassEffectContainer`, so the two morph into one another instead of stacking.
public struct GlassPanel<Content: View>: View {
  private let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    content
      .padding(16)
      .glassEffect(.regular, in: .rect(cornerRadius: 22))
  }
}
