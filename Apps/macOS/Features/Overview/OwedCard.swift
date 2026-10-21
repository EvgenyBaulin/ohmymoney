import AppCore
import SwiftUI

/// Parts I paid for somebody else that have not come back. When nobody owes anything the
/// card stays and says so — the grid does not rearrange itself — and offers no button, as
/// there is nothing to close.
///
/// Money back may cover a part only in part: the part waits for the rest, and the card counts
/// what is left of it, never the whole part again. What came back of such parts is said under
/// the figure, so 1 500 ₽ owed with 700 ₽ back reads «800 ₽ · уже вернули часть: 700 ₽».
struct OwedCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let actions: OperationActions

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .owedToMe, environment), state: compute.states.owed,
      fillsHeight: true, retry: { compute.retry(ComputeStep.owed) }
    ) { owed in
      if owed.count > 0 {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: environment.money.rounded(owed.amount))
              .appFont(.title2.monospacedDigit())
            Text(
              verbatim: environment.language.format(
                "owed.count", table: "Entry", counts: owed.count)
            )
            .appFont(.caption)
            .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          if let partly = partlyReturned(under: owed) {
            Text(verbatim: partly)
              .appFont(.caption)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          // Content, not a floating control: a plain small button, never glass.
          Button(environment.language("reimbursement.title", table: "Entry")) {
            actions.recordingReimbursement = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      } else {
        Text(verbatim: environment.language("overview.owedNobody", table: "Overview"))
          .foregroundStyle(.secondary)
      }
    }
  }

  /// «уже вернули часть: 700 ₽» while some owed part has had money back and waits for the
  /// rest; `nil` otherwise, and while the figure above is of other data than the lists'.
  private func partlyReturned(under figure: OwedSummary) -> String? {
    guard let ledger = compute.snapshot?.ledger,
      let returned = OwedPartly(ledger).returned(under: figure)
    else { return nil }
    return environment.language.format(
      "overview.owedPartlyReturned", table: "Overview", environment.money.rounded(returned))
  }
}

/// The owed parts some money already came back for, which wait for the rest: how many, what
/// came back and what is left. The rule of «owed» is `OwedParts` — an expected part with
/// something left of it —, the summary's too, so the card and the summary agree.
struct OwedPartly: Hashable, Sendable {
  var count = 0
  var returnedRub: AmountE4 = .zero
  var remainingRub: AmountE4 = .zero
  /// Everything owed by that rule, in the same pass: what the card's figure says when it is
  /// of the same data.
  var owed = OwedSummary()

  init(_ ledger: Ledger) {
    for part in OwedParts(ledger).parts {
      owed.amount += part.remainingRub
      owed.count += 1
      guard part.returnedRub.raw > 0 else { continue }
      count += 1
      returnedRub += part.returnedRub
      remainingRub += part.remainingRub
    }
  }

  /// What came back of the parts still owed, to say under `figure` — the card's figure,
  /// counted by a step of its own. `nil` when nothing came back, or when the figure is of
  /// other data than this ledger (a step counted from an older read): the line would tell
  /// another story than the number above it.
  func returned(under figure: OwedSummary) -> AmountE4? {
    guard returnedRub.raw > 0, figure == owed else { return nil }
    return returnedRub
  }
}
