import AppCore
import Observation
import SwiftUI

/// What the File menu asks the main window to show: the dialog of a locked copy, the report of
/// what the app keeps, the banner's way back. A request is a value the window presents, so the
/// menu never reaches into a view.
@MainActor
@Observable
final class PrivacyRequests {
  static let shared = PrivacyRequests()

  /// A dialog of «Экспорт копии…» asked for; each ask is a fresh form.
  struct CopyAsk: Identifiable, Equatable {
    let id = UUID()
    var format: ExportCopyRequest.Format
  }

  var copy: CopyAsk?
  var storage = false

  func askCopy(format: ExportCopyRequest.Format = .archive) {
    copy = CopyAsk(format: format)
  }
}

/// The sheets of the privacy menu items, hung on the main window. A sheet is laid out by a host of
/// its own, so the dependencies are handed over; and none of them comes over the cover of the
/// locked app.
private struct PrivacySheets: ViewModifier {
  let deps: AppDependencies
  @Bindable private var requests = PrivacyRequests.shared

  func body(content: Content) -> some View {
    content
      .sheet(item: deps.environment.lock.presenting($requests.copy)) { ask in
        ExportCopyView(model: PrivacyScreens.exportModel(deps.environment, format: ask.format))
          .appDependencies(deps)
      }
      .sheet(isPresented: deps.environment.lock.presenting($requests.storage)) {
        StorageReportView().appDependencies(deps)
      }
  }
}

extension View {
  /// «Файл → Экспорт копии…» and «Файл → Что знает приложение…» open over this view.
  func privacySheets(_ deps: AppDependencies) -> some View {
    modifier(PrivacySheets(deps: deps))
  }
}
