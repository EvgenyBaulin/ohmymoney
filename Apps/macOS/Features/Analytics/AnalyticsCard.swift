import AppCore
import SwiftUI

/// A card of the Analytics window: its title, the basis of its figures under it and its grey
/// figure at the right stay in every state; under them the state of its block — «Считается», a
/// failure with «Повторить», «Мало данных» with its reason, «Появится в …» — or its chart.
/// No glass: the card of the design (`analyticsCard`).
///
/// With `--measure` the card reports the first `task` of what it draws for each model to
/// `AnalyticsMeasurement`: the chart, or «Мало данных» in its place.
struct AnalyticsCard<Value: Sendable, Content: View, Accessory: View>: View {
  @Dependency(\.environment) private var environment
  /// Optional: a card shown without the window's store (a test, a preview) draws the same and
  /// only skips the measurement — SwiftUI would stop the app on a missing one.
  @Environment(AnalyticsStore.self) private var analytics: AnalyticsStore?

  let block: String
  let title: String
  var subtitle: String?
  /// The grey figure at the right of the title: «12 месяцев», «148 200 ₽», «2».
  var caption: String?
  var style: AnalyticsCardStyle = .detail
  let state: BlockState<ChartBlock<Value>>
  let retry: (() -> Void)?
  let accessory: Accessory
  let content: (Value) -> Content

  init(
    block: String, title: String, subtitle: String? = nil, caption: String? = nil,
    style: AnalyticsCardStyle = .detail, state: BlockState<ChartBlock<Value>>,
    retry: (() -> Void)?, @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder content: @escaping (Value) -> Content
  ) {
    self.block = block
    self.title = title
    self.subtitle = subtitle
    self.caption = caption
    self.style = style
    self.state = state
    self.retry = retry
    self.accessory = accessory()
    self.content = content
  }

  var body: some View {
    let serial = analytics?.serial ?? 0
    VStack(alignment: .leading, spacing: AnalyticsCardMetrics.bodyGap(style)) {
      AnalyticsCardHeader(
        title: title, subtitle: subtitle, caption: caption, style: style
      ) { accessory }
      ComputedBlock(
        title: nil, state: unwrapped, style: .plain, emptyReason: reason, retry: retry
      ) { value in
        content(value)
          .task(id: serial) { analytics?.measurement.blockAppeared(block, serial: serial) }
      }
      .frame(minHeight: 64, alignment: .topLeading)
      .task(id: reason == nil ? nil : serial) {
        // «Мало данных» stands where the chart would: it is what the section drew.
        guard reason != nil else { return }
        analytics?.measurement.blockAppeared(block, serial: serial)
      }
    }
    .analyticsCard(style)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: title))
  }

  /// The state of the block with its chart's data, or «Мало данных».
  private var unwrapped: BlockState<Value> {
    state.flatMap { block, at in
      switch block {
      case .ready(let value): .ready(value, at: at)
      case .notEnoughData: .notEnoughData
      }
    }
  }

  private var reason: String? {
    state.value?.reason.map { environment.language($0.key, table: "Analytics") }
  }
}

extension AnalyticsCard where Accessory == EmptyView {
  init(
    block: String, title: String, subtitle: String? = nil, caption: String? = nil,
    style: AnalyticsCardStyle = .detail, state: BlockState<ChartBlock<Value>>,
    retry: (() -> Void)?, @ViewBuilder content: @escaping (Value) -> Content
  ) {
    self.init(
      block: block, title: title, subtitle: subtitle, caption: caption, style: style,
      state: state, retry: retry, accessory: { EmptyView() }, content: content)
  }
}

extension BlockState where Value == AnalyticsModel {
  /// The state of one block of the section: the section's own until its model is there,
  /// then the block's data or its «Мало данных».
  func block<T: Sendable>(_ pick: (AnalyticsModel) -> ChartBlock<T>?) -> BlockState<ChartBlock<T>> {
    flatMap { model, at in pick(model).map { .ready($0, at: at) } ?? .calculating }
  }
}

/// Two cards side by side on a wide window (from about 1 000 pt), one above the other on a
/// narrow one (small charts go two in a row, wide ones always take the whole width).
struct AnalyticsPair<First: View, Second: View>: View {
  let isWide: Bool
  @ViewBuilder let first: First
  @ViewBuilder let second: Second

  var body: some View {
    let layout =
      isWide
      ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
    layout {
      first
      second
    }
  }
}

/// The two cards the design draws in Analytics. `summary` is the card of the first page of
/// «Траты» (5:36907, the phone's 5:6837): 14 inside an edge of 1, a title of 14 with its grey
/// figure at the right, 10 to the body. `detail` is the card of every other page (61:60578,
/// 61:62017, 6:108990): 16 inside the edge, a title of 15 over a line of 11, 12 to the body.
enum AnalyticsCardStyle: Hashable, Sendable {
  case summary
  case detail
}

/// The numbers of the cards of Analytics, as the frames draw them.
enum AnalyticsCardMetrics {
  /// The edge of a card: 1, inside it the margin of the style.
  static let edge: CGFloat = 1
  static func padding(_ style: AnalyticsCardStyle) -> CGFloat { style == .summary ? 14 : 16 }
  /// Between the title (with the line under it) and the body.
  static func bodyGap(_ style: AnalyticsCardStyle) -> CGFloat { style == .summary ? 10 : 12 }
  /// Between the title and the line under it.
  static let subtitleGap: CGFloat = 2
  /// Between the title and its grey figure at the right.
  static let captionGap: CGFloat = 8
  /// The radius: 12 on the Mac, 22 on a phone and a tablet, as every card of the app.
  static var radius: CGFloat { ContentCard.cornerRadius }
}

/// The type of the cards of Analytics at «Обычный»; each grows with the size chosen in Settings.
enum AnalyticsCardType {
  /// The title: 14 semibold on the summary card, 15 semibold on the others.
  static func title(_ style: AnalyticsCardStyle) -> AppFont {
    .system(size: style == .summary ? 14 : 15, weight: .semibold)
  }
  /// The grey figure at the right of the title: 12.
  static let caption = AppFont.system(size: 12).monospacedDigit()
  /// The line under the title and the notes under a body: 11.
  static let subtitle = AppFont.system(size: 11)
  /// A line of a body: its name 13, its figure 13 medium.
  static let row = AppFont.system(size: 13)
  static let rowFigure = AppFont.system(size: 13, weight: .medium).monospacedDigit()
  /// The one figure a card leads with: «72 из 100», «Хватит на 94 дня» — 17 semibold.
  static let lead = AppFont.system(size: 17, weight: .semibold).monospacedDigit()
}

/// The head of a card of Analytics: the title, its grey figure at the right, the line under the
/// title, and what the card offers beside them (a switch of the step).
struct AnalyticsCardHeader<Accessory: View>: View {
  let title: String
  var subtitle: String?
  var caption: String?
  var style: AnalyticsCardStyle = .detail
  @ViewBuilder var accessory: Accessory

  var body: some View {
    VStack(alignment: .leading, spacing: AnalyticsCardMetrics.subtitleGap) {
      HStack(alignment: .firstTextBaseline, spacing: AnalyticsCardMetrics.captionGap) {
        Text(verbatim: title)
          .appFont(AnalyticsCardType.title(style))
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
        if let caption {
          Text(verbatim: caption)
            .appFont(AnalyticsCardType.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
        accessory
      }
      if let subtitle {
        Text(verbatim: subtitle)
          .appFont(AnalyticsCardType.subtitle)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

extension AnalyticsCardHeader where Accessory == EmptyView {
  init(
    title: String, subtitle: String? = nil, caption: String? = nil,
    style: AnalyticsCardStyle = .detail
  ) {
    self.init(
      title: title, subtitle: subtitle, caption: caption, style: style, accessory: { EmptyView() })
  }
}

/// The surface of a card of Analytics: the theme's card, its edge of 1, the margin of the style
/// inside it. Content, never glass; «Увеличить контраст» adds the separator edge.
struct AnalyticsCardFrame: ViewModifier {
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.colorSchemeContrast) private var contrast
  let style: AnalyticsCardStyle

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: AnalyticsCardMetrics.radius)
    content
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(AnalyticsCardMetrics.padding(style) + AnalyticsCardMetrics.edge)
      .background(surfaces.card, in: shape)
      .overlay {
        shape.strokeBorder(surfaces.cardBorder, lineWidth: AnalyticsCardMetrics.edge)
        if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
      }
  }
}

extension View {
  func analyticsCard(_ style: AnalyticsCardStyle = .detail) -> some View {
    modifier(AnalyticsCardFrame(style: style))
  }
}
