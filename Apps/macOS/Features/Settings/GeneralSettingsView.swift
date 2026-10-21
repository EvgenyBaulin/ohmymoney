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

struct GeneralSettingsView: View {
  @Dependency(\.environment) private var environment
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false
  /// The people of the book, archived ones too, read when the tab appears and after each one
  /// is added.
  @State private var people: [Person] = []
  @State private var newPerson = ""
  #if !APPSTORE && os(macOS)
    /// Read once when the tab is made; the switch is the only thing that changes it.
    @State private var automaticUpdates = AutomaticUpdates().isOn
  #endif

  var body: some View {
    @Bindable var language = environment.language
    Form {
      Picker(selection: $language.choice) {
        ForEach(AppLanguage.Choice.allCases, id: \.self) { choice in
          Text(verbatim: environment.language(choice.settingsKey, table: "Settings"))
            .tag(choice)
        }
      } label: {
        Text(verbatim: environment.language("settings.language", table: "Settings"))
      }
      .pickerStyle(.inline)

      // «Стартовый набор»: categories, limits and tiles for the way the owner lives; only adds.
      Section {
        Button(environment.language("settings.starter.open", table: "Settings")) {
          SettingsStarterSet.shared.open()
        }
        .accessibilityIdentifier("settings.starter.open")
      } header: {
        Text(verbatim: environment.language("settings.starter", table: "Settings"))
      } footer: {
        Text(verbatim: environment.language("settings.starter.hint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      // The tips on the spot (`GuideTips`): on this Mac only, never in the data.
      Section {
        Toggle(
          isOn: Binding(get: { GuideStore.shared.tipsOff }, set: { GuideTips.setOff($0) })
        ) {
          Text(verbatim: environment.language("settings.tips.off", table: "Settings"))
        }
        .accessibilityIdentifier("settings.tips.off")
      }

      // Hiding the amounts and the lock: switches of this Mac, never in the archive. The phone
      // has its own lock (Face ID), set up in «Ещё».
      #if os(macOS)
        PrivacySettingsSection()
      #endif

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
        if !ReferenceNames.folded(newPerson).isEmpty, !canAddPerson {
          Text(verbatim: environment.language("references.nameTaken", table: "Settings"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text(verbatim: environment.language("settings.forWhom.people", table: "Settings"))
      } footer: {
        Text(verbatim: environment.language("settings.forWhom.peopleHint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      #if !APPSTORE && os(macOS)
        updatesSection
      #endif

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

  #if !APPSTORE && os(macOS)
    /// «Обновления: автоматические вкл/выкл (по умолчанию вкл)». A build
    /// that cannot verify an update keeps the switch in view, greyed, and says why.
    private var updatesSection: some View {
      Section {
        Toggle(
          isOn: Binding(
            get: { automaticUpdates },
            set: { isOn in
              AutomaticUpdates().isOn = isOn
              automaticUpdates = isOn
            })
        ) {
          Text(verbatim: environment.language("settings.updates.automatic", table: "Settings"))
        }
        .disabled(!AutomaticUpdates.isChangeable)
      } header: {
        Text(verbatim: environment.language("settings.updates", table: "Settings"))
      } footer: {
        Text(
          verbatim: environment.language(
            AutomaticUpdates.isChangeable
              ? "settings.updates.automaticHint" : "settings.updates.unavailableHint",
            table: "Settings")
        )
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }
    }
  #endif

  private func reloadPeople() {
    people = (try? environment.references?.people(includeArchived: true)) ?? []
  }

  /// A name already in the book — a name or an alias, by the rule the reference books use —
  /// adds nothing, and a button that stays live while nothing happens is worse than one that
  /// explains itself by being grey.
  private var canAddPerson: Bool {
    Self.person(toAdd: newPerson, among: people) != nil
  }

  /// The row «Добавить» brings for `name`, or nil when it adds nothing: an empty name, or one
  /// a live person already answers to, as a name or an other name, by the rule the reference
  /// books use (`ReferenceNames`: case, «ё»/«е» and the spaces around do not count) — two
  /// people with one name are two rows the entry line cannot tell apart. A name the archive
  /// has — his name first, else one of his other names — brings that person back with the
  /// relation and the other names he had, as `ReferenceRepository.revive` does on the write.
  static func person(toAdd name: String, among people: [Person]) -> Person? {
    let name = name.trimmingCharacters(in: .whitespaces)
    let live = people.filter { !$0.archived }
    guard ReferenceBooksView.canAdd(name, to: .people, people: live, places: []) else {
      return nil
    }
    let wanted = ReferenceNames.folded(name)
    let archived = people.filter(\.archived)
    guard
      var back = archived.first(where: { ReferenceNames.folded($0.name) == wanted })
        ?? archived.first(where: { $0.aliases.contains { ReferenceNames.folded($0) == wanted } })
    else { return Person(name: name) }
    back.archived = false
    return back
  }

  /// A new person, or the one the archive holds under this name or an other name of his —
  /// with the relation and the other names he had — by the rule of the reference books
  /// (`NewReference.add`), rather than a second row with the same name.
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
