import CoreKit
import Foundation

/// The numbers the model is built with. They are written into its file, so a model trained
/// under other numbers is recognisably a different model and is refused rather than misread.
public struct CategoryModelOptions: Hashable, Sendable, Codable {
  /// The model turns on at 50 labelled parts and 5 per class.
  public var minimumExamples: Int
  public var minimumPerClass: Int
  /// Above this the category is filled in; below it, only offered. Basis points.
  public var confidenceThresholdBp: Int
  /// Below this nothing is offered at all: a chip nobody would press is noise.
  public var suggestionFloorBp: Int
  /// Half a year: last winter still counts, the one before it barely does.
  public var halfLifeDays: Int
  /// Smoothing of a feature, in thousandths of an example. The vocabulary runs to tens of
  /// thousands of grams; a whole example each would drown a class that has five.
  public var featureSmoothingMilli: Int
  /// Smoothing of the prior, in thousandths. Classes are few, so one example is right.
  public var priorSmoothingMilli: Int
  /// One sighting is a coincidence; the second makes a habit.
  public var exactMinimumObservations: Int
  /// Up to three suggestions are always shown.
  public var topK: Int

  public init(
    minimumExamples: Int = 50, minimumPerClass: Int = 5, confidenceThresholdBp: Int = 6500,
    suggestionFloorBp: Int = 1500, halfLifeDays: Int = 180, featureSmoothingMilli: Int = 200,
    priorSmoothingMilli: Int = 1000, exactMinimumObservations: Int = 2, topK: Int = 3
  ) {
    self.minimumExamples = minimumExamples
    self.minimumPerClass = minimumPerClass
    self.confidenceThresholdBp = confidenceThresholdBp
    self.suggestionFloorBp = suggestionFloorBp
    self.halfLifeDays = halfLifeDays
    self.featureSmoothingMilli = featureSmoothingMilli
    self.priorSmoothingMilli = priorSmoothingMilli
    self.exactMinimumObservations = exactMinimumObservations
    self.topK = topK
  }

  public static let standard = CategoryModelOptions()
}

/// How much an example still counts for, by how long ago it was.
///
/// `weight = 1000 · 2^((day − anchor) / halfLife)`, in thousandths, worked out with integers
/// and a frozen table. A `pow` would have been shorter, but its last bits are not promised to
/// be the same on every platform — and these numbers go into a file that has to mean the same
/// thing wherever it is read.
enum Recency {
  static let unit: Int64 = 1000
  static let floor: Int64 = 1
  static let ceiling: Int64 = 64_000

  /// 2^(i/64), in thousandths.
  static let doublingTable: [Int64] = [
    1000, 1011, 1022, 1033, 1044, 1056, 1067, 1079,
    1091, 1102, 1114, 1127, 1139, 1151, 1164, 1176,
    1189, 1202, 1215, 1228, 1242, 1255, 1269, 1283,
    1297, 1311, 1325, 1340, 1354, 1369, 1384, 1399,
    1414, 1430, 1445, 1461, 1477, 1493, 1509, 1526,
    1542, 1559, 1576, 1593, 1610, 1628, 1646, 1664,
    1682, 1700, 1719, 1737, 1756, 1775, 1795, 1814,
    1834, 1854, 1874, 1895, 1915, 1936, 1957, 1978,
  ]

  /// Days between two dates, counted on the proleptic Gregorian calendar and nothing else.
  ///
  /// Not `CalendarContext`: a weight written into the model file must not depend on which
  /// time zone the owner was in when it was trained. Howard Hinnant's `days_from_civil`,
  /// which is exact for every date this application can hold.
  static func dayNumber(of day: DateOnly) -> Int {
    let year = day.month <= 2 ? day.year - 1 : day.year
    let era = (year >= 0 ? year : year - 399) / 400
    let yearOfEra = year - era * 400
    let dayOfYear = (153 * (day.month + (day.month > 2 ? -3 : 9)) + 2) / 5 + day.day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func days(from origin: DateOnly, to day: DateOnly) -> Int {
    dayNumber(of: day) - dayNumber(of: origin)
  }

  static func weight(daysFromAnchor delta: Int, halfLife: Int) -> Int64 {
    guard halfLife > 0 else { return unit }
    // Floored division, so a day before the anchor and a day after are treated alike.
    var whole = delta / halfLife
    var remainder = delta % halfLife
    if remainder < 0 {
      remainder += halfLife
      whole -= 1
    }
    let fraction = doublingTable[remainder * doublingTable.count / halfLife]
    var weight = fraction
    if whole >= 0 {
      guard whole < 32 else { return ceiling }
      weight = weight << Int64(whole)
    } else {
      guard whole > -32 else { return floor }
      weight = weight >> Int64(-whole)
    }
    return min(max(weight, floor), ceiling)
  }
}
