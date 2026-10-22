import AppCore
import Foundation
import Observation

/// What the tiles of 2.0 read, kept once for every tile and for «Почему так»: the figures counted
/// from the ledger of the data step's snapshot (`OverviewFigures`), the state of the copies, the
/// check of the database and the rates (`OverviewSystemStatus`), and the limit of a small purchase
/// from the settings. A tile and its breakdown take the same instance, so the total of «Почему
/// так» is the figure of the tile by construction (0376).
///
/// The figures are counted once per snapshot and limit — a tile that comes after another one
/// finds them ready — and on the main thread: they are a few passes over the month's rows.
@MainActor
@Observable
final class OverviewFiguresStore {
  static let shared = OverviewFiguresStore()

  /// The most a purchase may cost to be small; `nil` while the owner has not said.
  private(set) var smallLimit: AmountE4?
  /// The newest copy of the database and how many there are.
  private(set) var backupAt: Date?
  private(set) var backupCount = 0

  @ObservationIgnored
  private var cache: (version: DataVersion, limit: AmountE4?, figures: OverviewFigures)?

  init() {}

  /// The figures of `snapshot`, counted once for it and the limit.
  func figures(for snapshot: DataSnapshot) -> OverviewFigures {
    if let cache, cache.version == snapshot.version, cache.limit == smallLimit {
      return cache.figures
    }
    let figures = OverviewFigures(
      ledger: snapshot.ledger, today: snapshot.today, smallLimit: smallLimit,
      expectedIncome: snapshot.planning.income.expectedRemaining)
    cache = (snapshot.version, smallLimit, figures)
    return figures
  }

  /// The state of the copies, the check and the rates now.
  func systemStatus(
    for snapshot: DataSnapshot, environment: AppEnvironment
  ) -> OverviewSystemStatus {
    let record = environment.integrity?.record
    // The newest rate of any currency but the ruble: the day the bank last spoke for.
    let ratesDay = snapshot.context.rateDays.filter { $0.key != .rub }.values.max()
    return OverviewSystemStatus(
      now: environment.now(), today: snapshot.today, backupAt: backupAt, backupCount: backupCount,
      checkedAt: record?.checkedAt, problems: record?.report.problemCount ?? 0,
      ratesDay: ratesDay)
  }

  /// What the books of `snapshot` say about the functions the self-showing tiles hang on.
  func facts(for snapshot: DataSnapshot) -> OverviewFacts {
    var features: Set<OverviewFeature> = []
    let planning = snapshot.planning
    if snapshot.owed.count > 0 { features.insert(.owedToMe) }
    if !planning.debts.iOwe.isEmpty { features.insert(.iOwe) }
    if planning.income.expectedRemaining.raw > 0 { features.insert(.expectedIncome) }
    if !planning.overdue.isEmpty { features.insert(.overdue) }
    if !planning.creditCards.isEmpty { features.insert(.creditCard) }
    if snapshot.dataset.tripSettings.activeEventId != nil { features.insert(.trip) }
    if snapshot.dataset.paymentMethods.contains(where: { !$0.archived && $0.interest != nil }) {
      features.insert(.deposit)
    }
    if !planning.expected.isEmpty { features.insert(.salary) }
    if !planning.allocationOffers.isEmpty { features.insert(.incomeToAllocate) }
    if OverviewCurrencyBalances(planning.accounts).isMultiCurrency {
      features.insert(.multiCurrency)
    }
    if smallLimit != nil { features.insert(.smallLimit) }
    return OverviewFacts(features)
  }

  // MARK: - Reading the outside

  /// Reads the limit of a small purchase and the copies of the database; the tiles follow.
  func refresh(environment: AppEnvironment) async {
    if let settings = environment.settings {
      let stored = (try? settings.string(OverviewSettings.smallPurchaseLimitKey)) ?? nil
      let limit = OverviewSettings.smallPurchaseLimit(from: stored)
      if limit != smallLimit { smallLimit = limit }
    }
    if let folder = await environment.backups?.folder {
      let list = await Task.detached(priority: .utility) { BackupList.load(in: folder) }.value
      let newest = list.items.first?.copy.moment
      if newest != backupAt { backupAt = newest }
      if list.count != backupCount { backupCount = list.count }
    }
  }

  /// Writes the limit of a small purchase — whole rubles, `nil` or zero for none — as a setting,
  /// no step of ⌘Z. Returns whether it was written; the tiles follow.
  @discardableResult
  func saveSmallLimit(_ whole: Int64?, environment: AppEnvironment) -> Bool {
    let text = OverviewSettings.text(forSmallPurchaseLimit: whole)
    let written = environment.attempt("settings.overview", on: environment.settings) {
      try $0.set(OverviewSettings.smallPurchaseLimitKey, to: text)
    }
    if written { smallLimit = OverviewSettings.smallPurchaseLimit(from: text) }
    return written
  }
}
