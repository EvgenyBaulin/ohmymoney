import SwiftUI

/// A block whose content the pipeline or `compute(...)` calculates: a card of Overview, a
/// chart of Analytics, a table of Reports.
///
/// The title stays in every state; only the body changes: «Считается, ожидайте», a message
/// with «Повторить», «Мало данных», «Появится в …», or the content. No glass: content is
/// never glass. The body is at least 64 pt tall, so a grid of cards does not jump when they
/// turn ready. The state is never told by colour alone — every one has a symbol and words.
///
/// How it reads with the accessibility settings:
/// * «Уменьшить прозрачность» changes nothing: the card has no material, and its background
///   is opaque already;
/// * «Увеличить контраст» adds a 1 pt edge in the colour of separators, without which a
///   card melts into a light window;
/// * VoiceOver meets a container named by the title, then the state in words — the
///   spinner is labelled «Считается, ожидайте» — and «Повторить» as a button of its own.
struct ComputedBlock<Value: Sendable, Content: View>: View {
  enum Style {
    /// A card: its own background, rounded, with a margin.
    case card
    /// The body alone, for the middle of a window or of a list.
    case plain
  }

  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.cardStyle) private var cardStyle
  @Environment(\.tileIsCompact) private var compact

  let title: String?
  let state: BlockState<Value>
  let style: Style
  /// A card in a row of a grid takes the height of the row, so the cards of a row line up.
  let fillsHeight: Bool
  /// The one line under «Мало данных» that says why, when there is one to say.
  let emptyReason: String?
  /// «Повторить» for a failed block; `nil` shows the message alone.
  let retry: (() -> Void)?
  /// When the value shown was counted, for a value counted from data older than the last
  /// write (`ComputeStore.States.asOf`): a grey «цифры от 14:32» beside the title. `nil` — the
  /// ordinary case — shows nothing.
  let asOf: Date?
  let content: (Value) -> Content

  init(
    title: String?, state: BlockState<Value>, style: Style = .card, fillsHeight: Bool = false,
    emptyReason: String? = nil, asOf: Date? = nil, retry: (() -> Void)?,
    @ViewBuilder content: @escaping (Value) -> Content
  ) {
    self.asOf = state.phase == .ready ? asOf : nil
    self.title = title
    self.state = state
    self.style = style
    self.fillsHeight = fillsHeight
    self.emptyReason = emptyReason
    self.retry = retry
    self.content = content
  }

  var body: some View {
    switch style {
    case .card:
      stack.contentCard(fillsHeight: fillsHeight)
    case .plain:
      stack
    }
  }

  private var stack: some View {
    VStack(alignment: .leading, spacing: lineGap) {
      if title != nil || asOf != nil {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if let title {
            Text(verbatim: title)
              .appFont(titleFont)
              .foregroundStyle(titleInk)
              .accessibilityAddTraits(.isHeader)
          }
          if let asOf {
            Spacer(minLength: 4)
            Text(verbatim: ComputedBlockText.asOf(asOf, environment))
              .appFont(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("block.asOf")
          }
        }
      }
      bodyOfState
        .frame(minHeight: style == .card ? 64 : nil, alignment: .topLeading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
  }

  /// A tile has 6 between its lines, a compact one 3; any other card 8.
  private var lineGap: CGFloat {
    guard cardStyle == .tile else { return 8 }
    return compact ? StyleMetrics.compactTileGap : StyleMetrics.tileGap
  }

  /// The title of a tile is in the primary ink; of a compact tile and any other card, grey.
  private var titleInk: Color {
    cardStyle == .tile && !compact ? surfaces.primary : surfaces.secondary
  }

  /// A tile is titled in 15 semibold, a compact one in the grey 11 of its caption.
  private var titleFont: AppFont {
    guard cardStyle == .tile else { return .caption }
    return compact ? StyleType.compactTitle : StyleType.tileTitle
  }

  @ViewBuilder
  private var bodyOfState: some View {
    switch state {
    case .ready(let value, _):
      content(value)
    case .calculating:
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(Text(verbatim: environment.language("common.calculating")))
        Text(verbatim: environment.language("common.calculating"))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    case .failed(let messageKey):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.octagon")
          .foregroundStyle(surfaces.negative)
          .accessibilityHidden(true)
        Text(verbatim: environment.language(messageKey))
          .fixedSize(horizontal: false, vertical: true)
        if let retry {
          Spacer(minLength: 8)
          Button(environment.language("action.retry"), action: retry)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
      }
    case .notEnoughData:
      VStack(alignment: .leading, spacing: 4) {
        Label {
          Text(verbatim: environment.language("common.noData"))
        } icon: {
          Image(systemName: "hourglass")
        }
        if let emptyReason {
          Text(verbatim: emptyReason)
            .appFont(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .foregroundStyle(.secondary)
    case .plannedFor(let stage):
      Label {
        Text(verbatim: environment.format("compute.plannedFor", stage))
      } icon: {
        Image(systemName: "hammer")
      }
      .foregroundStyle(.secondary)
    }
  }
}

extension ComputedBlock where Content == EmptyView, Value == Never {
  /// A list or a window waiting for its first data: the state without a value.
  init(waiting state: BlockState<Never>, retry: (() -> Void)?) {
    self.init(title: nil, state: state, style: .plain, retry: retry, content: Self.noContent)
  }

  /// A waiting block is never ready, so there is no content to build.
  private static func noContent(_ value: Never) -> EmptyView {}
}

/// How a card is drawn: the quiet card of a list or a chart, or a tile of a screen's grid — the
/// tile of the one style has its title in 15 semibold over the figures and a 1 pt outline.
enum CardStyle: Hashable {
  case plain
  case tile
}

extension EnvironmentValues {
  /// Set by a grid of tiles (Overview) for every card in it; every other card stays plain.
  @Entry var cardStyle: CardStyle = .plain
  /// Set by a compact tile — one figure of a pair: its name and caption grey 11, 12 of margin.
  @Entry var tileIsCompact = false
}

/// The card every block of content stands on: the secondary background, radius 12, 14 pt of
/// margin — no glass, content is never glass. «Увеличить контраст» adds a 1 pt edge in the
/// colour of separators, without which a card melts into a light window. The cards of
/// Overview and the chart cards of Analytics share it, so they look the same.
struct ContentCard: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.appTheme) private var theme
  @Environment(\.cardStyle) private var style
  @Environment(\.layoutIdiom) private var idiom
  @Environment(\.tileIsCompact) private var compact
  let fillsHeight: Bool

  /// 12 pt on the Mac; the phone design rounds its cards to 22 and lifts them with a soft shadow.
  static var cornerRadius: CGFloat {
    #if os(iOS)
      22
    #else
      StyleMetrics.cardRadius
    #endif
  }

  /// The edge of a card: a tile wears the theme's outline at 1 pt, every other card its own
  /// hairline at half a point.
  static func edge(_ style: CardStyle) -> (width: CGFloat, outline: Bool) {
    style == .tile ? (StyleMetrics.cardBorder, true) : (0.5, false)
  }

  /// The edge of a card on a design: a tile of the phone's frame wears the hairline token at
  /// 1 pt instead of the outline.
  enum Edge: Equatable { case outline, hairline, cardBorder }
  static func edge(
    _ style: CardStyle, idiom: LayoutIdiom
  ) -> (width: CGFloat, ink: Edge) {
    switch style {
    case .tile:
      (
        StyleMetrics.cardBorder,
        OverviewPageMetrics.of(idiom).tileEdgeIsHairline ? .hairline : .outline
      )
    case .plain: (0.5, .cardBorder)
    }
  }

  /// The soft shadow under a card of a phone and a tablet; the tiles of Overview have none, as
  /// their frames draw them.
  static func hasShadow(_ style: CardStyle, idiom: LayoutIdiom) -> Bool {
    idiom != .mac && style == .plain
  }

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
    let design = LayoutIdiom.resolved(idiom)
    let edge = Self.edge(style, idiom: design)
    let ink: Color =
      switch edge.ink {
      case .outline: theme.borderOutline
      case .hairline: theme.borderHairline
      case .cardBorder: surfaces.cardBorder
      }
    content
      .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
      .padding(
        style == .tile && compact ? StyleMetrics.compactTilePadding : StyleMetrics.tilePadding
      )
      .background(surfaces.card, in: shape)
      #if os(iOS)
        .shadow(
          color: .black.opacity(Self.hasShadow(style, idiom: design) ? 0.05 : 0), radius: 10, y: 6)
      #endif
      .overlay {
        // The theme's own edge always; under «Увеличить контраст» the separator edge too.
        shape.strokeBorder(ink, lineWidth: edge.width)
        if contrast == .increased {
          shape.strokeBorder(.separator, lineWidth: 1)
        }
      }
  }
}

extension View {
  func contentCard(fillsHeight: Bool = false) -> some View {
    modifier(ContentCard(fillsHeight: fillsHeight))
  }
}

/// The words of a block whose numbers are older than the data.
@MainActor
enum ComputedBlockText {
  /// «цифры от 14:32», or «цифры от 17 сент., 14:32» when the value was not counted today.
  static func asOf(_ instant: Date, _ environment: AppEnvironment) -> String {
    let today = environment.calendar.day(of: instant) == environment.today
    let moment = today ? environment.dates.time(instant) : environment.dates.moment(instant)
    return environment.format("common.asOf", table: "Common", moment)
  }
}
