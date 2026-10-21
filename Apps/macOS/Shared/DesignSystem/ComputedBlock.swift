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

  let title: String?
  let state: BlockState<Value>
  let style: Style
  /// A card in a row of a grid takes the height of the row, so the cards of a row line up.
  let fillsHeight: Bool
  /// The one line under «Мало данных» that says why, when there is one to say.
  let emptyReason: String?
  /// «Повторить» for a failed block; `nil` shows the message alone.
  let retry: (() -> Void)?
  let content: (Value) -> Content

  init(
    title: String?, state: BlockState<Value>, style: Style = .card, fillsHeight: Bool = false,
    emptyReason: String? = nil, retry: (() -> Void)?,
    @ViewBuilder content: @escaping (Value) -> Content
  ) {
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
    VStack(alignment: .leading, spacing: 8) {
      if let title {
        Text(verbatim: title)
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
      }
      bodyOfState
        .frame(minHeight: style == .card ? 64 : nil, alignment: .topLeading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
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
          .foregroundStyle(.red)
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

/// The card every block of content stands on: the secondary background, radius 12, 14 pt of
/// margin — no glass, content is never glass. «Увеличить контраст» adds a 1 pt edge in the
/// colour of separators, without which a card melts into a light window. The cards of
/// Overview and the chart cards of Analytics share it, so they look the same.
struct ContentCard: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  let fillsHeight: Bool

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
      .padding(14)
      .background(.background.secondary, in: .rect(cornerRadius: 12))
      .overlay {
        if contrast == .increased {
          RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1)
        }
      }
  }
}

extension View {
  func contentCard(fillsHeight: Bool = false) -> some View {
    modifier(ContentCard(fillsHeight: fillsHeight))
  }
}
