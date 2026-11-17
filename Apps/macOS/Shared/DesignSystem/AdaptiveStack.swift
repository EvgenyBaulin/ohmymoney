import SwiftUI

/// A row of a title and its actions, or of a label and a value, that becomes a column at the
/// accessibility text sizes: a button of ten letters is wider than half a phone at the largest
/// size, and a row that cannot fit makes the whole page wider than the screen. Up to the largest
/// ordinary size it is the `HStack` it replaces, down to the spacing.
struct AdaptiveStack<Content: View>: View {
  @Environment(\.dynamicTypeSize) private var size
  private let alignment: VerticalAlignment
  private let columnAlignment: HorizontalAlignment
  private let spacing: CGFloat?
  private let content: Content

  init(
    alignment: VerticalAlignment = .center, columnAlignment: HorizontalAlignment = .leading,
    spacing: CGFloat? = nil, @ViewBuilder content: () -> Content
  ) {
    self.alignment = alignment
    self.columnAlignment = columnAlignment
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    // Two plain stacks rather than one `AnyLayout`: a type-erased layout has to be measured
    // again for every proposal, which made a list of cards visibly slower to lay out.
    if size.isAccessibilitySize {
      VStack(alignment: columnAlignment, spacing: spacing) { content }
    } else {
      HStack(alignment: alignment, spacing: spacing) { content }
    }
  }
}

private struct FixedSizeUnlessLargeText: ViewModifier {
  @Environment(\.dynamicTypeSize) private var size

  func body(content: Content) -> some View {
    content.fixedSize(horizontal: !size.isAccessibilitySize, vertical: false)
  }
}

extension View {
  /// `fixedSize()` — the control as wide as its words — except at the accessibility text sizes,
  /// where words wider than the screen would stretch the page: there the control takes the room
  /// it is given.
  func fixedSizeUnlessLargeText() -> some View { modifier(FixedSizeUnlessLargeText()) }
}

private struct OneLineUnlessLargeText: ViewModifier {
  @Environment(\.dynamicTypeSize) private var size

  func body(content: Content) -> some View {
    content
      .lineLimit(size.isAccessibilitySize ? nil : 1)
      .fixedSize(horizontal: !size.isAccessibilitySize, vertical: false)
  }
}

extension View {
  /// A label that keeps to one line, as wide as its words (a button of a row, a tag) — except at
  /// the accessibility text sizes, where it wraps in the room it has instead of widening its page.
  func oneLineUnlessLargeText() -> some View { modifier(OneLineUnlessLargeText()) }
}

private struct SegmentedUnlessLargeText: ViewModifier {
  @Environment(\.dynamicTypeSize) private var size

  func body(content: Content) -> some View {
    if size.isAccessibilitySize {
      content.pickerStyle(.menu)
    } else {
      content.pickerStyle(.segmented)
    }
  }
}

extension View {
  /// `.pickerStyle(.segmented)` — except at the accessibility text sizes, where the segments of
  /// a native control do not shrink and are wider than a phone: a menu takes their place.
  func segmentedUnlessLargeText() -> some View { modifier(SegmentedUnlessLargeText()) }
}

private struct ShrinksToFit: ViewModifier {
  @Environment(\.dynamicTypeSize) private var size
  let factor: CGFloat

  func body(content: Content) -> some View {
    // A one-line text with a scale factor is never narrower than that share of its own width, so
    // at the accessibility sizes a figure of 400 pt would still ask for 320. There it may shrink
    // much further, to what the row can give.
    content.minimumScaleFactor(size.isAccessibilitySize ? min(factor, 0.3) : factor)
  }
}

extension View {
  /// `minimumScaleFactor(_:)` that gives way at the accessibility text sizes (see above).
  func shrinksToFit(_ factor: CGFloat) -> some View { modifier(ShrinksToFit(factor: factor)) }
}
