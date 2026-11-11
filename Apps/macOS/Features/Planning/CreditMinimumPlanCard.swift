import AppCore
import SwiftUI

/// The minimum is the obligation; the full amount remains visible for keeping the grace period.
struct CreditMinimumPlanCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let snapshot: DataSnapshot
  @State private var editing: CreditMinimumPrefill?

  private var statements: [CreditMinimumPrefill] {
    snapshot.planning.creditStatements.compactMap { accountId, statements in
      guard !snapshot.hiding.isHidden(accountId), let statement = statements.last,
        statement.remainingE4.raw > 0,
        let account = snapshot.dataset.paymentMethods.first(where: { $0.id == accountId })
      else { return nil }
      return CreditMinimumPrefill(
        accountId: accountId, currency: account.mainCurrency, statement: statement)
    }.sorted {
      if $0.statement.due != $1.statement.due { return $0.statement.due < $1.statement.due }
      return $0.accountId.uuidString < $1.accountId.uuidString
    }
  }

  var body: some View {
    if !statements.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(verbatim: environment.language("account.credit.minimum.title", table: "Accounts"))
          .appFont(.headline)
        ForEach(statements, id: \.accountId) { item in
          row(item)
        }
      }
      .padding(16)
      .planningCardSurface()
      .sheet(item: $editing) { prefill in
        CreditMinimumSheet(prefill: prefill).handingOver(dependencies)
      }
      .accessibilityIdentifier("planning.creditMinimums")
    }
  }

  private func row(_ item: CreditMinimumPrefill) -> some View {
    let statement = item.statement
    let name = snapshot.dataset.paymentMethods.first { $0.id == item.accountId }?.name ?? ""
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(
          verbatim: environment.format(
            "account.credit.minimum.row", table: "Accounts", name,
            environment.dates.dayAndMonth(statement.due),
            (statement.minimumIsEstimate ? "≈\u{00A0}" : "")
              + environment.money.exact(statement.minimumRemainingE4, currency: item.currency))
        )
        .monospacedDigit()
        Spacer(minLength: 6)
        Button(environment.language("account.credit.minimum.change", table: "Accounts")) {
          editing = item
        }
        .controlSize(.small)
      }
      Text(
        verbatim: environment.format(
          "account.credit.minimum.full", table: "Accounts",
          environment.money.exact(statement.remainingE4, currency: item.currency))
      )
      .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
  }
}
