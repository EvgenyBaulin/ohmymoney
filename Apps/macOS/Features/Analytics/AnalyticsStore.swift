import AppCore
import Foundation
import Observation

/// The models of one Analytics window: the one on screen and the ones already built.
/// A model is computed off the main thread through `ComputeStore.compute(_:)`
/// and kept by what it was computed for and the generation of the data, so going back to a
/// section or a period is instant; a new generation — a write, a reload, a full run — makes
/// every older model useless, and they are dropped. `--measure` bypasses the cache, so every
/// change is a first build (`AnalyticsMeasurement`).
@MainActor
@Observable
final class AnalyticsStore {
  /// What a model is kept by: the request and the generation of the data it was built
  /// from (`ComputeStore.generation`, which grows whenever the data on screen changes).
  struct Key: Hashable, Sendable {
    var request: AnalyticsRequest
    var generation: Int
  }

  /// The last model delivered, and when.
  private(set) var model: AnalyticsModel?
  private(set) var modelAt: Date?
  /// Grows with every model delivered: the charts key their first `task` on it.
  private(set) var serial = 0

  let measurement: AnalyticsMeasurement
  @ObservationIgnored private var cache = ModelCache<AnalyticsModel>()

  init(measurement: AnalyticsMeasurement = AnalyticsMeasurement()) {
    self.measurement = measurement
  }

  var bypassesCache: Bool { measurement.isEnabled }

  /// The model for `key`: from the cache, or built off the main thread. A newer call
  /// cancels this one (`.task(id:)`), and a cancelled build never lands; until the new model
  /// is there, the old one stays — a write does not send the charts back to «Считается».
  func load(_ key: Key, ledger: Ledger, compute: ComputeStore) async {
    if !bypassesCache, let cached = cache.model(for: key) {
      deliver(cached)
      return
    }
    let request = key.request
    // `AnalyticsBuilder.model` does not throw: the only error here is the cancellation by a newer
    // request, whose model must not land. A builder that could fail would need `try` inside
    // the closure, and a state with «Повторить» for it — not a `try?` that waits for ever.
    guard
      let built = try? await compute.compute({ AnalyticsBuilder.model(request, ledger: ledger) }),
      !Task.isCancelled
    else { return }
    if !bypassesCache { cache.store(built, for: key) }
    deliver(built)
  }

  /// A model on screen: the charts it feeds are awaited by the measurement.
  func deliver(_ model: AnalyticsModel, at instant: Date = Date()) {
    self.model = model
    modelAt = instant
    serial += 1
    measurement.modelArrived(serial: serial, blocks: model.blockIDs)
  }

  /// What the blocks of a section show:
  ///
  /// * the state of the data step while it is not ready — «Считается» until the first data
  ///   and during a full run, its failure with «Повторить»;
  /// * for the forecast, the state of the forecast step as well, and for the anomalies the
  ///   state of theirs;
  /// * the model once one was built for this section, period and day; a model of another
  ///   period or section is never shown for this one — until the new one is there, «Считается».
  ///   A model of an older generation of the same request is: a light refresh keeps the
  ///   numbers on screen until the new ones are there.
  nonisolated static func state<Data: Sendable>(
    for wanted: AnalyticsRequest, data: BlockState<Data>,
    forecast: BlockState<MonthForecast.Remainder>?,
    anomalies: BlockState<AnomalyReport>? = nil, model: AnalyticsModel?, at: Date?
  ) -> BlockState<AnalyticsModel> {
    if let waiting = data.waiting { return waiting.never() }
    if let forecast, let waiting = forecast.waiting { return waiting.never() }
    if let anomalies, let waiting = anomalies.waiting { return waiting.never() }
    guard let model, let at, model.request.section == wanted.section,
      model.request.period == wanted.period, model.request.today == wanted.today
    else { return .calculating }
    return .ready(model, at: at)
  }
}

extension BlockState where Value == Never {
  /// A state without a value as the state of any block: it is never `ready`.
  func never<Other: Sendable>() -> BlockState<Other> {
    switch self {
    case .calculating: .calculating
    case .failed(let key): .failed(messageKey: key)
    case .notEnoughData: .notEnoughData
    case .plannedFor(let stage): .plannedFor(stage: stage)
    }
  }
}

/// Models kept by their key. Only the newest generation of the data is worth keeping: an
/// older one is never asked for again, so storing a model drops them. Beyond `capacity` the
/// model used longest ago goes.
struct ModelCache<Value> {
  var capacity = 32
  private var values: [AnalyticsStore.Key: Value] = [:]
  private var order: [AnalyticsStore.Key] = []

  var count: Int { values.count }

  mutating func model(for key: AnalyticsStore.Key) -> Value? {
    guard let value = values[key] else { return nil }
    order.removeAll { $0 == key }
    order.append(key)
    return value
  }

  mutating func store(_ value: Value, for key: AnalyticsStore.Key) {
    let stale = values.keys.filter { $0.generation < key.generation }
    for old in stale { values[old] = nil }
    order.removeAll { $0.generation < key.generation || $0 == key }
    values[key] = value
    order.append(key)
    while order.count > capacity {
      values[order.removeFirst()] = nil
    }
  }
}
