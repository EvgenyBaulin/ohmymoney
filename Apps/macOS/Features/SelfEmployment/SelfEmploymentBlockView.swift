import AppCore
import SwiftUI

/// The block «Самозанятость» of the planning: the income of the month, the tax to pay and by
/// when with «Заплатить…», the deduction left and what is left of the limit of the year. Nothing
/// while self-employment is off. The planning registers it as one of its blocks.
struct SelfEmploymentBlockView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var paying: PayingMonth?

  var body: some View {
    let snapshot = compute.snapshot
    let npd = snapshot?.planning.npd
    let today = snapshot?.today ?? environment.today
    if let npd, let block = SelfEmploymentBlock.build(npd: npd, today: today) {
      VStack(alignment: .leading, spacing: 8) {
        SelfEmploymentFigures(block: block, year: npd.year)
        if let month = SelfEmploymentActions.prefill(npd, today: today), month.state != .accruing {
          HStack {
            if let gap = npd.months.last(where: { $0.fnsGapE4 != nil })?.fnsGapE4 {
              Text(verbatim: SelfEmploymentFigures.gapText(gap, environment))
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(AllocationText.t("npd.pay.open", environment)) {
              paying = PayingMonth(month: month)
            }
            .accessibilityIdentifier("selfEmployed.pay")
          }
        } else if let gap = npd.months.last(where: { $0.fnsGapE4 != nil })?.fnsGapE4 {
          Text(verbatim: SelfEmploymentFigures.gapText(gap, environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityIdentifier("selfEmployed.block")
      .sheet(item: $paying) { paying in
        NPDPaymentSheet(month: paying.month)
          .handingOver(dependencies)
      }
    }
  }
}

/// A month of the tax the form of a payment is open for.
struct PayingMonth: Identifiable {
  var month: NPDMonth
  var id: MonthKey { month.month }
}

/// The figures of the block and of the tile, one look for both.
struct SelfEmploymentFigures: View {
  @Dependency(\.environment) private var environment
  let block: SelfEmploymentBlock
  let year: NPDYear
  var compact = false

  var body: some View {
    let money = environment.money
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(AllocationText.t("selfEmployed.block.income", environment)) {
        Text(verbatim: money.rounded(block.monthIncomeRub)).monospacedDigit()
      }
      LabeledContent(AllocationText.t("selfEmployed.block.tax", environment)) {
        VStack(alignment: .trailing, spacing: 0) {
          Text(verbatim: "≈ " + money.rounded(block.taxToPayE4))
            .monospacedDigit()
          if let due = block.due {
            Text(
              verbatim: AllocationText.format(
                "selfEmployed.block.due", environment, environment.dates.dayAndMonth(due))
            )
            .appFont(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
      if !compact {
        LabeledContent(AllocationText.t("selfEmployed.block.deduction", environment)) {
          Text(
            verbatim: block.deductionLeftE4.map { money.rounded($0) }
              ?? AllocationText.t("selfEmployed.block.deductionUnknown", environment)
          )
          .monospacedDigit()
        }
      }
      LabeledContent(AllocationText.t("selfEmployed.block.yearLeft", environment)) {
        HStack(spacing: 4) {
          if year.exceeded {
            Image(systemName: "exclamationmark.triangle")
              .accessibilityLabel(
                Text(verbatim: AllocationText.t("selfEmployed.block.exceeded", environment)))
          }
          Text(verbatim: money.rounded(block.yearLeftRub)).monospacedDigit()
          Text(verbatim: "· " + money.percent(basisPoints: year.shareBp))
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// «ФНС насчитала на 2 ₽ меньше» / «больше».
  static func gapText(_ gap: AmountE4, _ environment: AppEnvironment) -> String {
    AllocationText.format(
      gap.isNegative ? "npd.gap.less" : "npd.gap.more", environment,
      environment.money.exact(gap.magnitude))
  }
}
