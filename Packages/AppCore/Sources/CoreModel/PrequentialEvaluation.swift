import CoreKit
import Foundation

/// How good the model is, measured the only honest way: in the order the operations happened,
/// predicting each one before learning it — a split by time.
///
/// Anything else — training on everything and scoring on a slice of it — measures a model
/// that had already seen the answer. This measures the model the owner will actually have.
public enum PrequentialEvaluation {
  /// Everything in basis points, so the numbers that reach a screen or a report are integers.
  public struct Metrics: Hashable, Sendable {
    public var examples = 0
    /// Of those, the ones asked after the model had turned on. Accuracy over the cold first
    /// fifty says nothing, so the figures that matter are these.
    public var asked = 0
    public var classes = 0
    public var classesReady = 0
    public var top1Bp = 0
    public var top3Bp = 0
    /// How often the model was sure enough to fill the category in.
    public var coverageBp = 0
    /// And how often it was right when it was.
    public var precisionBp = 0
    public var macroF1Bp = 0
    /// Always answer with the commonest category of the question's kind so far.
    public var baselineMostFrequentBp = 0
    /// Answer with the last category used for the very same words, of the same kind.
    public var baselineLastSameTextBp = 0
    public var recallByClass: [UUID: Int] = [:]
    public var supportByClass: [UUID: Int] = [:]

    public init() {}
  }

  /// `anchor` is the day the recency weights are counted from; by default the day of the last
  /// example. Each question would ideally go to the model as it was on its own day, anchored
  /// at that day — the pipeline trains with today as the anchor. One anchor serves every
  /// question here, since re-anchoring means a whole training per day, and the end of the
  /// history is the nearest one to all of them. A later anchor — today, in a book left alone
  /// for a while — shrinks every weight against the smoothing and scores the past on a model
  /// the owner never had: a year after its last day the sample's top-1 falls from 0.778 to
  /// 0.750.
  public static func run(
    on examples: [CategoryExample], options: CategoryModelOptions = .standard,
    anchor: DateOnly? = nil
  ) -> Metrics {
    let ordered = examples.sorted { left, right in
      left.query.day != right.query.day
        ? left.query.day < right.query.day
        : left.partId.uuidString < right.partId.uuidString
    }
    guard let last = ordered.last else { return Metrics() }
    var model = CategoryModel(options: options, anchorDay: anchor ?? last.query.day)
    var metrics = Metrics()
    metrics.examples = ordered.count

    var asked = 0, top1 = 0, top3 = 0, applied = 0, appliedRight = 0
    var frequentRight = 0, sameTextRight = 0
    var counts: [UUID: Int] = [:]
    /// The kind each category was seen with: the entry line offers an expense only expense
    /// categories and an income only income ones, and the question here is the same.
    var kinds: [UUID: CategoryKind] = [:]
    /// By kind and words: the entry line's history level offers only categories of the kind.
    var lastForText: [String: UUID] = [:]
    var hits: [UUID: Int] = [:]
    var support: [UUID: Int] = [:]
    var predicted: [UUID: Int] = [:]

    for example in ordered {
      let kind = example.query.kind
      let sameKind = counts.filter { kinds[$0.key] == kind }
      // The answer's own category is in the tree the entry line offers from even before it is
      // first used; the model offers nothing it has seen fewer than five times anyway.
      let candidates = Set(sameKind.keys).union([example.categoryId])
      let prediction = model.predict(example.query, among: Array(candidates))
      if prediction.readiness.isOn, let best = prediction.suggestions.first {
        asked += 1
        support[example.categoryId, default: 0] += 1
        predicted[best.categoryId, default: 0] += 1
        if best.categoryId == example.categoryId {
          top1 += 1
          hits[example.categoryId, default: 0] += 1
        }
        if prediction.suggestions.contains(where: { $0.categoryId == example.categoryId }) {
          top3 += 1
        }
        if prediction.appliesTop {
          applied += 1
          if best.categoryId == example.categoryId { appliedRight += 1 }
        }
        // The two baselines are asked the same question at the same moment. A tie of the
        // commonest goes to the smallest id, as in the model's own scoring: the order a
        // dictionary walks in changes between dictionaries, launches and platforms.
        let commonest = sameKind.max { left, right in
          left.value != right.value
            ? left.value < right.value : left.key.uuidString > right.key.uuidString
        }
        if commonest?.key == example.categoryId { frequentRight += 1 }
        if let key = example.query.exactKey, lastForText["\(kind):\(key)"] == example.categoryId {
          sameTextRight += 1
        }
      }

      model.learn(example)
      counts[example.categoryId, default: 0] += 1
      kinds[example.categoryId] = kind
      if let key = example.query.exactKey { lastForText["\(kind):\(key)"] = example.categoryId }
    }

    metrics.asked = asked
    metrics.classes = counts.count
    metrics.classesReady = counts.values.filter { $0 >= options.minimumPerClass }.count
    metrics.top1Bp = share(top1, of: asked)
    metrics.top3Bp = share(top3, of: asked)
    metrics.coverageBp = share(applied, of: asked)
    metrics.precisionBp = share(appliedRight, of: applied)
    metrics.baselineMostFrequentBp = share(frequentRight, of: asked)
    metrics.baselineLastSameTextBp = share(sameTextRight, of: asked)
    metrics.supportByClass = support
    metrics.recallByClass = support.reduce(into: [:]) { result, entry in
      result[entry.key] = share(hits[entry.key] ?? 0, of: entry.value)
    }
    metrics.macroF1Bp = macroF1(hits: hits, support: support, predicted: predicted)
    return metrics
  }

  static func share(_ part: Int, of whole: Int) -> Int {
    guard whole > 0 else { return 0 }
    return Int((Double(part) / Double(whole) * 10_000).rounded())  // stats-only
  }

  /// The unweighted mean of the per-class F1: a category the owner uses twice a year counts
  /// as much as the one they use every day, which is the point of asking for it. The classes
  /// are added up in the order of their ids: floating-point addition is not associative, and
  /// the dictionary's own order would move the last basis point between runs.
  static func macroF1(hits: [UUID: Int], support: [UUID: Int], predicted: [UUID: Int]) -> Int {
    guard !support.isEmpty else { return 0 }
    var total = 0.0  // stats-only
    for (id, count) in support.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      let right = Double(hits[id] ?? 0)  // stats-only
      let recall = count > 0 ? right / Double(count) : 0  // stats-only
      let offered = Double(predicted[id] ?? 0)  // stats-only
      let precision = offered > 0 ? right / offered : 0  // stats-only
      total += precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0  // stats-only
    }
    return Int((total / Double(support.count) * 10_000).rounded())  // stats-only
  }
}
