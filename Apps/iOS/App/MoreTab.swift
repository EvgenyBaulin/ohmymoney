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
  /// The sections the bar carries: «Ещё» lists the rest.
  var layout: NavLayout = NavLayout.make(width: 0, isPad: false)
  /// The four sections of the phone bar, edited here.
  @Binding var phoneTabs: [NavItem]

  @State private var picking = false
  @State private var failure: String?
  @State private var query = ""
  @State private var editsTabs = false

  private var environment: AppEnvironment { deps.environment }
  private func t(_ key: String) -> String { environment.language(key, table: "Phone") }
  private func n(_ key: String) -> String { environment.language(key, table: "Navigation") }

  @State private var starterSet = SettingsStarterSet.shared

  private var isSearching: Bool {
    !query.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    @Bindable var router = router
    NavigationStack(path: $router.morePath) {
      Form {
        let rows = visibleRows
        if rows.sections.isEmpty && rows.app.isEmpty && isSearching {
          Text(verbatim: n("nav.more.noResults")).foregroundStyle(.secondary)
        }
        if !rows.sections.isEmpty {
          Section { ForEach(rows.sections) { row in rowView(row) } }
        }
        if !rows.app.isEmpty {
          Section { ForEach(rows.app) { row in rowView(row) } }
        }
        if !isSearching {
          Section {
            Button {
              environment.receiptRequest = ReceiptRequest(urls: [])
            } label: {
              Label(
                environment.language("receipt.menu", table: "Receipt"),
                systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("more.receipt")
          }
          dataSection
          // A real profile with no records of its own can take the data another device left in
          // the exchange folder.
          if session.profile == .real, let sync = environment.sync {
            SyncBootstrapSection(coordinator: sync)
          }
          folderSection
          privacySection
        }
      }
      .searchable(text: $query, prompt: Text(verbatim: n("nav.more.search")))
      .navigationTitle(t("phone.tab.more"))
      .navigationBarTitleDisplayMode(.inline)
      .phoneToolbar(deps: deps, router: router)
      .toolbar {
        if layout.placement == .bottom {
          ToolbarItem(placement: .topBarLeading) {
            Button(n("nav.more.edit")) { editsTabs = true }
          }
        }
      }
      .sheet(isPresented: $editsTabs) {
        PhoneTabsEditor(deps: deps, tabs: $phoneTabs)
      }
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
    case .analytics:
      sectionScreen(titleKey: "window.analytics") { AnalyticsWindow(deps: deps) }
    case .reports:
      sectionScreen(titleKey: "window.reports") { ReportsWindow(deps: deps) }
    case .purchases:
      sectionScreen(titleKey: "section.purchases") { PurchasesScreen() }
    case .whatIf:
      sectionScreen(titleKey: "window.whatIf") { WhatIfWindow(deps: deps) }
    case .settings:
      PhoneSettingsList(deps: deps)
    case .conflicts:
      if let sync = environment.sync {
        ConflictsList(coordinator: sync)
      } else {
        EmptyView()
      }
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

  private var menu: MoreMenu {
    MoreMenu.make(
      more: layout.more, tripIsOn: environment.tripEntryDefaults != nil,
      hasConflicts: !(environment.sync?.conflicts.isEmpty ?? true)
    )
    .filtered(by: query, title: title(of:))
  }

  private var visibleRows: MoreMenu { menu }

  private func title(of row: MoreRow) -> String {
    switch row {
    case .section(let item):
      environment.language(item.titleKey, table: item.titleTable ?? "Common")
    case .purchases: environment.language("section.purchases")
    case .whatIf: environment.language("window.whatIf")
    case .trip: n("nav.more.trip")
    case .reconcile: environment.language("action.reconcile")
    case .settings: environment.language("settings.title", table: "Settings")
    case .conflicts: environment.language("sync.conflicts.title", table: "Sync")
    case .tour: environment.language("guide.menu.tour", table: "Guide")
    case .whatsNew: environment.language("guide.menu.whatsNew", table: "Guide")
    case .problemReport: environment.language("report.title", table: "Settings")
    }
  }

  @ViewBuilder
  private func rowView(_ row: MoreRow) -> some View {
    let label = Label {
      Text(verbatim: title(of: row))
    } icon: {
      Image(systemName: row.symbol)
    }
    switch row {
    case .section(let item):
      if let destination = item.moreDestination {
        NavigationLink(value: destination) { label }
      } else {
        Button {
          router.open(nav: item)
        } label: {
          label
        }
      }
    case .settings:
      NavigationLink(value: MoreDestination.settings) { label }
    case .conflicts:
      NavigationLink(value: MoreDestination.conflicts) { label }
    case .purchases:
      NavigationLink(value: MoreDestination.purchases) { label }
    case .whatIf:
      NavigationLink(value: MoreDestination.whatIf) { label }
    case .trip:
      Button {
        environment.showsTrip = true
      } label: {
        label
      }
    case .reconcile:
      Button {
        environment.showsReconciliation = true
      } label: {
        label
      }
    case .tour:
      Button {
        GuideStore.shared.show(GuideCatalog.firstLaunch)
      } label: {
        label
      }
    case .whatsNew:
      Button {
        if let latest = GuideCatalog.whatsNew.last { GuideStore.shared.show(latest) }
      } label: {
        label
      }
    case .problemReport:
      Button {
        environment.showsProblemReport = true
      } label: {
        label
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
    case .rules: RulesSettingsView()
    case .attachments: AttachmentsSettingsView()
    case .purchases: PurchasesSettingsView()
    case .backups: BackupSettingsView()
    }
  }
}

/// «Ещё → Изменить»: which four sections the bar of the phone carries, and in what order. The
/// chosen ones come first and move; the rest are added one by one. Only four are kept.
struct PhoneTabsEditor: View {
  let deps: AppDependencies
  @Binding var tabs: [NavItem]

  @State private var draft: [NavItem] = []
  @Environment(\.dismiss) private var dismiss

  private var environment: AppEnvironment { deps.environment }
  private func n(_ key: String) -> String { environment.language(key, table: "Navigation") }
  private func title(_ item: NavItem) -> String {
    environment.language(item.titleKey, table: item.titleTable ?? "Common")
  }

  private var rest: [NavItem] { NavItem.allCases.filter { !draft.contains($0) } }
  private var isFull: Bool { draft.count == NavLayout.phoneSlots }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(draft) { item in
            HStack {
              Label {
                Text(verbatim: title(item))
              } icon: {
                Image(systemName: item.symbol)
              }
              Spacer()
              Button {
                draft.removeAll { $0 == item }
              } label: {
                Image(systemName: "minus.circle")
              }
              .accessibilityLabel(Text(verbatim: n("nav.edit.remove")))
            }
          }
          .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
        } header: {
          Text(
            verbatim: environment.format(
              "nav.edit.chosen", table: "Navigation", draft.count, NavLayout.phoneSlots))
        } footer: {
          Text(verbatim: n("nav.edit.footer"))
        }
        Section {
          ForEach(rest) { item in
            Button {
              if !isFull { draft.append(item) }
            } label: {
              Label {
                Text(verbatim: title(item))
              } icon: {
                Image(systemName: item.symbol)
              }
            }
            .disabled(isFull)
          }
        }
      }
      .environment(\.editMode, .constant(.active))
      .navigationTitle(n("nav.edit.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(environment.language("action.cancel")) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(n("nav.edit.done")) {
            if PhoneTabsPreference.validated(draft) != nil { tabs = draft }
            dismiss()
          }
          .disabled(!isFull)
        }
      }
    }
    .onAppear { draft = tabs }
  }
}
