import AppCore
import SwiftUI

/// «Категории самозанятого»: turning self-employment on with the ready categories «Заработок →
/// Самозанятость → от физлиц (4 %) / от организаций (6 %)», or with the owner's own categories —
/// their rates are then marked in «Настройки → Категории». One record, one step of ⌘Z.
/// Opened from «Настройки → Планирование» and from the offer after a first income of the kind.
struct SelfEmploymentSetupSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @State private var ready = true

  var body: some View {
    VStack(alignment: .leading) {
      Text(verbatim: AllocationText.t("selfEmployed.setup.title", environment))
        .appFont(.headline)
      Form {
        Picker(selection: $ready) {
          Text(verbatim: AllocationText.t("selfEmployed.setup.ready", environment)).tag(true)
          Text(verbatim: AllocationText.t("selfEmployed.setup.own", environment)).tag(false)
        } label: {
          EmptyView()
        }
        .pickerStyle(.radioGroup)
        Text(
          verbatim: AllocationText.t(
            ready ? "selfEmployed.setup.readyHint" : "selfEmployed.setup.ownHint", environment)
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      FormButtons(title: AllocationText.t("selfEmployed.setup.enable", environment), enabled: true)
      {
        guard let dependencies else { return false }
        return SelfEmploymentActions(dependencies).enable(ready: ready)
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 300)
  }
}
