import AppCore
import Foundation

/// «Почему так» while the hidden accounts are covered. The figure of a tile keeps all the money,
/// so its breakdown does too; a line that would name a plan of a hidden account, its operation or
/// the account itself goes, and one line «часть скрыта» without an amount stands in its place —
/// the total less the lines shown would be the hidden amount, so the folded line never says it.
///
/// `shown` is the snapshot the sheet presents (`DataSnapshot.hiding`); the whole one hides
/// nothing and the breakdown is the core's as it is.
@MainActor
enum TileWhyCover {
  /// The line that stands for what is hidden.
  static let partHiddenRow = TileRow(TilePhrase("privacy.partHidden", table: "PrivacyScreens"))

  static func covering(
    _ explanation: TileExplanation, inputs: TileInputs, shown: DataSnapshot
  ) -> TileExplanation {
    let hidden = HiddenOperations(snapshot: shown)
    guard !hidden.isEmpty, explanation.state == .ready else { return explanation }
    switch explanation.tile {
    case .upcoming:
      return upcoming(explanation, inputs: inputs, plans: HiddenPlans(snapshot: shown))
    case .expectedIncome:
      return expectedIncome(explanation, inputs: inputs, plans: HiddenPlans(snapshot: shown))
    case .lastRecord, .lastCountAndRecord:
      return lastRecord(explanation, ledger: inputs.ledger, hidden: hidden)
    case .worthALook:
      return worthALook(explanation, ledger: inputs.ledger, hidden: hidden)
    default:
      return explanation
    }
  }

  /// The payments of the week without those of a hidden account; their count is of what is
  /// listed, as on the tile.
  static func upcoming(
    _ explanation: TileExplanation, inputs: TileInputs, plans: HiddenPlans
  ) -> TileExplanation {
    let listed = UpcomingPaymentsCard.listed(inputs.planning.upcoming, hiding: plans)
    guard listed.count != inputs.planning.upcoming.count else { return explanation }
    var covered = TileExplanations.upcoming(listed)
    guard covered.state == .ready else {
      return TileExplanation(
        tile: .upcoming, sections: [TileSection(rows: [partHiddenRow])],
        notes: explanation.notes)
    }
    covered.sections[0].rows.append(partHiddenRow)
    return covered
  }

  /// The incomes expected without those that come to a hidden account; the total stays the
  /// tile's figure.
  static func expectedIncome(
    _ explanation: TileExplanation, inputs: TileInputs, plans: HiddenPlans
  ) -> TileExplanation {
    let listed = ExpectedIncomeBlock.listed(inputs.planning.expected, hiding: plans)
    guard listed.count != inputs.planning.expected.count, !explanation.sections.isEmpty else {
      return explanation
    }
    var planning = inputs.planning
    planning.expected = listed
    let shown = TileExplanations.expectedIncome(
      planning, ledger: inputs.ledger, today: inputs.today)
    var covered = explanation
    let shownSections = shown.state == .ready ? shown.sections : []
    covered.sections[0].rows = (shownSections.first?.rows ?? []) + [partHiddenRow]
    covered.sections = [covered.sections[0]] + shownSections.dropFirst()
    return covered
  }

  /// The newest operation, when it is of a hidden account, is not named nor its amount said.
  static func lastRecord(
    _ explanation: TileExplanation, ledger: Ledger, hidden: HiddenOperations
  ) -> TileExplanation {
    guard let entry = OverviewSummary.lastOperation(in: ledger.dataset), hidden.hides(entry) else {
      return explanation
    }
    var covered = explanation
    covered.sections = explanation.sections.map { section in
      guard section.title?.key == "why.record.title" else { return section }
      var section = section
      section.rows = section.rows.map { $0.label.key == "why.name" ? partHiddenRow : $0 }
      return section
    }
    return covered
  }

  /// The archived accounts with money, without a hidden one: the line is its name.
  static func worthALook(
    _ explanation: TileExplanation, ledger: Ledger, hidden: HiddenOperations
  ) -> TileExplanation {
    let names = Set(
      ledger.dataset.paymentMethods.filter { hidden.accounts.isHidden($0.id) }.map(\.name))
    guard !names.isEmpty else { return explanation }
    var covered = explanation
    covered.sections = explanation.sections.map { section in
      var section = section
      section.rows = section.rows.filter { row in
        guard row.label.key == "why.look.archived" else { return true }
        return !row.label.arguments.contains {
          if case .text(let name) = $0 { return names.contains(name) }
          return false
        }
      }
      return section
    }
    return covered
  }
}
