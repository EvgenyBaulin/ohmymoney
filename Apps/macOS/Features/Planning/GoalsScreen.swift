import AppCore
import SwiftUI

/// «Цели» as a screen of its own, the way the design draws it: one card per goal — the name and
/// its target over the tile, what is saved, the share and the bar —, the safety cushion among
/// them, and the card of the income allocation with its rules and the button that splits the
/// income waiting for it. Two columns on a wide window, one on a phone. The words and figures
/// are the core's; the contributions themselves are made from the goal's row in Planning.
struct GoalsScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeSurfaces) private var surfaces
  @State private var width: CGFloat = 0
  @State private var tripGoal: GoalStatus?
  @State private var allocation: AllocationRequest?
  @State private var showsRules = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top) {
          ScreenTitleBlock(
            title: t("goals.screen.title"), subtitle: t("goals.screen.subtitle"),
            identifier: "goals.screen.title")
          Spacer(minLength: 8)
          Button(environment.language("action.ok")) { dismiss() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("goals.screen.done")
        }
        if let snapshot = compute.snapshot {
          cards(snapshot)
        } else {
          Text(verbatim: t("goals.none")).foregroundStyle(.secondary)
        }
      }
      .padding(20)
    }
    .background(surfaces.background)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .sheetFrame(minWidth: 520, idealWidth: 860, minHeight: 480, idealHeight: 640)
    .sheet(item: $tripGoal) { status in
      TripFromGoalSheet(status: status).handingOver(dependencies)
    }
    .sheet(item: $allocation) { request in
      AllocationSheetView(request: request).handingOver(dependencies)
    }
    .sheet(isPresented: $showsRules) {
      AllocationRulesSheet().handingOver(dependencies)
    }
    .accessibilityIdentifier("goals.screen")
  }

  // MARK: Cards

  @ViewBuilder
  private func cards(_ snapshot: DataSnapshot) -> some View {
    let columns = ScreenColumns.count(forWidth: width - 40)
    let items = Self.items(of: snapshot)
    let laid = ScreenColumns.deal(items, into: columns)
    HStack(alignment: .top, spacing: 16) {
      ForEach(Array(laid.enumerated()), id: \.offset) { _, column in
        VStack(alignment: .leading, spacing: 16) {
          ForEach(column) { item in
            card(item, snapshot: snapshot)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  /// What the screen lists, in order: the goals, the cushion after them, the allocation last.
  enum Item: Identifiable {
    case goal(GoalStatus)
    case cushion(CushionStatus)
    case allocation

    var id: String {
      switch self {
      case .goal(let status): "goal-\(status.goal.id)"
      case .cushion: "cushion"
      case .allocation: "allocation"
      }
    }
  }

  static func items(of snapshot: DataSnapshot) -> [Item] {
    var items = GoalOrder.shown(snapshot.planning.goals).map(Item.goal)
    if snapshot.planning.cushion.state == .ready {
      items.append(.cushion(snapshot.planning.cushion))
    }
    items.append(.allocation)
    return items
  }

  @ViewBuilder
  private func card(_ item: Item, snapshot: DataSnapshot) -> some View {
    switch item {
    case .goal(let status): goalCard(status, snapshot: snapshot)
    case .cushion(let status): cushionCard(status)
    case .allocation: allocationCard(snapshot)
    }
  }

  private func goalCard(_ status: GoalStatus, snapshot: DataSnapshot) -> some View {
    let money = environment.money
    let complete = GoalProgressBar.isComplete(basisPoints: status.progressBp)
    let saved = money.rounded(status.saved, currency: status.currency)
    return VStack(alignment: .leading, spacing: 10) {
      ScreenCardHeader(
        title: status.goal.name,
        caption: complete
          ? t("goals.screen.reached")
          : environment.format(
            "goals.screen.target", table: "Planning",
            money.rounded(status.goal.targetE4, currency: status.currency)))
      goalLine(
        tile: GoalTile(complete: complete),
        title: environment.format(
          complete ? "goals.screen.gathered" : "goals.screen.saved", table: "Planning", saved),
        subtitle: planLine(status),
        share: money.percent(basisPoints: status.progressBp, fractionDigits: 0),
        complete: complete)
      GoalProgressBar(basisPoints: status.progressBp)
      if let account = accountLine(status.goal, snapshot: snapshot) {
        Text(verbatim: account)
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if TripGoal.readyBudget(target: status.goal.targetE4, saved: status.saved) != nil {
        Button {
          tripGoal = status
        } label: {
          Text(verbatim: TravelText.t("travel.goal.make", environment))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        .accessibilityIdentifier("goals.screen.makeTrip")
      }
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: status.goal.name))
  }

  private func cushionCard(_ status: CushionStatus) -> some View {
    let weights = CushionText.barWeights(status)
    let whole = max(weights.reduce(0, +), 1)
    let monthly = status.obligatory.monthlyRub.map { environment.money.rounded($0) }
    return VStack(alignment: .leading, spacing: 10) {
      ScreenCardHeader(
        title: CushionText.t("cushion.planning.name", environment),
        caption: environment.format(
          "goals.screen.cushionGoal", table: "Planning", String(CushionText.targetMonths(status))))
      goalLine(
        tile: GoalTile(complete: false, symbol: CushionText.symbol),
        title: environment.format(
          "goals.screen.saved", table: "Planning", environment.money.rounded(status.moneyRub)),
        subtitle: monthly.map {
          environment.format("goals.screen.obligatory", table: "Planning", $0)
        } ?? CushionText.barLabel(status, environment),
        share: environment.money.percent(
          basisPoints: weights[0] * Shares.whole / whole, fractionDigits: 0),
        complete: weights[1] == 0)
      GoalProgressBar(basisPoints: weights[0] * Shares.whole / whole)
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: CushionText.t("cushion.planning.name", environment)))
  }

  /// The row of a card: the tile, two lines of words, the share at the right.
  private func goalLine(
    tile: GoalTile, title: String, subtitle: String?, share: String, complete: Bool
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      tile
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .appFont(.body.monospacedDigit())
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        if let subtitle {
          Text(verbatim: subtitle)
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 6)
      Text(verbatim: share)
        .appFont(.body.weight(.semibold).monospacedDigit())
        .foregroundStyle(complete ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
  }

  /// «до 1 декабря · план 12 700 ₽/мес.»: the date and the plan the goal has, whichever it has.
  private func planLine(_ status: GoalStatus) -> String? {
    let money = environment.money
    let plan = status.goal.monthlyPlanE4.map { money.rounded($0, currency: status.currency) }
    switch (status.goal.targetDate, plan) {
    case (let day?, let plan?):
      return environment.format(
        "goals.screen.plan", table: "Planning", PlanningBlockText.dayText(day, environment), plan)
    case (let day?, nil):
      return environment.format(
        "goals.screen.until", table: "Planning", PlanningBlockText.dayText(day, environment))
    case (nil, let plan?):
      return environment.format("goals.screen.planOnly", table: "Planning", plan)
    case (nil, nil):
      return nil
    }
  }

  /// «Счёт цели: Накопительный · перевод при взносе включён».
  private func accountLine(_ goal: Goal, snapshot: DataSnapshot) -> String? {
    guard let id = goal.accountId,
      let name = snapshot.dataset.paymentMethods.first(where: { $0.id == id })?.name
    else { return nil }
    var line = environment.format("goals.screen.account", table: "Planning", name)
    if goal.transfersOnContribution { line += " · " + t("goals.screen.transfers") }
    return line
  }

  // MARK: Allocation

  private func allocationCard(_ snapshot: DataSnapshot) -> some View {
    let rules = snapshot.dataset.allocationRules.filter(\.active).sorted { $0.sort < $1.sort }
    let offer = snapshot.planning.allocationOffers.first.flatMap {
      AllocationActions.sheet(for: $0, snapshot: snapshot)
    }
    return VStack(alignment: .leading, spacing: 8) {
      ScreenCardHeader(title: t("goals.screen.allocation"), caption: t("goals.screen.rules"))
      if rules.isEmpty {
        Text(verbatim: t("goals.screen.noRules"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(rules) { rule in
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: ruleName(rule, snapshot: snapshot))
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 8)
          Text(verbatim: ruleAmount(rule))
            .appFont(.callout.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
      }
      if let offer, let request = snapshot.planning.allocationOffers.first {
        Button {
          allocation = AllocationRequest(incomeId: request)
        } label: {
          Text(
            verbatim: environment.format(
              "goals.screen.allocate", table: "Planning",
              environment.money.rounded(offer.incomeE4, currency: offer.currency))
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        .accessibilityIdentifier("goals.screen.allocate")
      }
      Button {
        showsRules = true
      } label: {
        Text(verbatim: t("goals.screen.rulesOpen")).frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)

      .accessibilityIdentifier("goals.screen.rules")
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: t("goals.screen.allocation")))
  }

  private func ruleName(_ rule: AllocationRule, snapshot: DataSnapshot) -> String {
    switch rule.target {
    case .goal(let id): snapshot.dataset.goals.first { $0.id == id }?.name ?? ""
    case .account(let id): snapshot.dataset.paymentMethods.first { $0.id == id }?.name ?? ""
    case .cushion: CushionText.t("cushion.planning.name", environment)
    }
  }

  private func ruleAmount(_ rule: AllocationRule) -> String {
    switch rule.amount {
    case .percent(let percent):
      environment.language.locale.language.languageCode?.identifier == "ru"
        ? NumberText.decimal(percent, fractionDigits: 0...2) + "\u{00A0}%"
        : NumberText.decimal(percent, fractionDigits: 0...2) + "%"
    case .fixed(let amount, let currency):
      environment.money.rounded(amount, currency: currency)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
