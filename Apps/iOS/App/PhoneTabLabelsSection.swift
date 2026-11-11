import AppCore
import SwiftUI

/// «Оформление» on the phone: names under every tab of the bottom bar (the default), or only
/// under the open one.
struct PhoneTabLabelsSection: View {
  @Dependency(\.environment) private var environment
  @AppStorage(PhoneTabLabels.activeOnlyKey) private var activeOnly = false

  var body: some View {
    Section {
      Toggle(isOn: $activeOnly) {
        Text(verbatim: environment.language("appearance.tabLabels.activeOnly", table: "Appearance"))
      }
      .accessibilityIdentifier("settings.appearance.tabLabels.activeOnly")
    } footer: {
      Text(verbatim: environment.language("appearance.tabLabels.hint", table: "Appearance"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
    }
  }
}
