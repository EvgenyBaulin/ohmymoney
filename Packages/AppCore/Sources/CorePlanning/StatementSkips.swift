import CoreKit
import Foundation

/// The accounts whose «Загрузить выписку» the owner skipped, with the day of the skip. A
/// skipped account is not asked again for `DoNowSources.statementDays` days. Plain data: the
/// screen keeps it as a small string among the habits of this Mac, nothing in the schema.
public struct StatementSkips: Hashable, Sendable {
  public private(set) var days: [UUID: DateOnly]

  public init(_ days: [UUID: DateOnly] = [:]) {
    self.days = days
  }

  /// The account was skipped less than `statementDays` days before `today`.
  public func isQuiet(_ account: UUID, today: DateOnly) -> Bool {
    guard let skipped = days[account] else { return false }
    return skipped.days(to: today) < DoNowSources.statementDays
  }

  /// «Пропустить» on `day`.
  public func skipping(_ account: UUID, on day: DateOnly) -> StatementSkips {
    var copy = self
    copy.days[account] = day
    return copy
  }

  /// The skips that still hold on `today`; the rest are forgotten so the string stays short.
  public func pruned(today: DateOnly) -> StatementSkips {
    StatementSkips(days.filter { $0.value.days(to: today) < DoNowSources.statementDays })
  }

  /// `uuid=YYYY-MM-DD` pairs, sorted, separated by commas; a pair that does not read is dropped.
  public var encoded: String {
    days.sorted { $0.key.uuidString < $1.key.uuidString }
      .map { "\($0.key.uuidString)=\($0.value.iso)" }.joined(separator: ",")
  }

  public init(encoded: String?) {
    var days: [UUID: DateOnly] = [:]
    for pair in (encoded ?? "").split(separator: ",") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
        let day = DateOnly(iso: String(parts[1]))
      else { continue }
      days[id] = day
    }
    self.init(days)
  }
}
