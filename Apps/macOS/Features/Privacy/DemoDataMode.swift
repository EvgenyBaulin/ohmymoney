import AppCore
import SwiftUI

/// «Показать на учебных данных»: the app opens again on the synthetic set of the tutorial, so the
/// owner can show it to somebody without showing a single real figure, and goes back to the real
/// books with one press. The real database is not opened, written or even listed meanwhile: the
/// set has a folder of its own (`AppPaths.DataSet.learn`), and the way back is the relaunch the
/// tutorial already uses.
enum DemoDataMode {
  /// The set the app shows on: the tutorial's, made by the app itself in every build.
  static let dataSet: AppPaths.DataSet = .learn

  /// Whether `dataSet` (the one this launch runs on) is the demonstration.
  static func isOn(_ running: AppPaths.DataSet? = AppPaths.dataSet) -> Bool {
    running == dataSet
  }

  /// The set the relaunch of each step opens: the demonstration to show, the real books (`nil`) to
  /// go back to.
  static func target(entering: Bool) -> AppPaths.DataSet? {
    entering ? dataSet : nil
  }

  /// The app opens again on the demonstration.
  @MainActor
  static func enter() {
    AppLog.info("privacy.demoEntered", .ui, "the app was asked to show the training data")
    AppRestart.relaunch(into: target(entering: true))
  }

  /// The app opens again on the owner's own books.
  @MainActor
  static func leave() {
    AppLog.info("privacy.demoLeft", .ui, "the app was asked to go back to the real books")
    AppRestart.relaunch(into: target(entering: false))
  }
}

/// The wide strip over the window while the training data are on: whatever is on the screen is
/// not the owner's, and the way back is in it.
struct DemoDataBanner: View {
  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { environment.language(key, table: "PrivacyExport") }

  var body: some View {
    HStack(spacing: 12) {
      Label {
        Text(verbatim: t("privacy.demo.banner")).fontWeight(.semibold)
      } icon: {
        Image(systemName: "eye.trianglebadge.exclamationmark")
      }
      Text(verbatim: t("privacy.demo.banner.hint"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Spacer(minLength: 8)
      Button(t("privacy.demo.back")) { DemoDataMode.leave() }
        .accessibilityIdentifier("privacy.demo.back")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.orange.opacity(0.18))
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("privacy.demo.banner")
  }
}
