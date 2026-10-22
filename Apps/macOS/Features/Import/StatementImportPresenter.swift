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

  /// Files a bank gives: a table, a text, a PDF. A dropped photo or a folder is not taken.
  static let fileExtensions: Set<String> = ["csv", "txt", "pdf"]

  static func statementFiles(in urls: [URL]) -> [URL] {
    urls.filter { fileExtensions.contains($0.pathExtension.lowercased()) }
  }

  func body(content: Content) -> some View {
    let environment = deps.environment
    content
      .sheet(item: environment.lock.presenting(Bindable(environment).statementImportRequest)) {
        request in
        StatementImportFlow(urls: request.urls).appDependencies(deps)
      }
      .dropDestination(for: URL.self) { dropped, _ in
        let files = Self.statementFiles(in: dropped)
        guard !files.isEmpty, environment.state == .ready, !environment.lock.isLocked else {
          return false
        }
        environment.statementImportRequest = StatementImportRequest(urls: files)
        return true
      }
  }
}
