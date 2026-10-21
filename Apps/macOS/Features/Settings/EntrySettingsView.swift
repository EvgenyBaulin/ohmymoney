import AppCore
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// Settings → «Ввод»: how a new operation is filled in — the line at the bottom of the window,
/// or the form of every field at the right, without a line and without suggestions — and the
/// order of the fields of the ↓ panel. The panel of the entry line, the form and the editor of a
/// saved operation lay their rows in it, and Tab walks them in it. A preference of the owner's,
/// like the theme: kept in `UserDefaults`, carried by the transfer archive, not a step of ⌘Z.
struct EntrySettingsView: View {
  @Dependency(\.environment) private var environment
  /// Read again whenever the app comes back to the front: the owner may have just turned
  /// «Навигация с клавиатуры» on in System Settings.
  @State private var fullKeyboardAccess = PanelTabOrder.fullKeyboardAccess

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker(
        selection: Binding(
          get: { environment.entryStyle }, set: { environment.entryStyle = $0 })
      ) {
        Text(verbatim: t("settings.entry.style.line")).tag(EntryStyle.line)
        Text(verbatim: t("settings.entry.style.form")).tag(EntryStyle.form)
      } label: {
        Text(verbatim: t("settings.entry.style"))
      }
      .pickerStyle(.menu)
      .fixedSize()
      .accessibilityIdentifier("settings.entry.style")
      hint("settings.entry.styleHint")
      Divider()

      List {
        Section {
          ForEach(environment.entryFieldOrder, id: \.self) { field in
            row(field)
          }
          .onMove { source, destination in
            EntrySettingsActions.move(environment, from: source, to: destination)
          }
        } header: {
          Text(verbatim: t("settings.entry.order"))
        }
      }
      .frame(minHeight: 200)

      HStack {
        Button(t("settings.entry.reset")) { EntrySettingsActions.reset(environment) }
          .disabled(EntryFieldOrder.isStandard(environment.entryFieldOrder))
        Spacer()
      }
      hint("settings.entry.orderHint")
      hint("settings.entry.returnHint")
      if !fullKeyboardAccess {
        Label {
          Text(verbatim: t("settings.entry.keyboardHint"))
        } icon: {
          Image(systemName: "keyboard")
        }
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding()
    #if os(macOS)
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        fullKeyboardAccess = PanelTabOrder.fullKeyboardAccess
      }
    #endif
  }

  /// A field: the handle to drag it by, its name, and «Выше» / «Ниже» for the keyboard and
  /// VoiceOver, in its menu and as its actions.
  private func row(_ field: EntryField) -> some View {
    let name = Self.name(of: field, environment)
    return HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(verbatim: name)
      Spacer()
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button(t("settings.entry.moveUp")) { EntrySettingsActions.move(environment, field, by: -1) }
        .disabled(!EntrySettingsActions.canMove(environment, field, by: -1))
      Button(t("settings.entry.moveDown")) { EntrySettingsActions.move(environment, field, by: 1) }
        .disabled(!EntrySettingsActions.canMove(environment, field, by: 1))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityAction(named: Text(verbatim: t("settings.entry.moveUp"))) {
      EntrySettingsActions.move(environment, field, by: -1)
    }
    .accessibilityAction(named: Text(verbatim: t("settings.entry.moveDown"))) {
      EntrySettingsActions.move(environment, field, by: 1)
    }
  }

  private func hint(_ key: String) -> some View {
    Text(verbatim: t(key))
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  /// What a field is called in the list.
  static func name(of field: EntryField, _ environment: AppEnvironment) -> String {
    let key: String
    switch field {
    case .amount: key = "settings.entry.field.amount"
    case .category: key = "settings.entry.field.category"
    case .quality: key = "settings.entry.field.quality"
    case .forWhom: key = "settings.entry.field.forWhom"
    case .place: key = "settings.entry.field.place"
    case .event: key = "settings.entry.field.event"
    case .account: key = "settings.entry.field.account"
    case .cashback: key = "settings.entry.field.cashback"
    case .goal: key = "settings.entry.field.goal"
    case .debt: key = "settings.entry.field.debt"
    case .note: key = "settings.entry.field.note"
    case .date: key = "settings.entry.field.date"
    case .incomeMonth: key = "settings.entry.field.incomeMonth"
    case .currency: key = "settings.entry.field.currency"
    }
    return environment.language(key, table: "Settings")
  }
}

/// What the tab of the order does, apart from the view so a test reads it without a window.
/// Every change is written at once (`AppEnvironment.entryFieldOrder`), and an open panel lays
/// its rows again.
@MainActor
enum EntrySettingsActions {
  /// A drag of the list (`onMove`).
  static func move(_ environment: AppEnvironment, from source: IndexSet, to destination: Int) {
    environment.entryFieldOrder = EntryFieldOrder.moving(
      environment.entryFieldOrder, from: source, to: destination)
  }

  /// «Выше» (`by: -1`) or «Ниже» (`by: 1`).
  static func move(_ environment: AppEnvironment, _ field: EntryField, by step: Int) {
    guard canMove(environment, field, by: step),
      let index = environment.entryFieldOrder.firstIndex(of: field)
    else { return }
    move(
      environment, from: IndexSet(integer: index), to: step < 0 ? index - 1 : index + 2)
  }

  static func canMove(_ environment: AppEnvironment, _ field: EntryField, by step: Int) -> Bool {
    guard let index = environment.entryFieldOrder.firstIndex(of: field) else { return false }
    return environment.entryFieldOrder.indices.contains(index + step)
  }

  /// «Сбросить»: the order of 1.1.
  static func reset(_ environment: AppEnvironment) {
    environment.entryFieldOrder = EntryFieldOrder.standard
  }
}
