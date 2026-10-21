import CoreKit
import Foundation

/// The lines `make eval-model` prints.
///
/// Identifiers and numbers only. A category's name would be the owner's data, and this output
/// exists to be pasted into a report — so the classes are numbered and named by their id.
public enum EvaluationReport {
  public static func text(of metrics: PrequentialEvaluation.Metrics, milliseconds: Int) -> String {
    var lines: [String] = []
    func row(_ name: String, _ value: String) {
      lines.append(name.padding(toLength: 24, withPad: " ", startingAt: 0) + value)
    }
    func share(_ name: String, _ bp: Int) { row(name, fraction(bp)) }

    row("examples", "\(metrics.examples)   (asked after the model turned on: \(metrics.asked))")
    row("classes", "\(metrics.classes)   (with >= 5 examples: \(metrics.classesReady))")
    share("top-1 accuracy", metrics.top1Bp)
    share("top-3 hit rate", metrics.top3Bp)
    share("coverage", metrics.coverageBp)
    share("precision when filled", metrics.precisionBp)
    share("macro-F1", metrics.macroF1Bp)
    share("baseline most-frequent", metrics.baselineMostFrequentBp)
    share("baseline last-same-text", metrics.baselineLastSameTextBp)
    lines.append("recall by class")
    let ordered = metrics.supportByClass.sorted { left, right in
      left.value != right.value
        ? left.value > right.value : left.key.uuidString < right.key.uuidString
    }
    for (index, entry) in ordered.enumerated() {
      let recall = fraction(metrics.recallByClass[entry.key] ?? 0)
      let short = String(entry.key.uuidString.prefix(8)).lowercased()
      lines.append("  \(index + 1)  \(short)  \(recall)  (\(entry.value))")
    }
    row("elapsed", "\(milliseconds / 1000).\(String(format: "%03d", milliseconds % 1000)) s")
    return lines.joined(separator: "\n")
  }

  /// «Кривая "покрытие — точность"» (промт, раздел 4): how much the model would fill in at
  /// each threshold, and how often it would be right. The threshold is a setting, and this is
  /// what there is to choose it by.
  public static func curve(
    of examples: [CategoryExample], thresholds: [Int] = Self.thresholds
  )
    -> String
  {
    var lines = ["threshold  coverage  precision  (of \(examples.count) examples)"]
    for threshold in thresholds {
      var options = CategoryModelOptions.standard
      options.confidenceThresholdBp = threshold
      let metrics = PrequentialEvaluation.run(on: examples, options: options)
      lines.append(
        "    \(fraction(threshold))     \(fraction(metrics.coverageBp))     "
          + "\(fraction(metrics.precisionBp))")
    }
    return lines.joined(separator: "\n")
  }

  public static let thresholds = [3_000, 5_000, 6_500, 8_000, 9_000, 9_500]

  /// Basis points as a plain three-digit fraction: 8123 → «0.812».
  static func fraction(_ bp: Int) -> String {
    let rounded = (bp + 5) / 10
    return "0.\(String(format: "%03d", min(rounded, 1000)))"
      .replacingOccurrences(of: "0.1000", with: "1.000")
  }
}
