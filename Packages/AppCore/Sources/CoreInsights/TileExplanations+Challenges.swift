import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation

extension TileExplanations {
  /// The table of the phrases of the challenges (their own String Catalog).
  static let challengesTable = "Challenges"

  /// «Челленджи»: each challenge not yet finished with what it counted so far — the spending it
  /// is about — and the day it ends. Nothing adds up to a total: the tile has no one sum.
  public static func challenges(
    ledger: Ledger, today: DateOnly
  ) -> TileExplanation {
    let items = ChallengeLists.ordered(
      ledger.dataset.challenges, ledger: ledger, planning: ledger.dataset.planning, today: today
    ).filter { !$0.progress.isFinished }
    guard !items.isEmpty else {
      return TileExplanation(
        tile: .challenges,
        state: .empty(TilePhrase("why.challenges.none", table: challengesTable)))
    }
    let rows = items.map { item -> TileRow in
      TileRow(
        TilePhrase("why.name", .text(item.challenge.title)),
        item.challenge.kind == .noNewSubscriptions
          ? .count(item.progress.newSubscriptionIds.count)
          : .money(item.progress.spent, .rub),
        note: TilePhrase(
          "why.challenges.ends", table: challengesTable, .day(item.challenge.end)))
    }
    return TileExplanation(tile: .challenges, sections: [TileSection(rows: rows)])
  }
}
