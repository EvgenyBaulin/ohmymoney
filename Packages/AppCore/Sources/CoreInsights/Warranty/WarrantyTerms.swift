import CoreAnalytics
import CoreKit
import CoreParse
import Foundation

/// The spans the warranty and the return term are counted in, from the day of the purchase.
public enum WarrantyTerms {
  /// The last day of `term` that starts on `day`: «гарантия 2г» bought on 29 October 2026 ends
  /// on 29 October 2028; a month that is shorter clips the day (31 March + 1 month = 28 February).
  public static func end(of term: TermReading, from day: DateOnly) -> DateOnly {
    switch term.unit {
    case .day: day.adding(days: term.count)
    case .week: day.adding(days: 7 * term.count)
    case .month: day.adding(months: term.count)
    case .year: day.adding(months: 12 * term.count)
    }
  }

  /// The quick choices next to the field «Гарантия до»: «+1 год», «+2 года», «+3 года».
  public static let warrantyPresets: [TermReading] = [
    TermReading(count: 1, unit: .year), TermReading(count: 2, unit: .year),
    TermReading(count: 3, unit: .year),
  ]

  /// The quick choices next to the field «Вернуть можно до»: «+14 дней», «+30 дней».
  public static let returnPresets: [TermReading] = [
    TermReading(count: 14, unit: .day), TermReading(count: 30, unit: .day),
  ]
}
