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
  /// «Добавить шаблон…» pressed: the words of the new template, typed in the last row.
  @State private var adding: String?
  @FocusState private var addFieldFocused: Bool

  var body: some View {
    #if os(macOS)
      macLayout
    #else
      formLayout
    #endif
  }

  private var formLayout: some View {
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
          addRow
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

      Text(verbatim: environment.language("templates.hintAdded", table: EntryLinks.table))
        .appFont(.callout)
        .foregroundStyle(.secondary)
    }
    .padding()
    .modifier(TemplatesLifecycle(reload: reload, refused: $refused, environment: environment))
  }

  /// «Добавить шаблон…»: a template is made by hand too, not only by what is entered. The
  /// words are typed in the row and written with Return; a template made so is pinned, so its
  /// chip stands under the line at once.
  @ViewBuilder
  private var addRow: some View {
    if let text = adding {
      HStack(spacing: 10) {
        Image(systemName: "pin.fill")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField(
          text: Binding(get: { text }, set: { adding = $0 }),
          prompt: Text(
            verbatim: environment.language("templates.add.prompt", table: EntryLinks.table))
        ) { EmptyView() }
        .labelsHidden()
        .textFieldStyle(.plain)
        .focused($addFieldFocused)
        .onSubmit { add(text) }
        .onExitCommand { adding = nil }
        .accessibilityIdentifier("templates.add.field")
      }
    } else {
      Button {
        adding = ""
        addFieldFocused = true
      } label: {
        Text(verbatim: environment.language("templates.add", table: EntryLinks.table))
          .foregroundStyle(.tint)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("templates.add")
    }
  }

  private func add(_ text: String) {
    guard let template = TemplatesByHand.template(from: text) else {
      adding = nil
      return
    }
    adding = nil
    // Words a template already holds pin that one rather than make a second chip of them.
    if let same = templates.first(where: {
      $0.text.caseInsensitiveCompare(template.text) == .orderedSame
    }) {
      write("templates.add") { try $0.setTemplate(same.id, pinned: true) }
      return
    }
    write("templates.add") { try $0.save(template) }
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

/// A template added by hand with «Добавить шаблон…»: the words typed, an amount at their end
/// taken as its amount («кофе 250»), pinned, used never.
enum TemplatesByHand {
  static func template(from typed: String) -> Template? {
    let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return nil }
    var parts = words.split(separator: " ").map(String.init)
    var amount: AmountE4?
    if parts.count > 1, let last = parts.last,
      last.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }),
      let value = Decimal(string: last.replacingOccurrences(of: ",", with: "."), locale: nil),
      value > 0, let e4 = try? AmountE4(decimal: value)
    {
      amount = e4
      parts.removeLast()
    }
    return Template(text: parts.joined(separator: " "), amountE4: amount, pinned: true)
  }
}

/// What every layout of the templates does the same: read on appear and when the chips write,
/// and say it when the database refuses a write.
private struct TemplatesLifecycle: ViewModifier {
  let reload: () -> Void
  @Binding var refused: Bool
  let environment: AppEnvironment

  func body(content: Content) -> some View {
    content
      .onAppear(perform: reload)
      .onReceive(NotificationCenter.default.publisher(for: .templatesChanged)) { _ in reload() }
      .refusedWriteAlert($refused, environment)
  }
}

#if os(macOS)
  /// The Mac's «Шаблоны» in the design's measures (Figma 61:30417): a card of rows 16 × 11 — the
  /// words and the amount 13 medium over «закреплён · использован 14 раз» 11 — with the action
  /// at the right in the accent («Открепить», «Закрепить», «Вернуть»), a card with the switch
  /// «Показывать архив», and the line of what templates are, 12.
  extension TemplatesSettingsView {
    fileprivate var macLayout: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: SettingsControlMetrics.blockGap) {
          SettingsCard {
            ForEach($templates, id: \.id) { $template in
              if !template.archived { macLiveRow($template) }
            }
            if showsArchive {
              ForEach(templates.filter(\.archived), id: \.id) { template in
                macArchivedRow(template)
              }
            }
            macAddRow
          }
          SettingsCard {
            SettingsCardRow(
              title: t("templates.showArchive"), showsDivider: false, compact: true
            ) {
              Toggle(isOn: $showsArchive) { Text(verbatim: t("templates.showArchive")) }
                .labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier("templates.showArchive")
            }
          }
          Text(verbatim: environment.language("templates.hintAdded", table: EntryLinks.table))
            .appFont(AppFont.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsChromeMetrics.contentInset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .modifier(TemplatesLifecycle(reload: reload, refused: $refused, environment: environment))
    }

    /// «закреплён · использован 14 раз», or «в архиве» for a template put away.
    func subtitle(of template: Template) -> String {
      if template.archived { return t("templates.inArchive") }
      let used = environment.format(
        "templates.used", table: "Settings", counts: template.useCount)
      return template.pinned ? "\(t("templates.pinnedState")) · \(used)" : used
    }

    private func macRow<Action: View>(
      _ template: Template, words: some View, @ViewBuilder action: () -> Action
    ) -> some View {
      VStack(spacing: 0) {
        HStack(spacing: SettingsCardMetrics.rowGap) {
          VStack(alignment: .leading, spacing: SettingsCardMetrics.textGap) {
            words
            Text(verbatim: subtitle(of: template))
              .appFont(AppFont.system(size: 11))
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          action()
        }
        .padding(.horizontal, SettingsCardMetrics.rowHorizontal)
        .padding(.vertical, SettingsCardMetrics.compactVertical)
        Divider().opacity(0.6)
      }
    }

    private func amountText(_ template: Template) -> String? {
      guard let amount = template.amountE4 else { return nil }
      let currency = Self.amountCurrency(of: template, defaultCurrency: environment.defaultCurrency)
      return environment.money.exact(amount, currency: currency)
    }

    private func macLiveRow(_ template: Binding<Template>) -> some View {
      let value = template.wrappedValue
      let pinned = value.pinned
      return macRow(
        value,
        words: HStack(spacing: 4) {
          TextField(text: template.text) { EmptyView() }
            .labelsHidden()
            .textFieldStyle(.plain)
            .appFont(AppFont.system(size: 13, weight: .medium))
            .onSubmit { rename(template.wrappedValue) }
          if let amount = amountText(value) {
            Text(verbatim: amount)
              .appFont(AppFont.system(size: 13, weight: .medium).monospacedDigit())
          }
        }
      ) {
        HStack(spacing: 8) {
          macAction(t(Self.pinCaptionKey(pinned: pinned))) {
            write("templates.save") { try $0.setTemplate(value.id, pinned: !pinned) }
          }
          Menu {
            Button(t("templates.archive")) { setArchived(value, true) }
            Divider()
            Button(environment.language("action.delete"), role: .destructive) { delete(value) }
          } label: {
            Image(systemName: "ellipsis.circle")
              .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(value.text, environment)))
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
        }
      }
    }

    private func macArchivedRow(_ template: Template) -> some View {
      macRow(
        template,
        words: HStack(spacing: 4) {
          Text(verbatim: template.text)
            .appFont(AppFont.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if let amount = amountText(template) {
            Text(verbatim: amount)
              .appFont(AppFont.system(size: 13, weight: .medium).monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      ) {
        HStack(spacing: 8) {
          macAction(t("templates.restore")) { setArchived(template, false) }
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
    }

    private func macAction(_ title: String, _ perform: @escaping () -> Void) -> some View {
      Button(action: perform) {
        Text(verbatim: title)
          .appFont(AppFont.system(size: 13, weight: .medium))
          .foregroundStyle(Color.accentColor)
      }
      .buttonStyle(.plain)
    }

    private var macAddRow: some View {
      addRow
        .padding(.horizontal, SettingsCardMetrics.rowHorizontal)
        .padding(.vertical, SettingsCardMetrics.compactVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
#endif
