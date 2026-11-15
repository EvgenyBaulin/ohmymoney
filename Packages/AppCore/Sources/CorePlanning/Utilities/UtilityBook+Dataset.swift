import CoreAnalytics
import CoreKit
import Foundation

extension Dataset {
  public static let utilitiesKey = "utilities.book"

  /// The meters, readings, bills and charges of the home, as the database holds them.
  public var utilities: UtilityBook {
    get { extras.value(Self.utilitiesKey) ?? UtilityBook() }
    set { extras.set(newValue, for: Self.utilitiesKey) }
  }
}
