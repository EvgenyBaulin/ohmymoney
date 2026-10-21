import AppCore
import AppDatabase
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// Goals: progress, what is needed a month and whether it is realistic; «Contribute» and
/// «Withdraw». A goal put in the archive is listed when asked, with «Вернуть» and «Удалить…».
struct GoalsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.planningCardHosted) private var hosted
  @Binding var sheet: PlanningSheet?
  /// How many of the nearest goals show before «Показать все»: nearest by the day each is for.
  var length: PlanningListLength = .all
  @State private var showsAll = false
  @State private var showsArchive = false
  /// The archived goal «Удалить…» asks about.
  @State private var deleting: Goal?
  /// Why an archived goal was not deleted, as a key of the Planning table, by the goal's id.
  @State private var deletionNotes: [UUID: String] = [:]
  /// The gathered goal «Сделать поездкой…» was pressed on.
  @State private var tripGoal: GoalStatus?

  var body: some View {
    ComputedBlock(
      title: hosted ? nil : t("goals.title"), state: compute.states.data,
      style: hosted ? .plain : .card, fillsHeight: !hosted,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 12) {
        // The safety cushion is not a goal — its money is moved by transfers, not put into
        // «Цели» —, but it is saved for like one: its row stands first, with the way to
        // «Капитал».
        CushionPlanningRow(status: snapshot.planning.cushion)
        Divider()
        let goals = snapshot.planning.goals
        let ordered = GoalOrder.shown(goals)
        let split = PlanningShortList.split(
          total: ordered.count, length: length, expanded: showsAll)
        let shown = (items: Array(ordered.prefix(split.shown)), hidden: split.hidden)
        if goals.isEmpty {
          if hosted {
            PlanningEmptyHint(block: .goals) { sheet = .goal(nil) }
              .guideTarget(GuideTarget.planningAddGoal)
          } else {
            Text(verbatim: t("goals.none")).foregroundStyle(.secondary)
          }
        }
        ForEach(shown.items) { status in
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
              Text(verbatim: status.goal.name).lineLimit(1)
              Spacer(minLength: 6)
              Text(
                verbatim: environment.money.percent(
                  basisPoints: status.progressBp, fractionDigits: 0)
              )
              .monospacedDigit()
              .foregroundStyle(.secondary)
            }
            Capsule()
              .fill(.quaternary)
              .overlay {
                ProportionalRow(
                  weights: [
                    min(status.progressBp, Shares.whole),
                    Shares.whole - min(status.progressBp, Shares.whole),
                  ]
                ) {
                  Capsule().fill(.tint)
                  Color.clear
                }
              }
              .frame(height: 4)
              .accessibilityHidden(true)
            // In the goal's own currency: a dollar goal is saved in dollars.
            Text(
              verbatim: String(
                format: t("planning.spentOf"), locale: environment.language.locale,
                environment.money.rounded(status.saved, currency: status.currency),
                environment.money.rounded(status.goal.targetE4, currency: status.currency))
            )
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if status.withoutRate > 0 {
              Label {
                Text(
                  verbatim: environment.format(
                    "goals.withoutRate", table: "Planning", counts: status.withoutRate))
              } icon: {
                Image(systemName: "hourglass")
              }
              .appFont(.caption)
              .foregroundStyle(.secondary)
            }
            Text(verbatim: realism(status))
              .appFont(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if let ahead = Self.paidAhead(of: status.goal, snapshot), ahead.raw > 0 {
              Text(
                verbatim: environment.format(
                  "goals.ahead", table: "Planning",
                  environment.money.rounded(ahead, currency: status.currency))
              )
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Button(t("goals.contribute")) { sheet = .moveGoal(status, withdraw: false) }
                .buttonStyle(.bordered)
              Button(t("goals.withdraw")) { sheet = .moveGoal(status, withdraw: true) }
                .buttonStyle(.bordered)
                .disabled(status.saved.raw <= 0)
              // A goal that has gathered what it was for can become the trip it was saved for.
              if TripGoal.readyBudget(target: status.goal.targetE4, saved: status.saved) != nil {
                Button(TravelText.t("travel.goal.make", environment)) { tripGoal = status }
                  .buttonStyle(.bordered)
                  .help(TravelText.t("travel.goal.help", environment))
                  .accessibilityIdentifier("goal.makeTrip")
              }
            }
            .controlSize(.small)
          }
          .draggable(GoalOrder.payload(of: status.goal.id)) {
            Text(verbatim: status.goal.name).padding(6)
          }
          .dropDestination(for: String.self) { payloads, _ in
            guard let moved = payloads.lazy.compactMap(GoalOrder.goal(in:)).first,
              let ids = GoalOrder.ids(
                moving: moved, onto: status.goal.id, in: ordered.map(\.goal.id)),
              let dependencies
            else { return false }
            return PlanningActions(dependencies).reorderGoals(ids)
          }
          .contextMenu {
            Button(environment.language("action.edit")) { sheet = .goal(status.goal) }
            Button(t("goals.archive")) {
              if let dependencies { PlanningActions(dependencies).archive(status.goal) }
            }
          }
        }
        PlanningShowAllButton(
          block: .goals, total: goals.count, hidden: shown.hidden, expanded: $showsAll)
        if !(hosted && goals.isEmpty) {
          Button(t("goals.add")) { sheet = .goal(nil) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .guideTarget(GuideTarget.planningAddGoal)
        }
        archive(snapshot.dataset.goals.filter(\.archived))
      }
    }
    .sheet(item: $tripGoal) { status in
      TripFromGoalSheet(status: status).handingOver(dependencies)
    }
    .confirmationDialog(
      environment.format("form.goal.delete.title", table: "Planning", deleting?.name ?? ""),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button(environment.language("action.delete"), role: .destructive) {
        if let deleting { delete(deleting) }
        deleting = nil
      }
      Button(environment.language("action.cancel"), role: .cancel) { deleting = nil }
    } message: {
      Text(verbatim: t("form.goal.delete.message"))
    }
  }

  /// The goals in the archive, behind «Показывать архив» while there are any. «Вернуть» brings
  /// one back as it was — one step of ⌘Z, as its archiving was. «Удалить…» asks the question
  /// of the goal form: the goal goes, its contributions stay spending as they were; a goal with
  /// a contribution filed outside «Цели» is not deleted, and the row says so instead.
  @ViewBuilder
  private func archive(_ archived: [Goal]) -> some View {
    if !archived.isEmpty {
      Toggle(isOn: $showsArchive) {
        Text(
          verbatim: environment.format(
            "goals.showArchive", table: "Settings", counts: archived.count))
      }
      .toggleStyle(.checkbox)
      .controlSize(.small)
      if showsArchive {
        ForEach(archived) { goal in
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: s("goals.inArchive")))
              Text(verbatim: goal.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
              Spacer(minLength: 6)
              Button(s("goals.restore")) { restore(goal) }
                .buttonStyle(.bordered)
                .controlSize(.small)
              if GoalForm.offersDeletion(after: deletionNotes[goal.id]) {
                Button(s("references.deleteAsk")) { askToDelete(goal) }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
              }
            }
            if let note = deletionNotes[goal.id] {
              Text(verbatim: t(note))
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
  }

  private func restore(_ goal: Goal) {
    guard let dependencies else { return }
    deletionNotes[goal.id] = nil
    let restored = Self.restore(
      goal.id, with: PlanningActions(dependencies), references: environment.references)
    // A live goal has the name: the row says so instead of staying silent.
    if !restored,
      GoalForm.liveNamesake(of: goal, among: (try? environment.references?.goals()) ?? []) != nil
    {
      deletionNotes[goal.id] = "form.goal.liveNamesake"
    }
  }

  private func askToDelete(_ goal: Goal) {
    guard let dependencies else { return }
    switch Self.askToDelete(goal, with: PlanningActions(dependencies)) {
    case .ask:
      deletionNotes[goal.id] = nil
      deleting = goal
    case .refused(let note):
      deletionNotes[goal.id] = note
    }
  }

  private func delete(_ goal: Goal) {
    guard let dependencies else { return }
    deletionNotes[goal.id] = Self.delete(goal, with: PlanningActions(dependencies))
  }

  /// What «Удалить…» of an archived row comes to before anything is written.
  enum DeletionAsk: Equatable {
    /// The goal may go: the question is asked.
    case ask
    /// It may not, or the database could not be read: what the row says instead, as a key
    /// of the Planning table.
    case refused(note: String)
  }

  /// «Удалить…» of the archived `goal`: the question, or why it is not asked — a contribution
  /// filed outside «Цели» keeps the goal for good (the button then goes), anything else is
  /// «not saved» and may be tried again. Read from the database as it is now.
  static func askToDelete(_ goal: Goal, with actions: PlanningActions) -> DeletionAsk {
    switch actions.deletion(of: goal) {
    case .success: return .ask
    case .failure(let refusal): return .refused(note: GoalForm.deletionNote(refusedBy: refusal))
    case .none: return .refused(note: GoalForm.deletionNote(refusedBy: nil))
    }
  }

  /// «Удалить» in the question: the archived `goal` deleted, its operations kept — one step of
  /// ⌘Z. Nil once it is gone; otherwise what the row says, as a key of the Planning table.
  @discardableResult
  static func delete(_ goal: Goal, with actions: PlanningActions) -> String? {
    switch actions.deleteArchived(goal) {
    case .deleted: return nil
    case .refused(let refusal): return GoalForm.deletionNote(refusedBy: refusal)
    case .notWritten: return GoalForm.deletionNote(refusedBy: nil)
    }
  }

  /// «Вернуть» of the goal `id`: read again from the database — the snapshot the block shows
  /// may be older than a change made since — and written back live, one step of ⌘Z. False when
  /// there is no such goal any more or the write was refused.
  @discardableResult
  static func restore(
    _ id: UUID, with actions: PlanningActions, references: ReferenceRepository?
  ) -> Bool {
    guard
      var goal = (try? references?.goals(includeArchived: true))?.first(where: { $0.id == id })
    else { return false }
    guard goal.archived else { return true }
    goal.archived = false
    return actions.save(goal)
  }

  /// «Нужно 18 300 ₽ в месяц · успеваете по плану», «при плане — к марту 2027».
  private func realism(_ status: GoalStatus) -> String {
    var pieces: [String] = []
    if let needed = status.neededMonthly {
      pieces.append(
        environment.format(
          "goals.needed", table: "Planning",
          environment.money.rounded(needed, currency: status.currency)))
    }
    pieces.append(t("goals.realism.\(status.realism.rawValue)"))
    if status.realism == .behindPlan || status.realism == .noDate,
      let month = status.projectedCompletion
    {
      pieces.append(
        environment.format(
          "goals.projected", table: "Planning", environment.dates.monthTitle(month)))
    }
    return pieces.joined(separator: " · ")
  }

  /// What went into `goal` above its monthly plans and counts towards the months after this
  /// one, in the goal's currency (`GoalPlanState.creditOut`); `nil` without a plan.
  static func paidAhead(of goal: Goal, _ snapshot: DataSnapshot) -> AmountE4? {
    GoalMath.planState(
      goal: goal, rows: snapshot.ledger.rows, month: snapshot.today.monthKey,
      rates: snapshot.planning.dayRates
    )?.creditOut
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
  /// The words of the archive, shared with Settings.
  private func s(_ key: String) -> String { environment.language(key, table: "Settings") }
}
