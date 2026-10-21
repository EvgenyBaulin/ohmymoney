import AppCore
import SwiftUI

/// A card of the Analytics window: its title in `.headline` and the basis of its figures in
/// `.caption` stay in every state; under them the state of its block — «Считается», a
/// failure with «Повторить», «Мало данных» with its reason, «Появится в …» — or its chart.
/// No glass: it stands on the same card as the blocks of Overview (`contentCard`).
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
  let state: BlockState<ChartBlock<Value>>
  let retry: (() -> Void)?
  let accessory: Accessory
  let content: (Value) -> Content

  init(
    block: String, title: String, subtitle: String? = nil, state: BlockState<ChartBlock<Value>>,
    retry: (() -> Void)?, @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder content: @escaping (Value) -> Content
  ) {
    self.block = block
    self.title = title
    self.subtitle = subtitle
    self.state = state
    self.retry = retry
    self.accessory = accessory()
    self.content = content
  }

  var body: some View {
    let serial = analytics?.serial ?? 0
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: title)
            .appFont(.headline)
            .accessibilityAddTraits(.isHeader)
          if let subtitle {
            Text(verbatim: subtitle)
              .appFont(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        accessory
      }
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
    .contentCard()
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
    block: String, title: String, subtitle: String? = nil, state: BlockState<ChartBlock<Value>>,
    retry: (() -> Void)?, @ViewBuilder content: @escaping (Value) -> Content
  ) {
    self.init(
      block: block, title: title, subtitle: subtitle, state: state, retry: retry,
      accessory: { EmptyView() }, content: content)
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
