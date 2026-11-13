import AppCore
import AppDatabase
import SwiftUI

/// The starter set asked from Settings → «Основные»: a sheet of the settings window. Apart from
/// `StarterSetOffer`, which the main window reads for the sheet it asks on a new database.
@MainActor
@Observable
final class SettingsStarterSet {
  static let shared = SettingsStarterSet()
  var isUp = false

  /// «Выбрать стартовый набор…»: the set over the settings, the main window's offer untouched.
  func open() {
    isUp = true
  }
}

extension GeneralSettingsView {
  /// A number in the style, for its row: «1,234.56» or «1 234,56».
  static func numberStyleSample(_ style: NumberStyle) -> String {
    NumberText.amount(AmountE4(raw: 12_345_600), style: style)
  }
}

struct GeneralSettingsView: View {
  @Dependency(\.environment) private var environment
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false
  /// The people of the book, archived ones too, read when the tab appears and after each one
  /// is added.
  @State private var people: [Person] = []
  @State private var newPerson = ""
  /// One identity for the person being typed, so a hidden notice stays about this entry.
  @State private var newPersonId = UUID()
  #if !APPSTORE && os(macOS)
    /// Read once when the tab is made; the switch is the only thing that changes it.
    @State private var automaticUpdates = AutomaticUpdates().isOn
  #endif

  var body: some View {
    @Bindable var language = environment.language
    #if !os(macOS)
      @Bindable var theme = environment.theme
    #endif
    Form {
      #if os(macOS)
        languageGroup
        PrivacySettingsSection()
        #if !APPSTORE
          updatesGroup
        #endif
      #else
        Picker(selection: $language.choice) {
          ForEach(AppLanguage.Choice.allCases, id: \.self) { choice in
            Text(verbatim: environment.language(choice.settingsKey, table: "Settings"))
              .tag(choice)
          }
        } label: {
          Text(verbatim: environment.language("settings.language", table: "Settings"))
        }
        .pickerStyle(.inline)

        // «Запись чисел» (0563): how the interface writes a number; files stay as they are.
        Section {
          Picker(selection: $theme.numberStyle) {
            ForEach(NumberStyle.allCases, id: \.self) { style in
              Text(verbatim: Self.numberStyleSample(style)).tag(style)
            }
          } label: {
            Text(verbatim: environment.language("settings.numbers", table: "Settings"))
          }
          .accessibilityIdentifier("settings.numbers")
        } footer: {
          Text(verbatim: environment.language("settings.numbers.hint", table: "Settings"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }

      #endif

      // «Стартовый набор»: categories, limits and tiles for the way the owner lives; only adds.
      Section {
        Button(environment.language("settings.starter.open", table: "Settings")) {
          SettingsStarterSet.shared.open()
        }
        .accessibilityIdentifier("settings.starter.open")
      } header: {
        Text(verbatim: environment.language("settings.starter", table: "Settings"))
          .settingsHeaderStyle()
      } footer: {
        Text(verbatim: environment.language("settings.starter.hint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      #if !os(macOS)
        // The tips on the spot (`GuideTips`): on this Mac only, never in the data.
        Section {
          Toggle(
            isOn: Binding(get: { GuideStore.shared.tipsOff }, set: { GuideTips.setOff($0) })
          ) {
            Text(verbatim: environment.language("settings.tips.off", table: "Settings"))
          }
          .accessibilityIdentifier("settings.tips.off")
        }

      #endif

      // Hiding the amounts and the lock: switches of this Mac, never in the archive. The phone
      // has its own lock (Face ID), set up in «Ещё».
      Section {
        Toggle(
          isOn: Binding(
            get: { environment.assignsEventAutomatically },
            set: { if !environment.setAssignsEventAutomatically($0) { refused = true } })
        ) {
          Text(verbatim: environment.language("settings.events.automatic", table: "Settings"))
        }
      } footer: {
        Text(verbatim: environment.language("settings.events.automaticHint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      // The folder the journal of the exchange with the other devices lives in; the demo and
      // generated sets have no exchange, so no row.
      if let sync = environment.sync {
        SyncFolderSettingsView(coordinator: sync)
      }

      Section {
        ForEach(ForWhom.allCases, id: \.self) { value in
          LabeledContent {
            TextField(
              text: Binding(
                get: { environment.label(for: value) },
                set: { if !environment.setLabel($0, for: value) { refused = true } })
            ) {
              EmptyView()
            }
            .labelsHidden()
          } label: {
            Text(verbatim: environment.language("forWhom.\(value.rawValue)"))
          }
        }
      } header: {
        Text(verbatim: environment.language("settings.forWhomLabels", table: "Settings"))
          .settingsHeaderStyle()
      } footer: {
        Text(verbatim: environment.language("settings.forWhom.fixedHint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      // The five values above are fixed and can only be renamed. What
      // «для кого» can really be extended with is a person — the other half of the same
      // dimension, and a free list — and until 21.09 nothing on this screen said so or
      // offered to add one.
      Section {
        ForEach(people.filter { !$0.archived }, id: \.id) { person in
          Text(verbatim: person.name)
        }
        HStack {
          TextField(text: $newPerson) {
            // A person has a name, not a «Название»: the shared key of the reference books
            // reads wrong under a section headed «Люди».
            Text(verbatim: environment.language("settings.forWhom.personName", table: "Settings"))
          }
          .onSubmit(addPerson)
          .accessibilityIdentifier("settings.forWhom.newPerson")
          Button(environment.language("references.add", table: "Settings"), action: addPerson)
            .disabled(!canAddPerson)
        }
        PlanningNamesakeNotice(
          kind: .person, id: newPersonId, name: $newPerson, onChange: reloadPeople,
          dismissesOnRestore: false)
      } header: {
        Text(verbatim: environment.language("settings.forWhom.people", table: "Settings"))
          .settingsHeaderStyle()
      } footer: {
        Text(verbatim: environment.language("settings.forWhom.peopleHint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      // «Собрать отчёт о проблеме…» — it is here as well as in the
      // menu.
      ProblemReportView()

      #if os(macOS)
        if language.needsRestart {
          LabeledContent {
            Button(environment.language("settings.language.restart", table: "Settings")) {
              AppRestart.relaunch()
            }
          } label: {
            Text(verbatim: environment.language("settings.language.restartHint", table: "Settings"))
              .appFont(.callout)
              .foregroundStyle(.secondary)
          }
        }
      #endif
    }
    .formStyle(.grouped)
    .padding()
    .onAppear(perform: reloadPeople)
    .refusedWriteAlert($refused, environment)
  }

  #if os(macOS)
    /// «Язык и подсказки» of the design (Figma 52:585): language, number format, theme, tips —
    /// rows of a card with the value and a chevron at the right, or a switch.
    @ViewBuilder
    private var languageGroup: some View {
      @Bindable var language = environment.language
      @Bindable var theme = environment.theme
      SettingsCardGroup(title: g("settings.general.group.language")) {
        SettingsCardRow(
          symbol: "globe", title: environment.language("settings.language", table: "Settings")
        ) {
          SettingsValueMenu(
            value: environment.language(language.choice.settingsKey, table: "Settings")
          ) {
            Picker("", selection: $language.choice) {
              ForEach(AppLanguage.Choice.allCases, id: \.self) { choice in
                Text(verbatim: environment.language(choice.settingsKey, table: "Settings"))
                  .tag(choice)
              }
            }
            .pickerStyle(.inline).labelsHidden()
          }
          .accessibilityIdentifier("settings.language")
        }
        SettingsCardRow(
          symbol: "textformat.123",
          title: environment.language("settings.numbers", table: "Settings")
        ) {
          SettingsValueMenu(value: Self.numberStyleSample(theme.numberStyle)) {
            Picker("", selection: $theme.numberStyle) {
              ForEach(NumberStyle.allCases, id: \.self) { style in
                Text(verbatim: Self.numberStyleSample(style)).tag(style)
              }
            }
            .pickerStyle(.inline).labelsHidden()
          }
          .accessibilityIdentifier("settings.numbers")
        }
        SettingsCardRow(
          symbol: "moon",
          title: environment.language("settings.appearance.scheme", table: "Settings")
        ) {
          SettingsValueMenu(value: AppearanceSettingsView.schemeTitle(theme.scheme, environment)) {
            Picker("", selection: $theme.scheme) {
              ForEach(AppearanceSettingsView.schemeOrder, id: \.self) { scheme in
                Text(verbatim: AppearanceSettingsView.schemeTitle(scheme, environment))
                  .tag(scheme)
              }
            }
            .pickerStyle(.inline).labelsHidden()
          }
          .accessibilityIdentifier("settings.general.scheme")
        }
        SettingsCardRow(
          symbol: "lightbulb", title: g("settings.general.tips"),
          hint: g("settings.general.tipsHint"), showsDivider: false, verticalPadding: 11
        ) {
          Toggle(
            isOn: Binding(get: { !GuideStore.shared.tipsOff }, set: { GuideTips.setOff(!$0) })
          ) { Text(verbatim: g("settings.general.tips")) }
          .labelsHidden().toggleStyle(.switch)
          .accessibilityIdentifier("settings.tips.off")
        }
      }
    }

    private func g(_ key: String) -> String { environment.language(key, table: "SettingsGeneral") }
  #endif

  #if !APPSTORE && os(macOS)
    /// «Обновления» of the design (Figma 52:675): one row with a switch; a build that cannot
    /// verify an update keeps the switch in view, greyed, and says why under the card.
    private var updatesGroup: some View {
      SettingsCardGroup(
        title: g("settings.general.group.updates"),
        footer: AutomaticUpdates.isChangeable
          ? nil : environment.language("settings.updates.unavailableHint", table: "Settings")
      ) {
        SettingsCardRow(
          symbol: "arrow.clockwise", title: g("settings.general.updates"),
          hint: g("settings.general.updatesHint"), showsDivider: false, verticalPadding: 11
        ) {
          Toggle(
            isOn: Binding(
              get: { automaticUpdates },
              set: { isOn in
                AutomaticUpdates().isOn = isOn
                automaticUpdates = isOn
              })
          ) { Text(verbatim: g("settings.general.updates")) }
          .labelsHidden().toggleStyle(.switch)
          .disabled(!AutomaticUpdates.isChangeable)
          .accessibilityIdentifier("settings.updates.automatic")
        }
      }
    }
  #endif

  private func reloadPeople() {
    people = (try? environment.references?.people(includeArchived: true)) ?? []
  }

  /// A name that says something can always be added; a namesake only gets advice under the
  /// field (`PlanningNamesakeNotice`).
  private var canAddPerson: Bool {
    Self.person(toAdd: newPerson, among: people) != nil
  }

  /// The row «Добавить» writes for `name`: always a new person, nil for a name that says
  /// nothing. A person of the same name — live or in the archive — is left alone: the notice
  /// offers to rename either one or to bring the archived one back.
  static func person(toAdd name: String, among people: [Person]) -> Person? {
    let name = name.trimmingCharacters(in: .whitespaces)
    guard !ReferenceNames.folded(name).isEmpty else { return nil }
    return Person(name: name)
  }

  /// A new person, never a silent return of the archived one of the same name.
  private func addPerson() {
    guard canAddPerson else { return }
    let today = environment.today
    guard
      environment.attempt(
        "references.add", on: environment.references,
        { _ = try NewReference.add(newPerson, to: .people, from: today, to: today, references: $0) }
      )
    else {
      refused = true
      return
    }
    newPerson = ""
    reloadPeople()
    environment.refreshVocabulary()
    environment.scheduleBackup()
  }
}
