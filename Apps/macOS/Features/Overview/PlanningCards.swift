import AppCore
import SwiftUI

/// The planning cards of Overview, which took the place of the line «Появится позже». They
/// read the planning snapshot the data step builds with the ledger, so a new operation moves
/// them at once, like the other cards of the data.

/// «Можно отложить в этом месяце»: the range it can be — «от 18 000 до 26 000 ₽» — and what is
/// already put aside. The remainder of the month comes from the forecast step and is laid over
/// the current data, like the forecast card does.
struct CanSaveCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .canSave, environment), state: state, fillsHeight: true,
      emptyReason: t("advice.reason.noIncome"), asOf: compute.states.asOf(ComputeStep.forecast),
      retry: { compute.retry(ComputeStep.forecast) }
    ) { canSave in
      let tile = CanSaveTile.make(canSave, environment) { id in
        guard let tree = compute.snapshot?.ledger.tree else { return nil }
        return PlanningText.categoryPath(id, tree: tree)
      }
      VStack(alignment: .leading, spacing: StyleMetrics.tileGap) {
        Text(verbatim: tile.figure)
          .appFont(StyleType.tileFigure)
          .foregroundStyle(surfaces.primary)
          .fixedSize(horizontal: false, vertical: true)
        if let shortfall = tile.shortfall {
          Text(verbatim: shortfall)
            .appFont(StyleType.tileRow.monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("overview.canSave.shortfall")
          ForEach(Array(tile.hints.enumerated()), id: \.offset) { _, hint in
            Text(verbatim: hint)
              .appFont(StyleType.tileHint)
              .foregroundStyle(surfaces.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        TileFigureRow(label: tile.savedLabel, figure: tile.saved)
        if canSave.lowData {
          Label {
            Text(verbatim: environment.language("common.noData"))
          } icon: {
            Image(systemName: "hourglass")
          }
          .appFont(StyleType.tileHint)
          .foregroundStyle(surfaces.secondary)
        }
      }
    }
  }

  private var state: BlockState<CanSave> {
    compute.states.forecast.flatMap { remainder, at in
      guard let snapshot = compute.snapshot else { return .calculating }
      let canSave = snapshot.planning.canSave(remainder: remainder, ledger: snapshot.ledger)
      if case .notEnoughData = canSave.status { return .notEnoughData }
      return .ready(canSave, at: at)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// Scheduled payments and debt payments due within seven days, overdue ones first: the title
/// counts them with their total, «просрочен» stands under it while one is late, three are
/// listed and the rest summed up under them. A payment in another currency than the default one
/// says under its amount about how much it is in the default currency at today's rate, in grey —
/// or that there is no rate, never a guess.
struct UpcomingPaymentsCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    let tile = compute.states.data.value.map { self.tile($0) }
    ComputedBlock(
      title: tile?.title ?? OverviewTileText.name(of: .upcoming, environment),
      state: compute.states.data, fillsHeight: true, retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let tile = self.tile(snapshot)
      if tile.rows.isEmpty {
        Text(verbatim: environment.language("overview.upcomingNone", table: "Planning"))
          .appFont(StyleType.tileRow)
          .foregroundStyle(surfaces.secondary)
      } else {
        VStack(alignment: .leading, spacing: StyleMetrics.tileGap) {
          if tile.hasOverdue {
            TileOverdueChip(text: environment.language("planning.overdue", table: "Planning"))
          }
          ForEach(Array(tile.rows.enumerated()), id: \.offset) { _, row in
            TileFigureRow(label: row.label) {
              VStack(alignment: .trailing, spacing: 0) {
                TileFigureText(text: row.amount)
                if let approximate = row.approximate {
                  Text(verbatim: approximate)
                    .appFont(StyleType.tileHint.monospacedDigit())
                    .foregroundStyle(surfaces.secondary)
                    .help(
                      Text(
                        verbatim: environment.language(
                          "overview.upcoming.approxHelp", table: "Planning")))
                }
              }
            }
          }
          if let footer = tile.footer {
            Text(verbatim: footer)
              .appFont(StyleType.tileHint.monospacedDigit())
              .foregroundStyle(surfaces.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  /// The words of the tile for a snapshot: covered, not naming a payment of a hidden account.
  private func tile(_ snapshot: DataSnapshot) -> UpcomingTile {
    // The block hands over the whole snapshot; what is covered is the presented one's.
    UpcomingTile.make(
      Self.listed(
        snapshot.planning.upcoming, hiding: HiddenPlans(snapshot: compute.snapshot ?? snapshot)),
      target: snapshot.dataset.accountSettings.defaultCurrency,
      rubPerUnit: snapshot.planning.rubPerUnit, environment)
  }
}

extension UpcomingPaymentsCard {
  /// The payments the tile lists: covered, not those of a hidden account.
  static func listed(_ payments: [UpcomingPayment], hiding: HiddenPlans) -> [UpcomingPayment] {
    payments.filter { !hiding.hides($0) }
  }

  /// The grey line under a payment's amount: «≈ 269 ₽» in the default currency, «нет курса»
  /// when a rate is missing, nothing for a payment in the default currency.
  static func approximateText(
    _ approximate: UpcomingPayment.Approximate?, _ environment: AppEnvironment
  ) -> String? {
    switch approximate {
    case .none:
      nil
    case .amount(let amount, let currency):
      "≈\u{00A0}\(environment.money.rounded(amount, currency: currency))"
    case .noRate:
      environment.language("overview.upcoming.noRate", table: "Planning")
    }
  }
}

/// What is still expected this month, and the nearest expectations.
struct ExpectedIncomeCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .expectedIncome, environment), state: compute.states.data,
      fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      // The figure keeps an income of a hidden account; the list does not name it.
      let open = ExpectedIncomeBlock.listed(
        snapshot.planning.expected, hiding: HiddenPlans(snapshot: compute.snapshot ?? snapshot)
      ).filter { !$0.isFulfilled }
      if open.isEmpty {
        Text(verbatim: t("overview.expectedNone")).foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          PlanningFigure(
            label: t("overview.expectedThisMonth"),
            amount: snapshot.planning.income.expectedRemaining)
          if open.count != snapshot.planning.expected.filter({ !$0.isFulfilled }).count {
            PartHiddenNote()
          }
          ForEach(open.prefix(3), id: \.income.id) { status in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(verbatim: status.income.name).lineLimit(1)
              Spacer(minLength: 6)
              Text(
                verbatim: environment.money.rounded(
                  status.remaining, currency: status.income.currency)
              )
              .monospacedDigit()
            }
            .appFont(.callout)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// The event going on — spent against its budget — or else the next one with what it cost
/// last time.
struct EventCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .event, environment), state: compute.states.data,
      fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let events = snapshot.planning.events
      if let plan = events.active.first ?? events.upcoming.first {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: plan.event.name).appFont(.headline).lineLimit(1)
          Text(verbatim: PlanningText.eventWhen(plan, environment))
            .appFont(.caption).foregroundStyle(.secondary)
          if let budget = plan.budget {
            Text(
              verbatim: String(
                format: t("planning.spentOf"), locale: environment.language.locale,
                environment.money.rounded(plan.spent), environment.money.rounded(budget))
            )
            .monospacedDigit()
          } else if plan.isActive {
            PlanningFigure(label: t("planning.spent"), amount: plan.spent)
          } else if let last = plan.lastTimeTotal {
            PlanningFigure(label: t("planning.lastTime"), amount: last)
          }
        }
      } else {
        Text(verbatim: t("overview.eventNone")).foregroundStyle(.secondary)
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

// MARK: - Pieces

/// A figure of a planning card: words on the left, whole rubles on the right.
struct PlanningFigure: View {
  @Dependency(\.environment) private var environment
  let label: String
  let amount: AmountE4

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: label).appFont(.callout)
      Spacer(minLength: 8)
      Text(verbatim: environment.money.rounded(amount)).monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }
}
