import AppCore
import SwiftUI

/// What a card of the spending sections found out: a result to draw, or the reason there is
/// nothing to draw (already in words, shown under «Мало данных»).
enum SpendingOutcome<Value: Sendable>: Sendable {
  case ready(Value)
  case empty(reason: String)

  /// The block state this outcome stands for, delivered `at` the given moment.
  func state(at moment: Date = Date()) -> BlockState<SpendingOutcome<Value>> {
    switch self {
    case .ready: .ready(self, at: moment)
    case .empty: .notEnoughData
    }
  }

  var reason: String? {
    if case .empty(let text) = self { return text }
    return nil
  }
}

/// A card of the spending sections: its title and the basis of its figures stay in every state;
/// under them the state of its block — «Считается», a failure with «Повторить», «Мало данных»
/// with the reason, or the content.
///
/// The figures come from `ComputeStore.analysis` (off the main thread, kept per version of the
/// data), asked again when the request, the data or the day changes — never in `body`. No
/// glass: it stands on the same card as the blocks of Overview (`contentCard`).
struct SpendingBlock<Request: Hashable & Sendable, Value: Sendable, Content: View, Accessory: View>:
  View
{
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  let identifier: String
  let title: String
  var subtitle: String?
  /// What is asked for: a new request starts a new calculation.
  let request: Request
  let fetch: (DataSnapshot, Request) async throws -> SpendingOutcome<Value>
  let accessory: Accessory
  let content: (Value) -> Content

  @State private var state: BlockState<SpendingOutcome<Value>> = .calculating
  @State private var attempt = 0

  init(
    identifier: String, title: String, subtitle: String? = nil, request: Request,
    fetch: @escaping (DataSnapshot, Request) async throws -> SpendingOutcome<Value>,
    @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder content: @escaping (Value) -> Content
  ) {
    self.identifier = identifier
    self.title = title
    self.subtitle = subtitle
    self.request = request
    self.fetch = fetch
    self.accessory = accessory()
    self.content = content
  }

  private struct TaskKey: Hashable {
    var request: Request
    var generation: Int
    var dataReady: Bool
    var attempt: Int
  }

  var body: some View {
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
        title: nil, state: unwrapped, style: .plain, emptyReason: reason,
        retry: { attempt += 1 }
      ) { outcome in
        if case .ready(let value) = outcome { content(value) }
      }
      .frame(minHeight: 64, alignment: .topLeading)
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityIdentifier(identifier)
    .task(
      id: TaskKey(
        request: request, generation: compute.generation,
        dataReady: compute.states.data.phase == .ready, attempt: attempt)
    ) { await load() }
  }

  private var unwrapped: BlockState<SpendingOutcome<Value>> { state }

  private var reason: String? {
    guard case .notEnoughData = state else { return nil }
    return lastReason
  }

  @State private var lastReason: String?

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    do {
      let outcome = try await fetch(snapshot, request)
      guard !Task.isCancelled else { return }
      lastReason = outcome.reason
      state = outcome.state()
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      state = .failed(messageKey: "compute.failed.data")
    }
  }
}

extension SpendingBlock where Accessory == EmptyView {
  init(
    identifier: String, title: String, subtitle: String? = nil, request: Request,
    fetch: @escaping (DataSnapshot, Request) async throws -> SpendingOutcome<Value>,
    @ViewBuilder content: @escaping (Value) -> Content
  ) {
    self.init(
      identifier: identifier, title: title, subtitle: subtitle, request: request, fetch: fetch,
      accessory: { EmptyView() }, content: content)
  }
}
