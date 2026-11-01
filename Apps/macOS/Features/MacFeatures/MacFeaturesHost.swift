import AppCore
import CoreSpotlight
import SwiftUI

/// What the main window does for the features of the Mac outside it: after every change of the
/// figures the notifications and the Spotlight index follow the data; the app's explanation
/// before the system asks permission for notifications; a Spotlight result opened finds its
/// operation in «Операции».
private struct MacFeaturesHost: ViewModifier {
  let deps: AppDependencies
  @State private var notifications = MacNotifications.shared

  private var environment: AppEnvironment { deps.environment }
  private func t(_ key: String) -> String { environment.language(key, table: MacCommands.table) }

  func body(content: Content) -> some View {
    content
      .task(id: deps.compute.generation) {
        guard !AppEnvironment.isTestHost else { return }
        await MacNotifications.shared.refresh(deps)
        await SpotlightIndexer.shared.refresh(deps)
      }
      .alert(
        t("mac.notify.explain.title"),
        isPresented: Binding(
          get: { notifications.explaining && !environment.lock.isLocked },
          set: { shown in if !shown { notifications.explaining = false } })
      ) {
        Button(t("mac.notify.explain.allow")) {
          Task { await notifications.answerExplanation(allow: true) }
        }
        Button(t("mac.notify.explain.later"), role: .cancel) {
          Task { await notifications.answerExplanation(allow: false) }
        }
      } message: {
        Text(verbatim: t("mac.notify.explain.message"))
      }
      .onContinueUserActivity(CSSearchableItemActionType) { activity in
        guard let found = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
          let id = SpotlightPlan.operationId(of: found)
        else { return }
        AppLog.info("spotlight.opened", .ui, "a Spotlight result was opened")
        OperationReveal.ask(id)
      }
  }
}

extension View {
  func macFeatures(_ deps: AppDependencies) -> some View {
    modifier(MacFeaturesHost(deps: deps))
  }
}
