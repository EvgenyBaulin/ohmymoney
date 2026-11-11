import AppCore
import AppDatabase
import SwiftUI

/// One place for balance adjustments and statements that still need the owner's decision.
struct OverviewDiscrepancies: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var reviews: [StatementReview] = []
  @State private var selected: StatementReview?

  var body: some View {
    let difference = compute.snapshot?.summary.reconciliationDifference ?? .zero
    let visible = reviews.filter { review in
      compute.snapshot?.hiding.isHidden(review.accountID) != true
    }
    Group {
      if !difference.isZero || !visible.isEmpty {
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
          ForEach(visible) { review in
            Button {
              selected = review
            } label: {
              HStack {
                Label(review.fileName, systemImage: "doc.badge.clock")
                Spacer()
                Text(verbatim: t("overview.statement.awaitingDecision"))
                Image(systemName: "chevron.right").accessibilityHidden(true)
              }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overview.statement.pending.\(review.id)")
          }
        }
        .appFont(.callout)
        .contentCard()
        // The block is a container: its rows stay separate elements (and reachable) inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.discrepancies")
      }
    }
    .task(id: compute.generation) {
      reload()
    }
    .sheet(item: $selected, onDismiss: reload) { review in
      StatementReviewSheet(review: review).handingOver(dependencies)
    }
  }

  private func reload() {
    let live = Set(
      ((try? environment.statementImports?.imports()) ?? []).filter { !$0.isUndone }.map(\.id))
    reviews = StatementReview.decode(
      (try? environment.settings?.string(StatementReview.settingsKey)) ?? nil
    ).filter { live.contains($0.id) }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}

/// The imported statement's checks and written operations; closing keeps the decision pending.
struct StatementReviewSheet: View {
  let review: StatementReview
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(verbatim: review.fileName).appFont(.headline)
      Text(verbatim: t("overview.statement.awaitingDecision")).appFont(.callout)
      if let closing = review.closingBalance {
        Text(
          verbatim: environment.format(
            "overview.statement.closingBalance", table: "Overview",
            amountText(closing))
        )
        .appFont(.callout)
        if let balance = review.ledgerBalance {
          Text(
            verbatim: environment.format(
              "overview.statement.ledgerBalance", table: "Overview",
              amountText(balance))
          )
          .appFont(.callout)
        } else {
          Text(verbatim: t("overview.statement.noBalance")).appFont(.callout)
        }
      }
      ForEach(Array(review.checks.enumerated()), id: \.offset) { _, check in
        if check.violations > 0 && check.missingIncome.isZero && check.missingExpense.isZero {
          Text(verbatim: environment.language("import.check.footer.missing", table: "Import"))
            .appFont(.callout)
        } else {
          Text(
            verbatim: environment.format(
              "import.check.footer.body", table: "Import",
              amountText(check.missingIncome), amountText(check.missingExpense))
          )
          .appFont(.callout).fixedSize(horizontal: false, vertical: true)
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(entries) { entry in
            HStack {
              Text(
                verbatim: environment.dates.dayAndMonth(
                  environment.calendar.day(of: entry.transaction.occurredAt)))
              Text(verbatim: entry.transaction.note ?? "")
              Spacer()
              Text(
                verbatim: environment.money.exact(
                  entry.transaction.amountE4,
                  currency: entry.transaction.currency)
              ).monospacedDigit()
            }
            .appFont(.callout)
          }
          ForEach(transfers) { transfer in
            HStack {
              Text(verbatim: environment.language("screenshot.transfer", table: "Receipt"))
              Spacer()
              Text(
                verbatim: environment.money.exact(
                  transfer.fromAmountE4,
                  currency: transfer.fromCurrency))
              Image(systemName: "arrow.right").accessibilityHidden(true)
              Text(
                verbatim: environment.money.exact(
                  transfer.toAmountE4,
                  currency: transfer.toCurrency))
            }
            .appFont(.callout)
          }
        }
      }
      if failed { Text(verbatim: environment.language("import.failed", table: "Import")) }
      HStack {
        Button(environment.language("import.close", table: "Import")) { dismiss() }
        Spacer()
        Button(t("overview.statement.keepWritten")) { resolve() }
          .accessibilityIdentifier("statement.review.keepWritten")
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 480)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("statement.review")
  }

  private var entries: [TransactionEntry] {
    let included = Set(review.operationIDs ?? [])
    return (compute.snapshot?.dataset.entries ?? []).filter {
      !$0.transaction.isDeleted
        && (included.contains($0.id) || $0.transaction.importBatchId?.uuidString == review.id)
    }
    .sorted { $0.transaction.occurredAt < $1.transaction.occurredAt }
  }

  private var transfers: [Transfer] {
    let included = Set(review.transferIDs ?? [])
    return (compute.snapshot?.dataset.transfers ?? []).filter { included.contains($0.id) }
      .sorted { $0.occurredAt < $1.occurredAt }
  }

  private func resolve() {
    let pending = StatementReview.decode(
      (try? environment.settings?.string(StatementReview.settingsKey)) ?? nil)
    guard let text = try? StatementReview.encode(pending.filter { $0.id != review.id }),
      store.apply(PlanningChange(settings: [StatementReview.settingsKey: text]))
    else { failed = true; return }
    dismiss()
  }

  private func amountText(_ amount: AmountE4) -> String {
    if environment.money.hidesAmounts { return MoneyFormatter.mask }
    guard let currency = review.currency else { return NumberText.amount(amount) }
    return environment.money.exact(amount, currency: currency)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}
