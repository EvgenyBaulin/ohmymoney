import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// How the folder for copies stands, said in one word each — what the settings print and what
/// a test reads.
enum FolderStatus: Equatable {
  /// The demo writes nothing outside its own folder, so there is nothing to choose.
  case demoWritesNothing
  case notChosen
  /// Chosen, and the bookmark opens: the copies go there.
  case ready(name: String)
  /// Chosen once, but the bookmark no longer opens (renamed, moved, gone): choose it again.
  case lost

  static func of(
    profile: DataProfile, isStored: Bool, mirror: URL?, unavailable: Bool
  ) -> FolderStatus {
    guard profile == .real else { return .demoWritesNothing }
    if let mirror { return .ready(name: mirror.lastPathComponent) }
    if unavailable { return .lost }
    return isStored ? .lost : .notChosen
  }
}

/// «Ещё»: the sections that did not fit into a tab (Debts, Calendar, Capital), the tools the
/// Mac keeps in its toolbar (reconciliation, trip, Analytics, Reports), the guide, the set of
/// data, the folder for copies, privacy, and the settings of the shared screens.
struct MoreTab: View {
  let deps: AppDependencies
  let session: AppSession
  let lock: AppLock
  let router: PhoneRouter
  let actions: OperationActions

  @State private var picking = false
  @State private var failure: String?

  private var environment: AppEnvironment { deps.environment }
  private func t(_ key: String) -> String { environment.language(key, table: "Phone") }

  @State private var starterSet = SettingsStarterSet.shared

  var body: some View {
    @Bindable var router = router
    NavigationStack(path: $router.morePath) {
      Form {
        sectionsSection
        toolsSection
        guideSection
        dataSection
        folderSection
        privacySection
        Section {
          NavigationLink(value: MoreDestination.settings) {
            Label {
              Text(verbatim: environment.language("settings.title", table: "Settings"))
            } icon: {
              Image(systemName: "gearshape")
            }
          }
        }
      }
      .navigationTitle(t("phone.tab.more"))
      .navigationBarTitleDisplayMode(.inline)
      .phoneToolbar(deps: deps, router: router)
      .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
        take(result)
      }
      .navigationDestination(for: MoreDestination.self) { destination in
        screen(destination)
          .appDependencies(deps)
      }
    }
    // «Выбрать стартовый набор…» of «Основные»: the set, on a sheet over the settings.
    .sheet(
      isPresented: deps.environment.lock.presenting(
        Binding(get: { starterSet.isUp }, set: { if !$0 { starterSet.isUp = false } }))
    ) {
      StarterSetSheet().appDependencies(deps)
    }
  }

  /// What each destination shows. The sections of the Mac sidebar keep their entry bar below.
  @ViewBuilder
  private func screen(_ destination: MoreDestination) -> some View {
    switch destination {
    case .debts:
      sectionScreen(titleKey: "section.debts") { DebtsView() }
    case .calendar:
      sectionScreen(titleKey: "section.calendar") { CalendarView(actions: actions) }
    case .capital:
      sectionScreen(titleKey: "section.capital") {
        CapitalView { router.open(item: .account($0)) }
      }
    case .settings:
      PhoneSettingsList(deps: deps)
    }
  }

  private func sectionScreen<Content: View>(
    titleKey: String, @ViewBuilder content: () -> Content
  ) -> some View {
    PhoneContent(deps: deps, actions: actions, content: content) { EmptyView() }
      .navigationTitle(environment.language(titleKey))
      .navigationBarTitleDisplayMode(.inline)
  }

  // MARK: Sections and tools

  private var sectionsSection: some View {
    Section {
      destinationLink(.debts, titleKey: "section.debts", symbol: "creditcard")
      destinationLink(.calendar, titleKey: "section.calendar", symbol: "calendar.circle")
      destinationLink(.capital, titleKey: "section.capital", symbol: "building.columns")
    }
  }

  private func destinationLink(
    _ destination: MoreDestination, titleKey: String, symbol: String
  ) -> some View {
    NavigationLink(value: destination) {
      Label {
        Text(verbatim: environment.language(titleKey))
      } icon: {
        Image(systemName: symbol)
      }
    }
  }

  private var toolsSection: some View {
    Section {
      toolButton("window.analytics", symbol: "chart.xyaxis.line") {
        router.open(screen: .analytics)
      }
      toolButton("window.reports", symbol: "tablecells") { router.open(screen: .reports) }
      toolButton("action.reconcile", symbol: "checkmark.seal") {
        environment.showsReconciliation = true
      }
      Button {
        environment.showsTrip = true
      } label: {
        Label {
          Text(verbatim: TravelText.t("travel.start.button", environment))
        } icon: {
          Image(systemName: "airplane")
        }
      }
    }
  }

  private func toolButton(
    _ titleKey: String, symbol: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label {
        Text(verbatim: environment.language(titleKey))
      } icon: {
        Image(systemName: symbol)
      }
    }
  }

  /// The tour and «Что нового», the cards of the guide, and the report of a problem. The
  /// tutorial set and the spotlight of the Mac sidebar are not on the phone.
  private var guideSection: some View {
    Section {
      Button(environment.language("guide.menu.tour", table: "Guide")) {
        GuideStore.shared.show(GuideCatalog.firstLaunch)
      }
      Button(environment.language("guide.menu.whatsNew", table: "Guide")) {
        if let latest = GuideCatalog.whatsNew.last { GuideStore.shared.show(latest) }
      }
      Button(environment.language("report.title", table: "Settings")) {
        environment.showsProblemReport = true
      }
    }
  }

  // MARK: Data set

  private var dataSection: some View {
    Section {
      Picker(
        selection: Binding(
          get: { session.profile },
          set: { next in
            // The real books are asked for once: the demo is what the app opens on.
            Task { await session.switchProfile(to: next) }
          })
      ) {
        Text(verbatim: t("phone.data.demo")).tag(DataProfile.demo)
        Text(verbatim: t("phone.data.real")).tag(DataProfile.real)
      } label: {
        Text(verbatim: t("phone.data.title"))
      }
      .pickerStyle(.segmented)
      .disabled(session.isSwitching)
    } header: {
      Text(verbatim: t("phone.data.title"))
    } footer: {
      Text(verbatim: t(session.profile == .demo ? "phone.data.demoNote" : "phone.data.realNote"))
    }
  }

  // MARK: Folder

  private var status: FolderStatus {
    FolderStatus.of(
      profile: session.profile, isStored: environment.backupFolder.isStored,
      mirror: environment.mirrorFolder, unavailable: environment.mirrorFolderUnavailable)
  }

  private var folderSection: some View {
    Section {
      switch status {
      case .demoWritesNothing:
        Text(verbatim: t("phone.folder.demo")).foregroundStyle(.secondary)
      case .notChosen:
        Text(verbatim: t("phone.folder.none")).foregroundStyle(.secondary)
        Button(t("phone.folder.choose")) { picking = true }
      case .ready(let name):
        Label {
          Text(verbatim: name)
        } icon: {
          Image(systemName: "folder")
        }
        Button(t("phone.folder.change")) { picking = true }
      case .lost:
        Label {
          Text(verbatim: t("phone.folder.lost"))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        Button(t("phone.folder.chooseAgain")) { picking = true }
      }
      if let failure {
        Text(verbatim: environment.language(failure, table: "Settings"))
          .foregroundStyle(.secondary)
      }
    } header: {
      Text(verbatim: t("phone.folder.title"))
    } footer: {
      Text(verbatim: t("phone.folder.footer"))
    }
  }

  /// The folder the owner picked: access is opened for it first (without it the bookmark
  /// cannot be made) and kept open while the copies go there — the environment gives it back
  /// when it closes. Only a refusal gives it back at once.
  private func take(_ result: Result<URL, any Error>) {
    guard session.profile == .real, case .success(let url) = result else { return }
    guard url.startAccessingSecurityScopedResource() else {
      failure = BackupSettingsView.folderNotRememberedKey
      return
    }
    failure = BackupSettingsView.choose(url, in: environment)
    if failure != nil { url.stopAccessingSecurityScopedResource() }
  }

  // MARK: Privacy

  private var privacySection: some View {
    Section {
      Toggle(
        isOn: Binding(
          get: { environment.amounts.hidesAmounts },
          set: { environment.amounts.hidesAmounts = $0 })
      ) {
        Text(verbatim: environment.language("settings.privacy.hideAmounts", table: "Settings"))
      }
      Toggle(
        isOn: Binding(
          get: { lock.isEnabled },
          set: { on in
            if on {
              Task { await lock.enable(reason: t("phone.lock.reason")) }
            } else {
              lock.disable()
            }
          })
      ) {
        Text(verbatim: t("phone.lock.enable"))
      }
      if lock.isEnabled {
        Picker(
          selection: Binding(get: { lock.minutes }, set: { lock.minutes = $0 })
        ) {
          ForEach(AppLock.minuteChoices, id: \.self) { minutes in
            Text(
              verbatim: environment.format("phone.lock.minutes", table: "Phone", counts: minutes)
            )
            .tag(minutes)
          }
        } label: {
          Text(verbatim: t("phone.lock.after"))
        }
      }
      if let refusal = lock.lastRefusal, let key = LockScreen.refusalKey(refusal) {
        Text(verbatim: t(key)).foregroundStyle(.secondary)
      }
    } header: {
      Text(verbatim: environment.language("settings.privacy", table: "Settings"))
    }
  }
}

/// The ten sections of the Mac settings, one row each: the shared forms, pushed.
struct PhoneSettingsList: View {
  let deps: AppDependencies

  private var environment: AppEnvironment { deps.environment }

  var body: some View {
    Form {
      ForEach(SettingsSection.allCases, id: \.self) { section in
        NavigationLink {
          content(of: section)
            .navigationTitle(environment.language(section.titleKey, table: "Settings"))
            .appDependencies(deps)
        } label: {
          Label {
            Text(verbatim: environment.language(section.titleKey, table: "Settings"))
          } icon: {
            Image(systemName: section.symbol)
          }
        }
      }
    }
    .navigationTitle(environment.language("settings.title", table: "Settings"))
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private func content(of section: SettingsSection) -> some View {
    switch section {
    case .general: GeneralSettingsView()
    case .appearance: AppearanceSettingsView()
    case .currencies: CurrenciesSettingsView()
    case .accounts: AccountsSettingsView()
    case .categories: CategoriesSettingsView()
    case .references: ReferenceBooksView()
    case .entry: EntrySettingsView()
    case .templates: TemplatesSettingsView()
    case .planning: PlanningSettingsView()
    case .backups: BackupSettingsView()
    }
  }
}
