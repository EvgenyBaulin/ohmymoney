import AppCore
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// The window darkened around one place: a light window cut out at the place's frame with a
/// soft edge, and beside it the words — what to press and why — with an arrow at the place.
/// Clicks inside the cut-out reach the control under it, and move to the next step when the
/// step is a click; clicks anywhere else are held. A step whose place no root of the window
/// shows gets its words in the middle, a lighter shade and no hold: the place is a button of
/// the toolbar or of another window, and the owner has to be able to press it. The shade is a
/// plain colour, never glass.
struct GuideSpotlight: View {
  @Dependency(\.environment) private var environment
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  let guide: GuideStore
  let walk: GuideWalkthrough
  let anchors: [String: Anchor<CGRect>]
  let proxy: GeometryProxy
  /// The main root of the window: it speaks of a place no root shows and tells VoiceOver each
  /// step.
  let primary: Bool

  private var russian: Bool { environment.language.resolvedCode.hasPrefix("ru") }

  var body: some View {
    let step = walk.current
    let bounds = CGRect(origin: .zero, size: proxy.size)
    let insets = proxy.safeAreaInsets
    let hole = anchors[step.target].map { proxy[$0] }
    let elsewhere = hole == nil && guide.isShown(step.target)
    let speaks = hole != nil || (primary && !elsewhere)
    let maxWidth = GuideCaptionPlacement.maxWidth(in: bounds.size)
    let edge = GuideCaptionPlacement.edge(
      for: hole, size: CGSize(width: maxWidth, height: GuideCaptionPlacement.estimatedHeight),
      in: bounds)
    ZStack(alignment: .topLeading) {
      GuideShade(
        hole: hole?.offsetBy(dx: insets.leading, dy: insets.top),
        holds: hole != nil || elsewhere
      )
      .ignoresSafeArea()
      if let hole {
        GuideHoleWatcher { guide.clicked(step.target) }
          .frame(width: hole.width, height: hole.height)
          .position(x: hole.midX, y: hole.midY)
          .accessibilityHidden(true)
        if contrast == .increased {
          RoundedRectangle(cornerRadius: GuideShade.cornerRadius)
            .stroke(Color.white, lineWidth: 2)
            .frame(width: hole.width + 4, height: hole.height + 4)
            .position(x: hole.midX, y: hole.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        if let edge {
          GuideArrow(edge: edge)
            .position(GuideCaptionPlacement.arrowPoint(hole: hole, edge: edge, in: bounds))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      if speaks {
        GuideCaptionLayout(hole: hole, edge: edge, maxWidth: maxWidth) {
          GuideCaptionCard(
            step: step, position: walk.position, isLast: walk.isLast, russian: russian,
            next: { guide.next() }, exit: { guide.endWalk() })
        }
        .frame(width: bounds.width, height: bounds.height)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: walk)
    .onChange(of: walk, initial: true) { _, walk in
      guard primary else { return }
      let step = walk.current
      let words = [step.text.text(russian: russian), step.why?.text(russian: russian)]
        .compactMap { $0 }.joined(separator: ". ")
      AccessibilityNotification.Announcement(words).post()
    }
  }
}

/// The shade over a root: everything but the cut-out, whose edge fades over a few points. With
/// `holds` it takes every click outside the cut-out; without, it lets them all through.
struct GuideShade: View {
  nonisolated static let cornerRadius: CGFloat = 8
  /// How far the soft edge reaches outside the place: inside it the place stays fully lit.
  nonisolated static let softness: CGFloat = 6

  let hole: CGRect?
  let holds: Bool

  var body: some View {
    let shade = Rectangle()
      .fill(Color.black.opacity(holds ? 0.55 : 0.3))
      .mask {
        ZStack {
          Rectangle()
          if let hole {
            RoundedRectangle(cornerRadius: Self.cornerRadius + Self.softness)
              .frame(
                width: hole.width + 2 * Self.softness, height: hole.height + 2 * Self.softness
              )
              .position(x: hole.midX, y: hole.midY)
              .blur(radius: Self.softness / 2)
              .blendMode(.destinationOut)
          }
        }
        .compositingGroup()
      }
      .accessibilityHidden(true)
    if holds {
      shade
        .contentShape(GuideCutOut(hole: hole), eoFill: true)
        .onTapGesture {}
    } else {
      shade.allowsHitTesting(false)
    }
  }
}

/// The whole root with the place cut out of it, for the clicks the shade holds.
struct GuideCutOut: Shape {
  let hole: CGRect?

  /// The cut-out is square here though drawn round: a click in its corner reaches the control
  /// and is heard by the cut-out's watcher alike, never one without the other.
  func path(in rect: CGRect) -> Path {
    var path = Path(rect)
    if let hole { path.addRect(hole) }
    return path
  }
}

/// The small triangle between the place and its words, pointing at the place.
private struct GuideArrow: View {
  let edge: Edge

  var body: some View {
    Image(systemName: "arrowtriangle.up.fill")
      .font(.system(size: 14))  // font-fixed: the arrow is placed by its size
      .foregroundStyle(.background)
      .shadow(radius: 1)
      .rotationEffect(rotation)
  }

  /// The caption is on `edge` of the place, so the arrow points the other way.
  private var rotation: Angle {
    switch edge {
    case .bottom: .degrees(0)
    case .top: .degrees(180)
    case .trailing: .degrees(-90)
    case .leading: .degrees(90)
    }
  }
}

/// The words of a step: «Шаг 1 из 2», what to press, why, its keys, «Далее» or «Готово», and
/// the way out. VoiceOver reads it as one element and its two buttons by their names.
struct GuideCaptionCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.colorSchemeContrast) private var contrast
  let step: GuideHint
  let position: (number: Int, total: Int)
  let isLast: Bool
  let russian: Bool
  let next: () -> Void
  let exit: () -> Void

  private func t(_ key: String) -> String { environment.language(key, table: "Guide") }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if position.total > 1 {
        Text(verbatim: String(format: t("guide.spot.step"), position.number, position.total))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Text(verbatim: step.text.text(russian: russian))
        .appFont(.headline)
        .fixedSize(horizontal: false, vertical: true)
      if let why = step.why {
        Text(verbatim: why.text(russian: russian))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        if let keys = step.keys {
          Text(verbatim: keys)
            .appFont(.callout.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.background.secondary))
            .accessibilityLabel(Text(verbatim: keys))
        }
        Spacer(minLength: 4)
        Button(t("guide.spot.exit"), action: exit)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("guide.spot.exit")
        Button(isLast ? t("guide.spot.done") : t("guide.next"), action: next)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("guide.spot.next")
      }
      .controlSize(.small)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(.background))
    .overlay {
      if contrast == .increased {
        RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1)
      }
    }
    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      Text(
        verbatim: [step.text.text(russian: russian), step.why?.text(russian: russian)]
          .compactMap { $0 }.joined(separator: ". "))
    )
    .accessibilityIdentifier("guide.spot.caption")
  }
}

/// Lays the words out beside the place: measured at the width they may take, placed by
/// `GuideCaptionPlacement`. Nothing measured goes back into the layout around it.
struct GuideCaptionLayout: Layout {
  let hole: CGRect?
  let edge: Edge?
  let maxWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
      let frame = GuideCaptionPlacement.frame(
        size: CGSize(width: maxWidth, height: size.height), hole: hole, edge: edge,
        in: CGRect(origin: .zero, size: bounds.size))
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
        proposal: ProposedViewSize(frame.size))
    }
  }
}

/// Where the words of a step go: below the place when there is room, else above, else beside
/// it, always inside the root; in the middle when the root does not show the place.
enum GuideCaptionPlacement {
  /// From the edges of the root.
  static let margin: CGFloat = 12
  /// Between the place and the words: room for the arrow.
  static let gap: CGFloat = 16
  /// The height the words are taken to need when choosing their side: two or three lines and
  /// the buttons.
  static let estimatedHeight: CGFloat = 150

  /// The width the words may take in a root of `size`.
  static func maxWidth(in size: CGSize) -> CGFloat {
    max(120, min(320, size.width - 2 * margin))
  }

  /// The side of the place the words go to; nil without a place (the middle).
  static func edge(for hole: CGRect?, size: CGSize, in bounds: CGRect) -> Edge? {
    guard let hole else { return nil }
    let below = bounds.maxY - hole.maxY
    let above = hole.minY - bounds.minY
    let after = bounds.maxX - hole.maxX
    let before = hole.minX - bounds.minX
    let tall = size.height + gap + margin
    let wide = size.width + gap + margin
    if below >= tall { return .bottom }
    if above >= tall { return .top }
    if after >= wide { return .trailing }
    if before >= wide { return .leading }
    return below >= above ? .bottom : .top
  }

  /// The frame of the words of `size` on `edge` of the place, kept inside the root: never off
  /// the window, at worst over the place itself when the root has no room beside it.
  static func frame(size: CGSize, hole: CGRect?, edge: Edge?, in bounds: CGRect) -> CGRect {
    let width = min(size.width, max(0, bounds.width - 2 * margin))
    let height = min(size.height, max(0, bounds.height - 2 * margin))
    var origin: CGPoint
    if let hole, let edge {
      switch edge {
      case .bottom: origin = CGPoint(x: hole.midX - width / 2, y: hole.maxY + gap)
      case .top: origin = CGPoint(x: hole.midX - width / 2, y: hole.minY - gap - height)
      case .trailing: origin = CGPoint(x: hole.maxX + gap, y: hole.midY - height / 2)
      case .leading: origin = CGPoint(x: hole.minX - gap - width, y: hole.midY - height / 2)
      }
    } else {
      origin = CGPoint(x: bounds.midX - width / 2, y: bounds.midY - height / 2)
    }
    origin.x = clamp(origin.x, bounds.minX + margin, bounds.maxX - margin - width)
    origin.y = clamp(origin.y, bounds.minY + margin, bounds.maxY - margin - height)
    return CGRect(origin: origin, size: CGSize(width: width, height: height))
  }

  /// The centre of the arrow: in the gap between the place and its words, kept inside the root.
  static func arrowPoint(hole: CGRect, edge: Edge, in bounds: CGRect) -> CGPoint {
    let half = gap / 2
    let point: CGPoint
    switch edge {
    case .bottom: point = CGPoint(x: hole.midX, y: hole.maxY + half)
    case .top: point = CGPoint(x: hole.midX, y: hole.minY - half)
    case .trailing: point = CGPoint(x: hole.maxX + half, y: hole.midY)
    case .leading: point = CGPoint(x: hole.minX - half, y: hole.midY)
    }
    return CGPoint(
      x: clamp(point.x, bounds.minX + half, bounds.maxX - half),
      y: clamp(point.y, bounds.minY + half, bounds.maxY - half))
  }

  private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
    high < low ? low : min(max(value, low), high)
  }
}

/// An invisible view exactly over the cut-out that hears the clicks landing in it — without
/// taking them: the control under it gets the click all the same, and the walk moves on after.
#if os(macOS)
  struct GuideHoleWatcher: NSViewRepresentable {
    let clicked: @MainActor @Sendable () -> Void

    func makeNSView(context: Context) -> GuideHoleView {
      let view = GuideHoleView()
      view.clicked = clicked
      return view
    }

    func updateNSView(_ nsView: GuideHoleView, context: Context) {
      nsView.clicked = clicked
    }

    static func dismantleNSView(_ nsView: GuideHoleView, coordinator: ()) {
      nsView.stopListening()
    }
  }

  final class GuideHoleView: NSView {
    var clicked: (@MainActor @Sendable () -> Void)?
    private var monitor: Any?

    /// Never the target of a click: the control under the cut-out is.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopListening()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        MainActor.assumeIsolated { _ = self?.hears(event) }
        return event
      }
    }

    func stopListening() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    /// Whether the click lands in the cut-out of this window; if it does, the walk moves on once
    /// the click has reached its control.
    @discardableResult
    func hears(_ event: NSEvent) -> Bool {
      guard event.type == .leftMouseDown, let window, event.window === window,
        bounds.contains(convert(event.locationInWindow, from: nil))
      else { return false }
      let clicked = clicked
      DispatchQueue.main.async { MainActor.assumeIsolated { clicked?() } }
      return true
    }
  }
#else
  /// A touch has no pointer to listen to: the step moves on with «Далее».
  struct GuideHoleWatcher: View {
    let clicked: @MainActor @Sendable () -> Void
    var body: some View { Color.clear.allowsHitTesting(false) }
  }
#endif
