import AppCore
import Observation
import SwiftUI

extension View {
  /// The move from another application over the main window, opened by «Файл» → «Перенести из
  /// другого приложения…». Like every question the app raises by itself, never over the cover of
  /// the locked app.
  func migrationSheet(_ deps: AppDependencies) -> some View {
    modifier(MigrationPresenter(deps: deps))
  }
}

struct MigrationPresenter: ViewModifier {
  let deps: AppDependencies

  func body(content: Content) -> some View {
    let environment = deps.environment
    content
      .sheet(item: environment.lock.presenting(Bindable(environment).migrationRequest)) { _ in
        MigrationFlow().appDependencies(deps)
      }
  }
}
