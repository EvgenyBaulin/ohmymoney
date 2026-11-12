import CoreAnalytics
import CoreKit
import CoreModel
import Foundation
import Synchronization

/// «Model quality»: the metrics of the category model and the backtest of the forecast.
///
/// Both halves are measured the same way — on the owner's own history, by asking before
/// learning and by forecasting from a past day only. Nothing here is a claim about how good
/// the app is; it is what the app scored on this particular book.
public struct ModelQuality: Hashable, Sendable {
  /// What the category model is worth on this history.
  public struct Categories: Hashable, Sendable {
    public var readiness: CategoryModelReadiness
    /// Labelled operations the model may learn from.
    public var examples: Int
    /// What it scored, asking before learning. `nil` while the model is off: a model that
    /// says nothing has nothing to be right or wrong about.
    public var metrics: PrequentialEvaluation.Metrics?
    /// What the owner chose when the model had offered something.
    public var choices: Choices
    public var months: [PrequentialEvaluation.Month]

    public init(
      readiness: CategoryModelReadiness, examples: Int,
      metrics: PrequentialEvaluation.Metrics? = nil, choices: Choices = Choices(),
      months: [PrequentialEvaluation.Month] = []
    ) {
      self.readiness = readiness
      self.examples = examples
      self.metrics = metrics
      self.choices = choices
      self.months = months
    }
  }

  /// The owner's choices of a category against what the model offered (`category_feedback`)
  /// — the one figure measured on the owner's own clicks rather than on history replayed:
  /// every choice is written to `category_feedback`, and migration 0003 keeps the confidence
  /// «so «Качество модели» can say how sure it is when it is wrong».
  public struct Choices: Hashable, Sendable {
    /// Choices made, on operations still in the book.
    public var made: Int
    /// Of them, the ones filed elsewhere than the model offered first.
    public var overruled: Int
    /// How sure the model was when it was overruled: the median, in basis points. `nil` when
    /// it was never overruled.
    public var confidenceWhenOverruledBp: Int?

    public init(made: Int = 0, overruled: Int = 0, confidenceWhenOverruledBp: Int? = nil) {
      self.made = made
      self.overruled = overruled
      self.confidenceWhenOverruledBp = confidenceWhenOverruledBp
    }

    /// Only the choices of parts the book still has: a deleted operation is no longer what
    /// the model is measured on.
    static func of(_ dataset: Dataset) -> Choices {
      let live = Set(
        dataset.entries.filter { $0.transaction.deletedAt == nil }.flatMap { $0.parts.map(\.id) })
      let made = dataset.feedback.filter { $0.partId.map(live.contains) ?? false }
      let overruled = made.filter(\.overrulesTheModel)
      let sure = overruled.compactMap(\.confidenceBp).sorted()
      let median: Int? =
        sure.isEmpty
        ? nil
        : sure.count.isMultiple(of: 2)
          ? (sure[sure.count / 2 - 1] + sure[sure.count / 2]) / 2 : sure[sure.count / 2]
      return Choices(
        made: made.count, overruled: overruled.count, confidenceWhenOverruledBp: median)
    }
  }

  public var categories: Categories
  public var forecast: ForecastBacktest

  public init(categories: Categories, forecast: ForecastBacktest) {
    self.categories = categories
    self.forecast = forecast
  }

  /// Measures both halves. Pure and off the main thread, like every other section of
  /// Analytics — and not a step of the pipeline: this is looked at now and then, not with
  /// every write.
  ///
  /// What the replay of the history costs — most of a second — depends on the examples and the
  /// options and on nothing else, so it is kept (`ModelQualityCache`) and worked out again only
  /// when an example the model learns from has changed: a write that adds a purchase, say, and
  /// does not touch what the model is filed from, costs the examples and a digest of them. The
  /// forecast half is cached the same way (`ForecastBacktest.cached`).
  public static func build(
    ledger: Ledger, today: DateOnly, options: CategoryModelOptions = .standard,
    cache: ModelQualityCache = .shared
  ) -> ModelQuality {
    let examples = LedgerTraining.examples(of: ledger)
    let measured = cache.measurement(of: examples, options: options) {
      // Readiness is counts of examples, whatever the anchor; the metrics are measured at the
      // end of the history, the anchor nearest to the days the questions were asked
      // (`PrequentialEvaluation.run`).
      let readiness = CategoryModel.train(on: examples, anchor: today, options: options).readiness
      let report =
        readiness.isOn ? PrequentialEvaluation.report(on: examples, options: options) : nil
      return ModelQualityCache.Measurement(readiness: readiness, report: report)
    }
    return ModelQuality(
      categories: Categories(
        readiness: measured.readiness, examples: examples.count,
        metrics: measured.report?.metrics, choices: Choices.of(ledger.dataset),
        months: measured.report?.months ?? []),
      forecast: ForecastBacktest.cached(ledger: ledger, today: today))
  }
}

/// The last measurement of the category model, by the examples and the options it was made on.
public final class ModelQualityCache: Sendable {
  struct Measurement: Sendable {
    var readiness: CategoryModelReadiness
    var report: PrequentialEvaluation.Report?
  }

  public static let shared = ModelQualityCache()

  private struct Held {
    var key: Int?
    var measurement: Measurement?
    var hits = 0
    var misses = 0
  }

  private let held = Mutex(Held())

  public init() {}

  /// How many measurements came from the cache and how many were made.
  public var counts: (hits: Int, misses: Int) { held.withLock { ($0.hits, $0.misses) } }

  /// A number that is the same for the same examples and options, in any order — the replay puts
  /// them in its own — within one run of the program (`Hasher` is seeded at every start).
  static func key(of examples: [CategoryExample], options: CategoryModelOptions) -> Int {
    var combined = 0
    for example in examples {
      var hasher = Hasher()
      hasher.combine(example)
      combined &+= hasher.finalize()
    }
    var hasher = Hasher()
    hasher.combine(combined)
    hasher.combine(examples.count)
    hasher.combine(options)
    return hasher.finalize()
  }

  func measurement(
    of examples: [CategoryExample], options: CategoryModelOptions,
    make: () -> Measurement
  ) -> Measurement {
    let key = Self.key(of: examples, options: options)
    let known: Measurement? = held.withLock { held in
      guard held.key == key, let measurement = held.measurement else {
        held.misses += 1
        return nil
      }
      held.hits += 1
      return measurement
    }
    if let known { return known }
    let made = make()
    held.withLock { held in
      held.key = key
      held.measurement = made
    }
    return made
  }
}
