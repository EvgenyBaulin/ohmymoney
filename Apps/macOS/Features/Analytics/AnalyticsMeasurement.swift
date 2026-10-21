import Foundation
import Observation
import os

/// The build-time measurement of the Analytics window: with the launch argument `--measure`,
/// the time from a change of the period or the section to the moment every chart of the
/// section has appeared with the model computed for it — the first `task` of each block after
/// the model arrived, on `ContinuousClock`. The window's cache of models is bypassed then, so
/// every change measures a first build (`make bench-app`).
///
/// The result is shown in the window's subtitle and written to the log as the section, the
/// kind of period and milliseconds — never an amount, a name or a date of the data.
@MainActor
@Observable
final class AnalyticsMeasurement {
  /// On only with `--measure`; nothing is timed or logged otherwise.
  nonisolated static let isRequested = ProcessInfo.processInfo.arguments.contains("--measure")

  let isEnabled: Bool
  /// The last complete measurement, with what it measured.
  private(set) var last: Result?
  /// A change is being measured and not every chart has appeared yet.
  private(set) var isWaiting = false
  /// How many measurements have finished: `--measure-runs` makes its next change on it.
  private(set) var completed = 0

  struct Result: Equatable, Sendable {
    var label: String
    var duration: Duration

    var milliseconds: Int64 {
      let (seconds, attoseconds) = duration.components
      return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
  }

  @ObservationIgnored private let now: () -> ContinuousClock.Instant
  @ObservationIgnored private var startedAt: ContinuousClock.Instant?
  @ObservationIgnored private var label = ""
  /// The section and period of the last change measured.
  @ObservationIgnored private var subject: AnalyticsRequest.Subject?
  /// The serial of the model the charts are waited for, once it has arrived.
  @ObservationIgnored private var serial: Int?
  @ObservationIgnored private var awaited: Set<String> = []
  @ObservationIgnored private let log = Logger(
    subsystem: "io.github.EvgenyBaulin.ohmymoney", category: "measure")

  init(isEnabled: Bool = isRequested, now: @escaping () -> ContinuousClock.Instant = { .now }) {
    self.isEnabled = isEnabled
    self.now = now
  }

  /// The period or the section changed: the clock starts. `label` names what is measured —
  /// «overview month» — and nothing of the data. The same `subject` as the last one is not a
  /// change — another stored text of the same year: nothing new is computed for it, and the
  /// clock would wait for a model that never comes.
  func begin(_ label: String, for subject: AnalyticsRequest.Subject? = nil) {
    guard isEnabled else { return }
    if let subject {
      guard subject != self.subject else { return }
      self.subject = subject
    }
    startedAt = now()
    self.label = label
    serial = nil
    awaited = []
    isWaiting = true
  }

  /// A model for the change has arrived; its charts are awaited. A model arriving while
  /// nothing is measured — a light refresh of the data — is not a measurement.
  func modelArrived(serial: Int, blocks: [String]) {
    guard isEnabled, isWaiting, self.serial == nil else { return }
    self.serial = serial
    awaited = Set(blocks)
    if awaited.isEmpty { finish() }
  }

  /// The first `task` of a chart drawn from the model with this serial.
  func blockAppeared(_ block: String, serial: Int) {
    guard isEnabled, isWaiting, serial == self.serial else { return }
    awaited.remove(block)
    if awaited.isEmpty { finish() }
  }

  private func finish() {
    guard let startedAt else { return }
    let result = Result(label: label, duration: now() - startedAt)
    last = result
    isWaiting = false
    self.startedAt = nil
    serial = nil
    completed += 1
    log.notice(
      "analytics \(result.label, privacy: .public): \(result.milliseconds, privacy: .public) ms")
  }
}

/// `--measure-runs n` (`make bench-app`): the window changes the period by itself,
/// each change once the last one has been drawn — back a month and forward again, so every
/// change is a first build of twelve months of the same history. The first drawing is the
/// window's own opening, which waits for the data of the launch, and the first change is a
/// warm-up; the other `n − 1` are what counts. Then the times go where `make bench-app`
/// reads them — the folder of the data set — and the app quits.
@MainActor
final class MeasurementAutopilot {
  enum Next: Equatable {
    /// Move the period by this many steps.
    case step(Int)
    /// Everything measured: the report is ready to write (`report(operations:)`).
    case finish
  }

  let changes: Int
  private(set) var results: [AnalyticsMeasurement.Result] = []

  /// Nothing to drive without `--measure` or with fewer than two changes: a warm-up alone
  /// measures nothing.
  init?(changes: Int?) {
    guard let changes, changes >= 2 else { return nil }
    self.changes = changes
  }

  /// A drawing was timed: what the window does next.
  func measured(_ result: AnalyticsMeasurement.Result) -> Next {
    results.append(result)
    let made = results.count - 1
    if made < changes { return .step(made.isMultiple(of: 2) ? -1 : 1) }
    return .finish
  }

  /// The report of what was measured, drawn from this many live operations.
  func report(operations: Int) -> String {
    Self.report(results, operations: operations)
  }

  /// How much history was drawn first — «history · 20816 operations», so a set left empty,
  /// which draws fast, cannot pass for a measurement (`make bench-app` checks the line) —
  /// then one line per drawing and the summary last: «median 180 ms, max 212 ms (7 changes
  /// after a warm-up)». Times, what was drawn and a count — no amount, name or date.
  nonisolated static func report(
    _ results: [AnalyticsMeasurement.Result], operations: Int
  ) -> String {
    var lines = ["history · \(operations) operations"]
    for (index, result) in results.enumerated() {
      let name =
        switch index {
        case 0: "open"
        case 1: "warm-up"
        default: "change \(index - 1)"
        }
      lines.append("\(name) · \(result.label) · \(result.milliseconds) ms")
    }
    let counted = results.dropFirst(2).map(\.milliseconds).sorted()
    if let median = median(counted), let slowest = counted.last {
      lines.append(
        "median \(median) ms, max \(slowest) ms (\(counted.count) changes after a warm-up)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// The middle value, or the mean of the two middle ones.
  nonisolated static func median(_ sorted: [Int64]) -> Int64? {
    guard !sorted.isEmpty else { return nil }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }
}
