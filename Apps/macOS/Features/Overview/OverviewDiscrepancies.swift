import AppCore
import AppDatabase
import SwiftUI

/// The count difference of the period: balance adjustments, which are neither income nor spending.
struct OverviewDiscrepancies: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    let difference = compute.snapshot?.summary.reconciliationDifference ?? .zero
    Group {
      if !difference.isZero {
        VStack(alignment: .leading, spacing: 10) {
          if !difference.isZero {
            HStack {
              Label(t("overview.reconciliation.difference"), systemImage: "equal.circle")
              if let snapshot = compute.snapshot,
                snapshot.ledger.rows(in: snapshot.summary.span).contains(where: {
                  OverviewSummary.isCountDifference($0)
                    && snapshot.hiding.isHidden($0.paymentMethodId)
                })
              {
                Text(verbatim: environment.language("privacy.partHidden", table: "PrivacyScreens"))
                  .appFont(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(verbatim: environment.money.exact(difference)).monospacedDigit()
            }
            .accessibilityIdentifier("overview.reconciliation.difference")
          }
        }
        .appFont(.callout)
        .contentCard()
        // The block is a container: its rows stay separate elements (and reachable) inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.discrepancies")
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}
