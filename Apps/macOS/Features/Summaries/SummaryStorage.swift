import AppCore
import Foundation

/// What this Mac remembers about the summaries: which kinds the owner wants to be told about,
/// and which summaries were already opened or put away. A habit of the device, not data of the
/// books — `UserDefaults`, never the archive. The shown ones are kept per data set, so a trial
/// set never marks the real book's summaries as seen.
struct SummaryStorage {
  static let weekKey = "summaries.week.enabled"
  static let monthKey = "summaries.month.enabled"
  static let yearKey = "summaries.year.enabled"
  static let shownKey = "summaries.shown"

  /// The most summaries remembered as shown: older ones are past the time they are offered.
  static let rememberedLimit = 80

  let defaults: UserDefaults
  /// `.<data set>` or empty.
  let suffix: String

  init(defaults: UserDefaults = .standard, suffix: String? = nil) {
    self.defaults = defaults
    self.suffix = suffix ?? AppPaths.dataSet.map { ".\($0.rawValue)" } ?? ""
  }

  /// Every kind is on until the owner turns it off.
  var switches: SummarySwitches {
    SummarySwitches(
      week: flag(Self.weekKey), month: flag(Self.monthKey), year: flag(Self.yearKey))
  }

  func setEnabled(_ enabled: Bool, for kind: SummaryKind) {
    defaults.set(enabled, forKey: Self.key(for: kind))
  }

  static func key(for kind: SummaryKind) -> String {
    switch kind {
    case .week: weekKey
    case .month: monthKey
    case .year: yearKey
    }
  }

  private func flag(_ key: String) -> Bool {
    defaults.object(forKey: key) as? Bool ?? true
  }

  /// Oldest first.
  private var shownList: [String] {
    defaults.stringArray(forKey: Self.shownKey + suffix) ?? []
  }

  var shown: Set<SummaryID> {
    Set(shownList.compactMap(SummaryID.init(raw:)))
  }

  func markShown(_ id: SummaryID) {
    var list = shownList.filter { $0 != id.description }
    list.append(id.description)
    defaults.set(Array(list.suffix(Self.rememberedLimit)), forKey: Self.shownKey + suffix)
  }
}
