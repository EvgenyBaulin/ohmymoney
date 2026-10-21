// Umbrella module: the macOS app and the tests import `AppCore` only, while the code is
// split into focused targets so several people (or agents) can work without colliding.
@_exported import CoreAccounting
@_exported import CoreAnalytics
@_exported import CoreArchive
@_exported import CoreCSV
@_exported import CoreGuide
@_exported import CoreInsights
@_exported import CoreKit
@_exported import CoreLog
@_exported import CoreModel
@_exported import CoreParse
@_exported import CorePipeline
@_exported import CorePlanning
@_exported import CoreRates
@_exported import CoreSample

public enum AppCoreInfo {
  /// Bumped when the meaning of the golden fixtures changes.
  public static let version = "0.1.0"
}
