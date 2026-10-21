import AppCore
import SwiftUI

/// The last reconciliation: its day, how long ago, the differences it found as it found them —
/// each in its balance's own currency, never counted again at today's rates; a reconciliation of
/// one total says so — and «Сверить…», which opens the reconciliation sheet of the main window.
///
/// When an older version recorded a first count as a difference — the balance counted against
/// the zero it wrote for an empty field — the card says so for the newest such count whose
/// operation still distorts the income or the spending, and offers both answers: «Это первая
/// сверка — сделать точкой отсчёта» or «Это настоящая разница». Each is one step of ⌘Z.
struct ReconciliationCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .lastCount, environment),
      state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 6) {
        if let last = snapshot.planning.lastReconciliation {
          Text(verbatim: environment.dates.longDay(last.date))
            .appFont(.title3)
          Text(
            verbatim: environment.language.format(
              "overview.reconciliationAgo", table: "Planning",
              counts: max(0, last.date.days(to: snapshot.today)))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
          if let found = Self.found(
            by: last, balances: snapshot.dataset.planning.reconciledBalances,
            accounts: snapshot.dataset.paymentMethods, environment)
          {
            Text(verbatim: found)
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        } else {
          Text(verbatim: environment.language("overview.reconciliationNone", table: "Overview"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let offer = Self.offer(in: snapshot) {
          firstCountOffer(offer, snapshot: snapshot)
        }
        // Content, not a floating control: a plain small button, never glass.
        Button(environment.language("reconcile.open", table: "Planning")) {
          environment.showsReconciliation = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  /// What the card says the reconciliation found, as it found it: «одной суммой, до счетов ·
  /// разница −1,200 ₽» of a reconciliation of one total, made before there were accounts; the
  /// differences of the balances of one of the accounts, each in its currency and to the whole
  /// unit — or «без расхождений», «точка отсчёта»; nil when there is nothing to say.
  static func found(
    by reconciliation: Reconciliation, balances: [ReconciledBalance],
    accounts: [PaymentMethod], _ environment: AppEnvironment
  ) -> String? {
    func difference(_ text: String) -> String {
      environment.format("overview.reconciliationDifference", table: "Planning", text)
    }
    guard reconciliation.kind != .total else {
      let oneTotal = environment.language("overview.reconciliationTotal", table: "Overview")
      guard let found = reconciliation.differenceE4 else { return oneTotal }
      return oneTotal + " · " + difference(environment.money.signedRounded(found))
    }
    let balances = balances.filter { $0.reconciliationId == reconciliation.id }
    guard !balances.isEmpty else { return nil }
    let names = Dictionary(
      accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    // The Overview shows amounts to the ruble; the sheet's history keeps the kopecks.
    let text = ReconcileSheet.differencesText(
      balances, names: { names[$0] ?? "—" }, money: environment.money,
      language: environment.language, rounded: true)
    guard case .differences = ReconcileSheet.findings(balances) else { return text }
    return difference(text)
  }

  // MARK: The first count

  /// The first count the card offers to decide on: the newest one whose difference operation is
  /// still live — the one that shows in the income or the spending —, with how many others wait
  /// in the history. Those the owner called a real difference are left out. `nil` when none.
  static func offer(in snapshot: DataSnapshot) -> (candidate: FirstCountCandidate, more: Int)? {
    let all = ReconcileSheet.candidates(
      in: snapshot, kept: snapshot.dataset.planning.settings.firstCountKept)
    guard let shown = all.first(where: { $0.operationId != nil }) else { return nil }
    return (shown, all.count - 1)
  }

  /// What the card says of a candidate: when, how much, on which account.
  static func offerText(
    _ candidate: FirstCountCandidate, accounts: [PaymentMethod], _ environment: AppEnvironment
  ) -> String {
    let day = environment.dates.dayAndMonth(candidate.day)
    let amount = environment.money.signedRounded(candidate.difference, currency: candidate.currency)
    guard let key = candidate.key else {
      return environment.format("reconcile.firstCount.total", table: "Planning", day, amount)
    }
    let name = accounts.first { $0.id == key.accountId }?.name ?? "—"
    return environment.format("reconcile.firstCount.card", table: "Planning", day, amount, name)
  }

  private func firstCountOffer(
    _ offer: (candidate: FirstCountCandidate, more: Int), snapshot: DataSnapshot
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text(
          verbatim: Self.offerText(
            offer.candidate, accounts: snapshot.dataset.paymentMethods, environment)
        )
        .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "flag")
      }
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      // Content, not floating controls: plain small buttons, never glass.
      Button(environment.language("reconcile.firstCount.fix", table: "Planning")) {
        guard let dependencies else { return }
        PlanningActions(dependencies).fixFirstCount(offer.candidate)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      Button(environment.language("reconcile.firstCount.keep", table: "Planning")) {
        guard let dependencies else { return }
        PlanningActions(dependencies).keepFirstCount(offer.candidate)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      if offer.more > 0 {
        Button(
          environment.language.format(
            "reconcile.firstCount.more", table: "Planning", counts: offer.more)
        ) {
          ReconcileHistoryRequest.shared.isRequested = true
          environment.showsReconciliation = true
        }
        .buttonStyle(.link)
        .controlSize(.small)
      }
    }
  }
}
