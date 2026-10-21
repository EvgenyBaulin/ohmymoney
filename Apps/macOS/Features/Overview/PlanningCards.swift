import AppCore
import SwiftUI

/// The planning cards of Overview, which took the place of the line «Появится позже». They
/// read the planning snapshot the data step builds with the ledger, so a new operation moves
/// them at once, like the other cards of the data.

/// «Можно отложить в этом месяце»: the middle with its range, what is already put aside and
/// what can still be. The remainder of the month comes from the forecast step and is laid
/// over the current data, like the forecast card does.
struct CanSaveCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .canSave, environment), state: state, fillsHeight: true,
      emptyReason: t("advice.reason.noIncome"), retry: { compute.retry(ComputeStep.forecast) }
    ) { canSave in
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: "≈ \(environment.money.rounded(canSave.p50 ?? .zero))")
          .appFont(.title2.monospacedDigit())
        if let low = canSave.low, let high = canSave.high, low != high {
          Text(
            verbatim: String(
              format: t("overview.canSaveRange"), locale: environment.language.locale,
              environment.money.rounded(low), environment.money.rounded(high))
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        PlanningFigure(label: t("overview.alreadySaved"), amount: canSave.alreadySaved)
        PlanningFigure(label: t("overview.canSaveMore"), amount: canSave.canSaveMore ?? .zero)
        if canSave.lowData {
          Label {
            Text(verbatim: environment.language("common.noData"))
          } icon: {
            Image(systemName: "hourglass")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var state: BlockState<CanSave> {
    compute.states.forecast.flatMap { remainder, at in
      guard let snapshot = compute.snapshot else { return .calculating }
      let canSave = snapshot.planning.canSave(remainder: remainder)
      if case .notEnoughData = canSave.status { return .notEnoughData }
      return .ready(canSave, at: at)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// Scheduled payments and debt payments due within seven days, overdue ones first. A payment
/// in another currency than the default one says under its amount about how much it is in the
/// default currency at today's rate, in grey — or that there is no rate, never a guess.
struct UpcomingPaymentsCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .upcoming, environment),
      state: compute.states.data, fillsHeight: true, retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let upcoming = snapshot.planning.upcoming
      let target = snapshot.dataset.accountSettings.defaultCurrency
      if upcoming.isEmpty {
        Text(verbatim: environment.language("overview.upcomingNone", table: "Planning"))
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(upcoming.prefix(5), id: \.self) { payment in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              if payment.isOverdue {
                Image(systemName: "exclamationmark.circle")
                  .accessibilityLabel(
                    Text(verbatim: environment.language("planning.overdue", table: "Planning")))
              }
              Text(verbatim: environment.dates.dayAndMonth(payment.due))
                .monospacedDigit()
                .foregroundStyle(.secondary)
              Text(verbatim: payment.name)
                .lineLimit(1)
              Spacer(minLength: 6)
              // Two lines on the right keep the name from being cut short on a narrow card.
              VStack(alignment: .trailing, spacing: 0) {
                Text(
                  verbatim: environment.money.rounded(payment.amount, currency: payment.currency)
                )
                .monospacedDigit()
                if let approximate = Self.approximateText(
                  payment.approximate(to: target, rubPerUnit: snapshot.planning.rubPerUnit),
                  environment)
                {
                  Text(verbatim: approximate)
                    .appFont(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(
                      Text(
                        verbatim: environment.language(
                          "overview.upcoming.approxHelp", table: "Planning")))
                }
              }
            }
            .appFont(.callout)
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
  }
}

extension UpcomingPaymentsCard {
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
      let open = snapshot.planning.expected.filter { !$0.isFulfilled }
      if open.isEmpty {
        Text(verbatim: t("overview.expectedNone")).foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          PlanningFigure(
            label: t("overview.expectedThisMonth"),
            amount: snapshot.planning.income.expectedRemaining)
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
