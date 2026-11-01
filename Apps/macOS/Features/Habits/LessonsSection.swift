import AppCore
import SwiftUI

/// «Уроки» as a list: each lesson opens its five cards in the guide. The iPhone and the iPad show
/// it in «Ещё»; the Mac has the same list in «Справка → Уроки».
struct LessonsSection: View {
  let environment: AppEnvironment

  private var russian: Bool { environment.language.resolvedCode.hasPrefix("ru") }

  var body: some View {
    Section {
      ForEach(GuideLessons.all) { lesson in
        Button {
          GuideStore.shared.show(lesson.scenario)
        } label: {
          Label(lesson.title.text(russian: russian), systemImage: lesson.symbol)
        }
        .accessibilityIdentifier("lessons.\(lesson.id)")
      }
    } header: {
      Text(verbatim: HabitText.t("lessons.title", environment))
    } footer: {
      Text(verbatim: HabitText.t("lessons.subtitle", environment))
    }
  }
}
