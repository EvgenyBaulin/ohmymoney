import AppCore
import SwiftUI

/// «Зачем коплю» in a hard moment: the owner's own words about the goal, under what is about to
/// happen to its money. Words and a symbol, never colour alone.
struct GoalWhyReminder: View {
  @Dependency(\.environment) private var environment
  /// The key of the line in `Habits`: `goal.why.reminder` (one goal), `goal.why.lowered`.
  var key = "goal.why.reminder"
  let goal: Goal

  var body: some View {
    if let note = GoalWhy.clean(goal.whyNote) {
      Label {
        Text(verbatim: HabitText.f(key, environment, goal.name, note))
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "heart.text.square")
      }
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("goal.why")
    }
  }
}

/// The field of «Зачем коплю» in the form of a goal.
struct GoalWhyField: View {
  @Dependency(\.environment) private var environment
  @Binding var goal: Goal

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField(
        HabitText.t("goal.why.title", environment),
        text: Binding(get: { goal.whyNote ?? "" }, set: { goal.whyNote = $0 }),
        prompt: Text(verbatim: HabitText.t("goal.why.prompt", environment)), axis: .vertical
      )
      .lineLimit(1...4)
      .accessibilityIdentifier("goal.why.field")
      Text(verbatim: HabitText.t("goal.why.hint", environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

enum GoalWhyMoments {
  /// The plan of a saved goal is lowered: its note is worth a look before saving.
  static func planLowered(original: Goal?, edited: Goal) -> Bool {
    guard let original, let before = original.monthlyPlanE4, before.raw > 0 else { return false }
    return (edited.monthlyPlanE4 ?? .zero) < before
  }

  /// The goals whose notes «Потратили деньги цели?» shows: live goals with a note and money in
  /// them, at most `limit`, in the owner's order.
  static func exceeded(_ statuses: [GoalStatus], limit: Int = 3) -> [Goal] {
    Array(
      statuses.filter {
        !$0.goal.archived && $0.saved.raw > 0 && GoalWhy.clean($0.goal.whyNote) != nil
      }
      .map(\.goal)
      .prefix(limit))
  }

  /// The words of the dialog of deleting a goal: the usual message, and the note under it.
  @MainActor
  static func deletionMessage(_ base: String, goal: Goal?, _ environment: AppEnvironment) -> String
  {
    guard let goal, let note = GoalWhy.clean(goal.whyNote) else { return base }
    return base + "\n\n" + HabitText.f("goal.why.reminder", environment, goal.name, note)
  }
}
