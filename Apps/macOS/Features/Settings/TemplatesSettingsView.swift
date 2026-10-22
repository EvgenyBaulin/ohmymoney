import AppCore
import AppDatabase
import SwiftUI

/// Templates are the chips under the entry line: what I enter often, and what I pinned
/// myself. They fill themselves from real usage, so this screen is mostly about pinning,
/// renaming and putting away what turned out to be noise.
///
/// A template put in the archive leaves the chips but is still remembered — the next use of
/// its words counts on it instead of making a new chip — and «Вернуть» brings it back. The
/// archive is listed when asked. Deleting forgets a template for good; it holds no money.
///
/// The chips of the main window may show the same templates: every write here writes only what
/// it changes — the pin, the words, the archive flag — and tells the chips
/// (`templatesChanged`), and a write of theirs is read here again the same way.
struct TemplatesSettingsView: View {
  @Dependency(\.environment) private var environment
  /// Every template, the archived ones too; the list shows the archive when asked.
  @State private var templates: [Template] = []
  @State private var showsArchive = false
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Spacer()
        Toggle(isOn: $showsArchive) {
          Text(verbatim: t("templates.showArchive"))
        }
        .toggleStyle(.checkbox)
      }
      List {
        Section {
          ForEach($templates, id: \.id) { $template in
            if !template.archived { liveRow($template) }
          }
        }
        if showsArchive, templates.contains(where: \.archived) {
          Section {
            ForEach(templates.filter(\.archived), id: \.id) { template in
              archivedRow(template)
            }
          } header: {
            Text(verbatim: t("templates.archiveSection"))
              .settingsHeaderStyle()
          }
        }
      }
      .frame(minHeight: 240)

      Text(verbatim: t("templates.hint"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
    }
    .padding()
    .onAppear(perform: reload)
    .onReceive(NotificationCenter.default.publisher(for: .templatesChanged)) { _ in reload() }
    .refusedWriteAlert($refused, environment)
  }

  /// What the pin of a row says it will do: unpin a pinned template, pin any other.
  static func pinCaptionKey(pinned: Bool) -> String {
    pinned ? "templates.unpin" : "templates.pin"
  }

  private func liveRow(_ template: Binding<Template>) -> some View {
    // The pin says what pressing it does, «Открепить» on a pinned template: the filled pin
    // alone told the state to the eye only, and VoiceOver read the name of the symbol.
    let pinned = template.wrappedValue.pinned
    let pinCaption = t(Self.pinCaptionKey(pinned: pinned))
    return HStack(spacing: 10) {
      Button {
        write("templates.save") {
          try $0.setTemplate(template.wrappedValue.id, pinned: !pinned)
        }
      } label: {
        Image(systemName: pinned ? "pin.fill" : "pin")
      }
      .buttonStyle(.borderless)
      .help(pinCaption)
      .accessibilityLabel(Text(verbatim: pinCaption))

      TextField(text: template.text) { EmptyView() }
        .labelsHidden()
        .textFieldStyle(.plain)
        .onSubmit { rename(template.wrappedValue) }

      details(template.wrappedValue)

      Menu {
        Button(t("templates.archive")) { setArchived(template.wrappedValue, true) }
        Divider()
        Button(environment.language("action.delete"), role: .destructive) {
          delete(template.wrappedValue)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(
            Text(verbatim: SettingsRowMenu.label(template.wrappedValue.text, environment)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  private func archivedRow(_ template: Template) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text(verbatim: t("templates.inArchive")))
      Text(verbatim: template.text)
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 6)
      details(template)
      Button(t("templates.restore")) { setArchived(template, false) }
        .controlSize(.small)
      Menu {
        Button(environment.language("action.delete"), role: .destructive) { delete(template) }
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(template.text, environment)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  /// The amount in the currency its chip enters it in (`amountCurrency`), and how often it
  /// was used.
  @ViewBuilder
  private func details(_ template: Template) -> some View {
    if let amount = template.amountE4 {
      let currency = Self.amountCurrency(of: template, defaultCurrency: environment.defaultCurrency)
      Text(verbatim: environment.money.exact(amount, currency: currency))
        .appFont(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    Text(
      verbatim: environment.format("templates.used", table: "Settings", counts: template.useCount)
    )
    .appFont(.callout)
    .foregroundStyle(.secondary)
  }

  /// The currency the row shows a template's amount in: the one its chip enters it in
  /// (`Templates.currency(of:lineDefault:)`).
  static func amountCurrency(of template: Template, defaultCurrency: CurrencyCode) -> CurrencyCode {
    Templates.currency(of: template, lineDefault: defaultCurrency)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  private func reload() {
    templates = (try? environment.references?.templates(includeArchived: true)) ?? []
  }

  /// New words for a template, written alone. Words that say nothing are not written: the
  /// row shows what it had.
  private func rename(_ template: Template) {
    guard !template.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      reload()
      return
    }
    write("templates.save") { try $0.renameTemplate(template.id, to: template.text) }
  }

  /// Into the archive, or back with «Вернуть» — as it was, pin and count included. Only the
  /// flag is written: a text typed in the row and not submitted stays unsaved.
  private func setArchived(_ template: Template, _ archived: Bool) {
    write("templates.archive") { try $0.setTemplate(template.id, archived: archived) }
  }

  /// A template is not data about money: throwing one away loses nothing but the chip.
  private func delete(_ template: Template) {
    write("templates.delete") { try $0.deleteTemplate(id: template.id) }
  }

  /// One write of the templates; the chips are told. A refused one keeps the row as the owner
  /// left it, and the alert says so.
  private func write(_ name: String, _ body: (ReferenceRepository) throws -> Void) {
    guard environment.attempt(name, on: environment.references, body) else {
      refused = true
      return
    }
    NotificationCenter.default.post(name: .templatesChanged, object: nil)
    reload()
    environment.scheduleBackup()
  }
}
