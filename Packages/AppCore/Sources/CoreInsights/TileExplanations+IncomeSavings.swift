import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation

/// The breakdowns of the tiles of «Доход и сбережения»: the savings norm and the financial
/// health. Each reads the very result the tile and the section of Analytics show, so the lines
/// come to the figure exactly.
extension TileExplanations {
  /// The table the words of these two breakdowns are in.
  public static let incomeSavingsTable = "IncomeSavings"

  private static func phrase(_ key: String, _ arguments: TileArgument...) -> TilePhrase {
    TilePhrase(key, table: incomeSavingsTable, arguments: arguments)
  }

  /// The norm of the month so far: the income less what was spent (without the money put into
  /// goals, which is put aside, not spent) is what is kept, and the kept part of the income is
  /// the rate.
  public static func savingsNorm(_ month: SavingsNormMonth) -> TileExplanation {
    guard month.state == .ready, let rate = month.rateBp else {
      return TileExplanation(tile: .savingsRate, state: .empty(phrase("why.norm.noIncome")))
    }
    var details = [
      TileRow(phrase("why.norm.rate"), .percent(rate)),
      TileRow(phrase("why.norm.goals"), money(month.goalsNetRub)),
    ]
    if month.cushionDepositsRub.raw != 0 {
      details.append(TileRow(phrase("why.norm.cushion"), money(month.cushionDepositsRub)))
    }
    var notes: [TilePhrase] = []
    if month.isPartial { notes.append(phrase("why.norm.partial")) }
    if month.earningsFallback { notes.append(phrase("why.norm.fallback")) }
    return TileExplanation(
      tile: .savingsRate,
      sections: [
        TileSection(
          rows: [
            TileRow(phrase("why.norm.income"), money(month.incomeRub), role: .plus),
            TileRow(
              phrase("why.norm.spending"), money(month.spendingWithoutGoalsRub), role: .minus),
          ], total: TileRow(phrase("why.norm.kept"), money(month.keptRub))),
        TileSection(rows: details),
      ], notes: notes)
  }

  /// The health: the points of each counted part, which come to the number. A part that cannot
  /// be counted is named, not scored.
  public static func financialHealth(_ health: FinancialHealth?) -> TileExplanation {
    guard let health else { return TileExplanation(tile: .financialHealth, state: .waiting) }
    guard let total = health.total else {
      return TileExplanation(
        tile: .financialHealth, state: .empty(phrase("why.health.notEnough")))
    }
    let counted = health.parts.filter(\.isCounted).map { score in
      TileRow(
        phrase("why.health.part.\(score.part.rawValue)", .text(String(score.maxPoints))),
        .count(score.points), role: .detail, share: score.scoreBp)
    }
    let left = health.notCounted.map { part in
      TileRow(phrase("why.health.left.\(part.rawValue)"), nil)
    }
    var sections = [
      TileSection(rows: counted, total: TileRow(phrase("why.health.total"), .count(total)))
    ]
    if !left.isEmpty {
      sections.append(TileSection(title: phrase("why.health.leftTitle"), rows: left))
    }
    return TileExplanation(
      tile: .financialHealth, sections: sections, notes: [phrase("why.health.note")])
  }
}
