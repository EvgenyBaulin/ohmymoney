import AppCore
import AppDatabase
import SwiftUI

/// The changes the screens of the conditions make.
extension AccountActions {
  /// Takes a movement out of the free limits, or puts it back: one `PlanningChange` of the one
  /// setting, so ⌘Z puts it back.
  func setLimitOff(
    _ id: UUID, off: Bool, current: BankSettings
  ) -> AccountActionOutcome {
    var next = current
    if off { next.limitOff.insert(id) } else { next.limitOff.remove(id) }
    let key = BankSettings.limitOffKey
    var settings: [String: String?] = [:]
    settings.updateValue(next.storedValues[key] ?? nil, forKey: key)
    return apply(PlanningChange(settings: settings, at: environment.now()))
  }
}

/// «Условия банка» on the screen of an account: how far each free limit is used this month, what
/// is left to make the service free, and the balance the bank asks to keep. Nothing is shown for
/// an account whose conditions the owner has not typed.
struct AccountConditionsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute

  let accountId: UUID

  private var report: BankReport? { compute.snapshot?.planning.banks }

  private var conditions: BankConditions? {
    compute.snapshot?.dataset.bankData.conditions(account: accountId)
  }

  private var hasContent: Bool {
    guard let report else { return false }
    return !report.limits(of: accountId).isEmpty || report.service(of: accountId) != nil
      || conditions?.minBalanceE4 != nil
  }

  var body: some View {
    if let report, hasContent {
      ComputedBlock(
        title: BankText.t("bank.cond.title", environment),
        state: .ready(report, at: environment.now()), retry: nil
      ) { report in
        content(report)
      }
      .accessibilityIdentifier("account.conditions")
    }
  }

  private func content(_ report: BankReport) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(report.limits(of: accountId)) { line in limit(line) }
      if let service = report.service(of: accountId) { serviceRows(service) }
      if let minimum = conditions?.minBalanceE4, let currency = conditions?.currency {
        minBalanceRow(minimum: minimum, currency: currency, report: report)
      }
      if let note = conditions?.note, !note.isEmpty {
        Text(verbatim: note).appFont(.caption).foregroundStyle(.secondary)
      }
      Text(verbatim: BankText.t("bank.service.hint", environment))
        .appFont(.caption).foregroundStyle(.secondary)
    }
  }

  private func limit(_ line: BankLimitLine) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label {
        Text(verbatim: BankText.limitLine(line, environment)).monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: line.exceeded ? "exclamationmark.triangle" : symbol(line.kind))
      }
      .foregroundStyle(line.exceeded ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
      // The bar only draws the share; the words above carry the figures.
      ProgressView(value: share(line))
        .accessibilityHidden(true)
      if !line.movements.isEmpty {
        DisclosureGroup(BankText.t("bank.limit.counted", environment)) {
          ForEach(line.movements) { movement in movementRow(movement, line.currency) }
        }
        .appFont(.caption)
      }
    }
  }

  private func movementRow(_ movement: BankLimitMovement, _ currency: CurrencyCode) -> some View {
    HStack {
      Text(verbatim: environment.dates.dayAndMonth(movement.day))
        .foregroundStyle(.secondary)
      Text(verbatim: environment.money.rounded(movement.amountE4, currency: currency))
        .monospacedDigit()
        .strikethrough(movement.off)
      Spacer()
      Button(BankText.t(movement.off ? "bank.limit.on" : "bank.limit.off", environment)) {
        toggle(movement)
      }
      .buttonStyle(.borderless)
    }
  }

  private func toggle(_ movement: BankLimitMovement) {
    guard let settings = compute.snapshot?.dataset.bankData.settings else { return }
    _ = AccountActions(environment: environment, store: store)
      .setLimitOff(movement.id, off: !movement.off, current: settings)
  }

  /// The share of the limit used, 0…1, for the bar.
  private func share(_ line: BankLimitLine) -> Double {
    guard line.limitE4.raw > 0 else { return 0 }
    return min(1, Double(line.usedE4.raw) / Double(line.limitE4.raw))
  }

  private func symbol(_ kind: BankLimitKind) -> String {
    switch kind {
    case .cash: "banknote"
    case .sbp: "arrow.left.arrow.right"
    case .interbank: "building.columns"
    }
  }

  @ViewBuilder
  private func serviceRows(_ progress: BankServiceProgress) -> some View {
    ForEach(Array(BankText.serviceLines(progress, environment).enumerated()), id: \.offset) {
      _, line in
      Label {
        Text(verbatim: line).monospacedDigit().fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(
          systemName: progress.isFree
            ? "checkmark.circle" : "creditcard.trianglebadge.exclamationmark")
      }
    }
  }

  private func minBalanceRow(
    minimum: AmountE4, currency: CurrencyCode, report: BankReport
  ) -> some View {
    let risk = report.minBalanceRisk(of: accountId)
    let balance = compute.snapshot?.planning.accounts.line(of: accountId)?.keys
      .first { $0.key.currency == currency }?.balance
    return Label {
      Text(
        verbatim: BankText.minBalanceLine(
          balanceE4: balance, minimumE4: minimum, currency: currency, environment)
      )
      .monospacedDigit().fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: risk == nil ? "checkmark.circle" : "exclamationmark.triangle")
    }
    .foregroundStyle(risk == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
  }
}
