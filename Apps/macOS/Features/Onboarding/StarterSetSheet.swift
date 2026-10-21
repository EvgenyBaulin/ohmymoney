import AppCore
import AppDatabase
import SwiftUI

/// «Стартовый набор»: how the owner lives — student, working, freelance, family, alone, with a
/// partner, with children, several at once — and four questions after it. The set only adds:
/// the list of what it will add is on the sheet before anything is written, and the categories
/// and limits are written as one step of ⌘Z. The currency and the bank are the account
/// questionnaire's, which comes right after it on the first launch.
struct StarterSetSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var choice = StarterChoice()
  @State private var failed = false

  private func t(_ key: String) -> String { environment.language(key, table: "Onboarding") }

  private var additions: StarterAdditions {
    StarterSetActions.additions(
      for: choice, dataset: compute.snapshot?.dataset, environment: environment)
  }

  var body: some View {
    let plan = additions
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: t("starter.title")).appFont(.title2.weight(.semibold))
      Text(verbatim: t("starter.subtitle"))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
        ForEach(Lifestyle.allCases, id: \.self) { lifestyle in
          Toggle(isOn: lifestyleBinding(lifestyle)) {
            Text(verbatim: t("starter.lifestyle.\(lifestyle.rawValue)"))
              .frame(maxWidth: .infinity)
          }
          .toggleStyle(.button)
          .accessibilityIdentifier("starter.lifestyle.\(lifestyle.rawValue)")
        }
      }
      Divider()
      Toggle(t("starter.loans"), isOn: $choice.hasLoans)
      Toggle(t("starter.subscriptions"), isOn: $choice.hasSubscriptions)
      Toggle(t("starter.cashback"), isOn: $choice.tracksCashback)
      Toggle(t("starter.cushion"), isOn: $choice.wantsACushion)
      Divider()
      preview(plan)
      Spacer(minLength: 0)
      HStack {
        Button(t("starter.later")) { close(applied: false) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        // On even when there is nothing new to add: the set chosen is still remembered for the
        // tutorial's tasks.
        Button(t("starter.apply")) { apply(plan) }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("starter.apply")
      }
    }
    .padding(22)
    .sheetFrame(width: 560, height: 640)
    .refusedWriteAlert($failed, environment)
  }

  private func lifestyleBinding(_ lifestyle: Lifestyle) -> Binding<Bool> {
    Binding(
      get: { choice.lifestyles.contains(lifestyle) },
      set: { on in
        if on { choice.lifestyles.insert(lifestyle) } else { choice.lifestyles.remove(lifestyle) }
      })
  }

  /// «Добавится»: the categories, the limits and the tiles, by name.
  @ViewBuilder
  private func preview(_ plan: StarterAdditions) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: t("starter.willAdd")).appFont(.headline)
      if plan.isEmpty {
        Text(verbatim: t("starter.nothingToAdd")).foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            if !plan.categories.isEmpty {
              Text(
                verbatim: t("starter.categories") + " "
                  + plan.categories.map(\.name).joined(separator: ", "))
            }
            if !plan.budgets.isEmpty {
              Text(
                verbatim: t("starter.limits") + " "
                  + StarterSetActions.limitNames(
                    plan, environment: environment, dataset: compute.snapshot?.dataset
                  )
                  .joined(separator: ", "))
            }
            if !plan.tiles.isEmpty {
              Text(
                verbatim: t("starter.tiles") + " "
                  + plan.tiles.map { OverviewTileText.name(of: $0, environment) }.joined(
                    separator: ", "))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: 160)
        .accessibilityIdentifier("starter.preview")
      }
    }
  }

  private func apply(_ plan: StarterAdditions) {
    guard StarterSetActions.apply(plan, store: store, environment: environment) else {
      failed = true
      return
    }
    // The tutorial's tasks follow the set: remembered on this Mac, not in the database.
    GuideStore.shared.remember(choice)
    close(applied: true)
  }

  private func close(applied: Bool) {
    StarterSetActions.markAsked()
    AppLog.info(
      "starter.closed", .ui, "the starter set was closed",
      [LogPair("applied", .flag(applied)), LogPair("lifestyles", .count(choice.lifestyles.count))])
    dismiss()
    StarterSetOffer.shared.isRequested = false
  }
}

/// What the starter set writes, apart from the sheet.
@MainActor
enum StarterSetActions {
  /// Asked once on the first launch, then from Settings whenever the owner wants.
  static let askedKey = "starter.asked"

  static func markAsked(in defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: askedKey)
  }

  static func wasAsked(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: askedKey)
  }

  static func additions(
    for choice: StarterChoice, dataset: Dataset?, environment: AppEnvironment
  ) -> StarterAdditions {
    StarterSets.additions(
      for: choice, language: environment.language.resolvedCode,
      existing: dataset?.categories ?? [], budgets: dataset?.planning.budgets ?? [],
      tiles: environment.overviewTiles, startMonth: environment.today.monthKey)
  }

  /// The categories and the limits in one write and one step of ⌘Z; the tiles of Overview — a
  /// setting of this Mac, not data — join the chosen ones after it.
  static func apply(
    _ plan: StarterAdditions, store: TransactionsStore, environment: AppEnvironment
  ) -> Bool {
    guard !plan.isEmpty else { return true }
    if !plan.categories.isEmpty || !plan.budgets.isEmpty {
      let change = PlanningChange(
        upsert: PlanningRows(categories: plan.categories, budgets: plan.budgets),
        at: environment.now())
      guard store.apply(change) else { return false }
    }
    if !plan.tiles.isEmpty {
      environment.overviewTiles = OverviewTiles.sanitized(environment.overviewTiles + plan.tiles)
    }
    AppLog.info(
      "starter.applied", .db, "a starter set was applied",
      [
        LogPair("categories", .count(plan.categories.count)),
        LogPair("limits", .count(plan.budgets.count)), LogPair("tiles", .count(plan.tiles.count)),
      ])
    return true
  }

  /// «Продукты — 20,000 ₽»: the names of the limits' categories with their amounts.
  static func limitNames(
    _ plan: StarterAdditions, environment: AppEnvironment, dataset: Dataset?
  ) -> [String] {
    let all = (dataset?.categories ?? []) + plan.categories
    return plan.budgets.map { budget in
      let name = all.first { $0.id == budget.categoryId }?.name ?? ""
      return name + " — " + environment.money.rounded(budget.amountE4)
    }
  }
}

/// The starter set asked on the first launch or opened from Settings.
@MainActor @Observable
final class StarterSetOffer {
  static let shared = StarterSetOffer()
  var isRequested = false

  /// Due on a new database: after the cards of the guide, before the account questionnaire.
  static func isDue(_ environment: AppEnvironment, guide: GuideStore) -> Bool {
    environment.state == .ready && !AppEnvironment.isTestHost && AppPaths.dataSet == nil
      && environment.accountSetup == nil && guide.cards == nil && !StarterSetActions.wasAsked()
  }
}
