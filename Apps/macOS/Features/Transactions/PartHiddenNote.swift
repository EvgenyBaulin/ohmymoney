import AppCore
import SwiftUI

/// «часть скрыта» next to a figure that holds money of a covered hidden account, whose
/// operations the list beside it does not show. It never says how much.
struct PartHiddenNote: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    Text(verbatim: Self.text(environment.language))
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .accessibilityIdentifier("privacy.partHidden")
  }

  /// The words, from the privacy catalog: the same as on the accounts in the sidebar.
  static func text(_ language: AppLanguage) -> String {
    language("privacy.partHidden", table: "PrivacyScreens")
  }
}
