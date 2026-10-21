import AppCore
import SwiftUI

/// The strip over the main window while the tutorial is on: «Учебный режим · 3 из 10», the tasks
/// and «Выйти из учебного режима». A task chosen in the list frames the place to press.
struct TutorialBar: View {
  @Dependency(\.environment) private var environment
  let guide: GuideStore
  @State private var showsTasks = false

  private var russian: Bool { environment.language.resolvedCode.hasPrefix("ru") }
  private func t(_ key: String) -> String { environment.language(key, table: "Guide") }

  var body: some View {
    let state = guide.tutorial
    HStack(spacing: 12) {
      Label {
        Text(verbatim: t("guide.tutorial.title"))
          .fontWeight(.semibold)
      } icon: {
        Image(systemName: "graduationcap")
      }
      ProgressView(value: Double(state.done), total: Double(max(state.tasks.count, 1)))
        .frame(width: 90)
        .accessibilityHidden(true)
      Text(verbatim: String(format: t("guide.tutorial.progress"), state.done, state.tasks.count))
        .monospacedDigit()
        .accessibilityIdentifier("guide.tutorial.progress")
      Spacer(minLength: 8)
      Button(t("guide.tutorial.tasks")) { showsTasks.toggle() }
        .accessibilityIdentifier("guide.tutorial.tasks")
        .popover(isPresented: $showsTasks, arrowEdge: .bottom) { tasks(state.tasks) }
      Button(t("guide.tutorial.exit")) { GuideActions.leaveTutorial() }
        .accessibilityIdentifier("guide.tutorial.exit")
    }
    .controlSize(.small)
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(.background.secondary)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func tasks(_ tasks: [GuideTask]) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(tasks) { task in
          let done = guide.isDone(task)
          Button {
            guide.framedTask = done ? nil : task.id
            showsTasks = false
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: task.title.text(russian: russian))
                  .strikethrough(done)
                if !done, let hint = task.hints.first {
                  HStack(spacing: 6) {
                    Text(verbatim: hint.text.text(russian: russian))
                    if let keys = hint.keys {
                      Text(verbatim: keys).appFont(.caption.monospaced())
                    }
                  }
                  .appFont(.caption)
                  .foregroundStyle(.secondary)
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            Text(
              verbatim: task.title.text(russian: russian) + ", "
                + (done ? t("guide.tutorial.taskDone") : t("guide.tutorial.taskOpen")))
          )
          .accessibilityIdentifier("guide.task.\(task.id)")
        }
      }
      .padding(14)
    }
    .frame(width: 360, height: 380)
  }
}

/// What the Help menu and the tutorial strip do.
@MainActor
enum GuideActions {
  /// «Справка → Учебный режим»: the app opens again on the tutorial's set.
  static func enterTutorial() {
    AppLog.info("guide.tutorialEntered", .ui, "the tutorial was asked for")
    AppRestart.relaunch(into: .learn)
  }

  /// «Выйти из учебного режима»: the app opens again on the owner's own data.
  static func leaveTutorial() {
    AppLog.info("guide.tutorialLeft", .ui, "the tutorial was left")
    AppRestart.relaunch(into: nil)
  }

  /// «Начать заново»: the tasks forgotten, the set made anew, the tutorial opened again.
  static func restartTutorial() {
    GuideStore.shared.restartTutorial()
    AppRestart.relaunch(into: .learn)
  }
}
