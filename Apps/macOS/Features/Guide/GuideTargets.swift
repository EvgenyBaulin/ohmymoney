import AppCore
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// The places the guide points at: a view marks itself `.guideTarget("entry.line")`, and the
/// root of the window learns where it is. While the guide points at a place — a step of a task
/// of the tutorial, «Показать, куда нажимать», «Показать, где» of a card — the root darkens
/// around it (`GuideSpotlight`).
struct GuideTargetKey: PreferenceKey {
  static let defaultValue: [String: Anchor<CGRect>] = [:]
  static func reduce(
    value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { first, _ in first }
  }
}

extension View {
  /// Marks the place the guide may point at, by the id its steps use (`GuideTarget`).
  func guideTarget(_ id: String) -> some View {
    modifier(GuideTargetMark(id: id))
  }

  /// The root of a window, or of a column of it: darkened around the place of the current step,
  /// with the words beside it. `toolbar`: the main root of the window, under the toolbar — the
  /// one that speaks of a place no root shows (a button of the toolbar, another window) and
  /// tells VoiceOver each step.
  func guideOverlay(_ guide: GuideStore, toolbar: Bool = false) -> some View {
    overlayPreferenceValue(GuideTargetKey.self) { anchors in
      GeometryReader { proxy in
        GuideRoot(guide: guide, anchors: anchors, proxy: proxy, primary: toolbar)
      }
    }
  }
}

/// A marked place: its frame for the root, and — while the guide points at it — a way to bring
/// it into view when a scroll view holds it out of sight.
private struct GuideTargetMark: ViewModifier {
  let id: String

  func body(content: Content) -> some View {
    content
      // Added to what the views inside report, never in place of it: a marked list holds a
      // marked search field.
      .transformAnchorPreference(key: GuideTargetKey.self, value: .bounds) { places, anchor in
        places[id] = anchor
      }
      .background {
        #if os(macOS)
          if GuideStore.shared.walk?.current.target == id { GuideScrollIntoView() }
        #endif
      }
  }
}

#if os(macOS)
  /// Scrolls the scroll view that holds it until its place is in sight; nothing when it is.
  private struct GuideScrollIntoView: NSViewRepresentable {
    final class Marker: NSView {
      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // After the layout that placed it: before it the frame is still zero.
        DispatchQueue.main.async { [weak self] in
          guard let self, self.window != nil, self.enclosingScrollView != nil else { return }
          self.scrollToVisible(self.bounds)
        }
      }
    }

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ nsView: Marker, context: Context) {}
  }
#endif

/// One root of the window: it tells the store which places it shows, and darkens itself while
/// the guide points at something.
private struct GuideRoot: View {
  let guide: GuideStore
  let anchors: [String: Anchor<CGRect>]
  let proxy: GeometryProxy
  let primary: Bool

  private var root: String { primary ? "main" : "side" }

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.clear
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: Set(anchors.keys), initial: true) { _, ids in
          guide.placesShown(ids, in: root)
        }
        // A root that goes shows nothing: its places must not hold the window of another.
        .onDisappear { guide.placesShown([], in: root) }
      if let walk = guide.walk {
        GuideSpotlight(guide: guide, walk: walk, anchors: anchors, proxy: proxy, primary: primary)
      }
    }
  }
}

/// Esc leaves the place the guide points at.
struct GuideWhereToClickKeys: ViewModifier {
  let guide: GuideStore

  func body(content: Content) -> some View {
    content.background {
      if guide.walk != nil {
        Button("") { guide.endWalk() }
          .keyboardShortcut(.cancelAction)
          .opacity(0)
          .accessibilityHidden(true)
      }
    }
  }
}
