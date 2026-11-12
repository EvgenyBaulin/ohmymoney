import AppCore
import Observation
import SwiftUI

extension View {
  /// The loading of statements over the main window: opened by «Файл» → «Импорт выписки…» or by
  /// files dropped on the window. Like every question the app raises by itself, never over the
  /// cover of the locked app.
  func statementImportSheet(_ deps: AppDependencies) -> some View {
    modifier(StatementImportPresenter(deps: deps))
  }
}

struct StatementImportPresenter: ViewModifier {
  let deps: AppDependencies

  func body(content: Content) -> some View {
    let environment = deps.environment
    content
      .sheet(item: environment.lock.presenting(Bindable(environment).statementImportRequest)) {
        request in
        StatementImportFlow(urls: request.urls).appDependencies(deps)
      }
      .entryImportSheet(deps)
  }
}
