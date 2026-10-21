import AppCore
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// One-off and recurring income I expect: received of all, parts, what is left and when. An
/// income that came in whole offers «Закрыть полностью»; a closed one waits in «Архив» below the
/// list, collapsed, with «Вернуть»; «Удалить…» asks first. Each is one step of ⌘Z. Below them,
/// grey and read only, the interest deposits are expected to pay (`DepositPayoutRows`).
struct ExpectedIncomeBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.planningCardHosted) private var hosted
  @Binding var sheet: PlanningSheet?
  /// How many of the nearest incomes show before «Показать все».
  var length: PlanningListLength = .all
  /// The income «Удалить…» asks about.
  @State private var deleting: ExpectedIncome?
  @State private var showsArchive = false
  @State private var showsAll = false

  var body: some View {
    ComputedBlock(
      title: hosted ? nil : t("expected.title"), state: compute.states.data,
      style: hosted ? .plain : .card, fillsHeight: !hosted,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 8) {
        let statuses = snapshot.planning.expected
        let shown = PlanningShortListView.shown(
          statuses, length: length, expanded: showsAll,
          date: { Self.nextDue(of: $0) })
        let deposits = DepositPayoutRows.shown(
          snapshot.planning.deposits, today: environment.today)
        if statuses.isEmpty, deposits.isEmpty {
          if hosted {
            PlanningEmptyHint(block: .expectedIncome) { sheet = .expected(nil) }
          } else {
            Text(verbatim: t("expected.none")).foregroundStyle(.secondary)
          }
        }
        ForEach(shown.items) { status in
          VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
              Text(verbatim: status.income.name).lineLimit(1)
              if status.isOverdue {
                Image(systemName: "exclamationmark.circle")
                  .accessibilityLabel(Text(verbatim: t("planning.overdue")))
              }
              Spacer(minLength: 6)
              // A regular income shows this month's term, not everything since it began.
              let term = shownTerm(status)
              Text(
                verbatim: String(
                  format: t("planning.spentOf"), locale: environment.language.locale,
                  environment.money.rounded(term.received, currency: status.currency),
                  environment.money.rounded(term.total, currency: status.currency))
              )
              .monospacedDigit()
            }
            Text(verbatim: detail(status))
              .appFont(.caption)
              .foregroundStyle(.secondary)
            HStack(spacing: 8) {
              Button(t("expected.link")) { sheet = .linkIncome(status) }
              Button(t("expected.edit")) { sheet = .expected(status.income) }
              if ExpectedIncomeRules.offersClosing(status) {
                Button(t("expected.closeFully")) { close(status.income) }
                  .help(t("expected.closeFully.help"))
                  .accessibilityIdentifier("expected.closeFully")
              }
            }
            .buttonStyle(.link)
            .appFont(.caption)
          }
          .contextMenu {
            Button(t("expected.edit")) { sheet = .expected(status.income) }
            Button(t("expected.link")) { sheet = .linkIncome(status) }
            if ExpectedIncomeRules.offersClosing(status) {
              Button(t("expected.closeFully")) { close(status.income) }
            }
            Divider()
            Button(t("expected.delete")) { deleting = status.income }
          }
        }
        PlanningShowAllButton(
          block: .expectedIncome, total: statuses.count, hidden: shown.hidden,
          expanded: $showsAll)
        DepositPayoutRows(
          payouts: snapshot.planning.deposits, accounts: snapshot.dataset.paymentMethods)
        if !(hosted && statuses.isEmpty && deposits.isEmpty) {
          Button(t("expected.add")) { sheet = .expected(nil) }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        archive(Self.archived(snapshot.dataset.planning.expected))
      }
    }
    .confirmationDialog(
      environment.format("expected.deleteTitle", table: "Planning", deleting?.name ?? ""),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button(environment.language("action.delete"), role: .destructive) {
        if let deleting, let dependencies { PlanningActions(dependencies).delete(deleting) }
        deleting = nil
      }
      Button(environment.language("action.cancel"), role: .cancel) { deleting = nil }
    } message: {
      Text(verbatim: t("expected.deleteMessage"))
    }
  }

  /// The day an income is nearest by: the first of its dues with money still to come, else its
  /// latest due, else the day it was set for; nothing for an income with no day at all.
  static func nextDue(of status: ExpectedIncomeStatus) -> DateOnly? {
    status.occurrences.first { !$0.isFulfilled }?.due ?? status.current?.due
      ?? status.income.dueDate
  }

  /// The closed incomes, the archive of the block, in the order of the book.
  static func archived(_ incomes: [ExpectedIncome]) -> [ExpectedIncome] {
    incomes.filter(\.closed)
  }

  /// «Архив»: the closed incomes, collapsed until opened, each with «Вернуть» — open again, one
  /// step of ⌘Z — and «Удалить…» in its menu.
  @ViewBuilder
  private func archive(_ closed: [ExpectedIncome]) -> some View {
    if !closed.isEmpty {
      DisclosureGroup(isExpanded: $showsArchive) {
        ForEach(closed) { income in
          HStack(spacing: 6) {
            Image(systemName: "archivebox")
              .foregroundStyle(.secondary)
              .accessibilityLabel(Text(verbatim: t("expected.closed")))
            Text(verbatim: income.name)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: environment.money.rounded(income.totalE4, currency: income.currency))
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Button(t("expected.restore")) {
              if let dependencies { PlanningActions(dependencies).reopen(income) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
          .contextMenu {
            Button(t("expected.restore")) {
              if let dependencies { PlanningActions(dependencies).reopen(income) }
            }
            Divider()
            Button(t("expected.delete")) { deleting = income }
          }
        }
      } label: {
        Text(
          verbatim: environment.format("expected.archive", table: "Planning", counts: closed.count))
      }
      .appFont(.callout)
      .accessibilityIdentifier("expected.archive")
    }
  }

  private func close(_ income: ExpectedIncome) {
    guard let dependencies else { return }
    PlanningActions(dependencies).close(income)
  }

  /// A one-off income as a whole; a regular one by the term of this month, or its latest.
  private func shownTerm(
    _ status: ExpectedIncomeStatus
  )
    -> (received: AmountE4, total: AmountE4, remaining: AmountE4, parts: Int)
  {
    guard status.income.kind == .recurring else {
      return (
        status.received, status.received + status.remaining, status.remaining, status.partsReceived
      )
    }
    let term = Self.shownOccurrence(status.occurrences, today: environment.today)
    guard let term else { return (.zero, status.income.totalE4, status.income.totalE4, 0) }
    return (term.received, term.total, term.remaining, term.partsReceived)
  }

  /// The term of a recurring income the row stands for: the latest of this month that has
  /// come — a weekly one has later weeks still ahead — else the month's first, else the last
  /// known (third review, 19.09).
  static func shownOccurrence(
    _ occurrences: [ExpectedOccurrence], today: DateOnly
  ) -> ExpectedOccurrence? {
    let month = occurrences.filter { $0.due.monthKey == today.monthKey }
    return month.last { $0.due <= today } ?? month.first ?? occurrences.last
  }

  private func detail(_ status: ExpectedIncomeStatus) -> String {
    let term = shownTerm(status)
    let expectedParts =
      status.income.kind == .recurring ? status.income.partsExpected : status.partsExpected
    var pieces = [
      environment.language.format(
        "expected.parts", table: "Planning", term.parts, expectedParts)
    ]
    if !term.remaining.isZero {
      pieces.append(
        environment.format(
          "expected.left", table: "Planning",
          environment.money.rounded(term.remaining, currency: status.currency)))
    }
    let shownDue =
      status.income.kind == .recurring
      ? Self.shownOccurrence(status.occurrences, today: environment.today)?.due
      : status.current?.due
    if let due = shownDue ?? status.income.dueDate {
      pieces.append(environment.dates.dayAndMonth(due))
    }
    return pieces.joined(separator: " · ")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// Suggestions built by rules on my data, each with its formula and numbers, «Мало данных»
/// where there is too little, and the permanent line that this is not financial advice.
struct AdviceBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.planningCardHosted) private var hosted

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // In every state of the block, even while it counts or failed («постоянная
      // пометка»).
      Label {
        Text(verbatim: t(AdviceBook.disclaimerKey))
      } icon: {
        Image(systemName: "info.circle")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      ComputedBlock(
        title: hosted ? nil : t("advice.title"), state: compute.states.advice,
        style: hosted ? .plain : .card, retry: { compute.retry(ComputeStep.advice) }
      ) { report in
        VStack(alignment: .leading, spacing: 12) {
          ForEach(report.items) { advice in
            AdviceRow(advice: advice)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

private struct AdviceRow: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let advice: Advice

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: AdviceText.title(advice, environment, tree: compute.snapshot?.ledger.tree))
        .appFont(.callout.weight(.medium))
      switch advice.status {
      case .ready:
        if let result = advice.result {
          Text(verbatim: AdviceText.line(result, environment, tree: compute.snapshot?.ledger.tree))
            .appFont(.callout.monospacedDigit())
        }
        ForEach(Array(advice.terms.enumerated()), id: \.offset) { _, term in
          Text(verbatim: AdviceText.line(term, environment, tree: compute.snapshot?.ledger.tree))
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        ForEach(Array(advice.notes.enumerated()), id: \.offset) { _, note in
          Text(verbatim: AdviceText.line(note, environment, tree: compute.snapshot?.ledger.tree))
            .appFont(.caption)
            .foregroundStyle(.tertiary)
        }
        if advice.kind == .debtLoad, let history = compute.snapshot?.planning.debtLoadHistory {
          DebtLoadHistoryView(history: history)
        }
      case .notEnoughData(let reason):
        Label {
          Text(
            verbatim: environment.language("common.noData") + " — "
              + environment.language(reason, table: "Planning"))
        } icon: {
          Image(systemName: "hourglass")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// The debt load month by month, the last twelve months, under its suggestion: each month's
/// share of income, and a symbol with a word where the Bank of Russia calls a load high (from
/// 50 %) or very high (from 80 %) — said in words, never in colour; then those thresholds and
/// that a bank counts a credit card stricter, by its limit.
struct DebtLoadHistoryView: View {
  @Dependency(\.environment) private var environment
  let history: [DebtLoadMonth]

  var body: some View {
    let rows = Self.rows(history)
    VStack(alignment: .leading, spacing: 4) {
      if !rows.isEmpty {
        Text(verbatim: t("advice.load.history"))
          .appFont(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
          ForEach(rows, id: \.month) { row in
            GridRow {
              Text(verbatim: environment.dates.shortMonthAndYear(row.month))
                .foregroundStyle(.secondary)
              Text(
                verbatim: row.loadBp.map { environment.money.percent(basisPoints: $0) } ?? "—"
              )
              .monospacedDigit()
              .gridColumnAlignment(.trailing)
              if let level = Self.level(row.loadBp) {
                Label {
                  Text(verbatim: t(level.key))
                } icon: {
                  Image(systemName: level.symbol)
                }
              } else {
                Text(verbatim: "")
              }
            }
            .accessibilityElement(children: .combine)
          }
        }
        .appFont(.caption)
      }
      Text(verbatim: t("advice.load.thresholds"))
        .appFont(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: t("advice.load.bank"))
        .appFont(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("advice.load.history")
  }

  /// A month of the history and its load; `nil` where it could not be counted.
  struct Row: Hashable {
    var month: MonthKey
    var loadBp: Int?
  }

  /// The months, newest first.
  static func rows(_ history: [DebtLoadMonth]) -> [Row] {
    history.map { Row(month: $0.month, loadBp: $0.load.loadBp) }.sorted { $0.month > $1.month }
  }

  /// How the Bank of Russia would call the load: high from 50 %, very high from 80 %
  /// (`DebtLoad.highBp`, `veryHighBp`); below that, nothing is said.
  enum Level: Hashable {
    case high
    case veryHigh

    var key: String { self == .high ? "advice.load.high" : "advice.load.veryHigh" }
    var symbol: String { self == .high ? "exclamationmark.circle" : "exclamationmark.triangle" }
  }

  static func level(_ loadBp: Int?) -> Level? {
    guard let loadBp else { return nil }
    if loadBp >= DebtLoad.veryHighBp { return .veryHigh }
    if loadBp >= DebtLoad.highBp { return .high }
    return nil
  }

  static let keys = [
    "advice.load.history", "advice.load.thresholds", "advice.load.bank", "advice.load.high",
    "advice.load.veryHigh",
  ]

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
