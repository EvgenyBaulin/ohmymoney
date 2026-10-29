import AppCore
import AppDatabase
import AppKit
import SwiftUI

/// ⌘, — the settings, as System Settings shows its own: the sections in a sidebar with their
/// symbols and a search field above them, the section chosen on the right in a grouped form.
///
/// The search finds a section by its name or by the caption of a setting it holds, in either
/// language (`SettingsSearch`); under a section found by a setting the captions that matched
/// are listed, and a click on one opens the section. Return opens the first section found.
///
/// Whatever the settings open — an editor, the rules of cashback, the password of the lock, the
/// starter set — is a sheet on this very window, never something behind it in the main one.
struct SettingsView: View {
  let deps: AppDependencies

  init(deps: AppDependencies) {
    self.deps = deps
  }

  private var environment: AppEnvironment { deps.environment }
  @State private var navigation = SettingsNavigation.shared
  /// «Выбрать стартовый набор…» of «Основные»: the set, on a sheet over the settings.
  @State private var starterSet = SettingsStarterSet.shared
  @Environment(\.themeSurfaces) private var surfaces

  /// The smallest the window may be made: the sidebar and a section beside it whose grouped
  /// form still holds a row of the accent circles and a category per row with its quality.
  static let minimumSize = CGSize(width: 850, height: 460)
  /// The size it opens at.
  static let idealSize = CGSize(width: 910, height: 620)
  /// The sidebar of the sections: the longest name, «Справочники», «Планирование», with its
  /// symbol, in either language.
  static let sidebarWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (180, 200, 260)

  var body: some View {
    // A sidebar and a section side by side, not a `NavigationSplitView`: that one can fold its
    // sidebar away — leaving a window with a toggle in the corner and nothing in it — and the
    // settings have no use for it. The sections are always on the left.
    HStack(spacing: 0) {
      SettingsSidebar(navigation: navigation, environment: environment)
        .frame(
          minWidth: Self.sidebarWidth.min, idealWidth: Self.sidebarWidth.ideal,
          maxWidth: Self.sidebarWidth.max
        )
        .layoutPriority(1)
      Divider()
      VStack(spacing: 0) {
        SettingsSectionTitle(
          section: navigation.section,
          title: environment.language(navigation.section.titleKey, table: "Settings"))
        SettingsSectionContent(section: navigation.section)
          .scrollContentBackground(.hidden)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(surfaces.background)
    }
    .navigationTitle(environment.language(navigation.section.titleKey, table: "Settings"))
    // Room for what the sections hold — the row of accent circles, a category per row with its
    // quality — and a window that can be made larger still: a list of categories read through
    // a slot of 420 points is a list nobody reads.
    .frame(
      minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width, maxWidth: .infinity,
      minHeight: Self.minimumSize.height, idealHeight: Self.idealSize.height,
      maxHeight: .infinity
    )
    .background(ResizableSettingsWindow(minimum: Self.minimumSize))
    // So a UI test can say the settings really opened when the gear of the toolbar is pressed.
    .accessibilityIdentifier("settings.window")
    // «Справка» → «Собрать отчёт о проблеме…»: the report itself, not a section to look for it
    // in. A sheet is laid out by a host of its own: the dependencies are handed over.
    .sheet(
      isPresented: Binding(
        get: { environment.showsProblemReport },
        set: { environment.showsProblemReport = $0 })
    ) {
      ProblemReportSheet(height: 380).appDependencies(deps)
    }
    // The starter set asked from «Основные» comes over the settings, where it was asked: the
    // main window's sheet stood behind this window, out of sight.
    .sheet(
      isPresented: environment.lock.presenting(
        Binding(get: { starterSet.isUp }, set: { if !$0 { starterSet.isUp = false } }))
    ) {
      StarterSetSheet().appDependencies(deps)
    }
  }
}

/// What a section shows: the views of the ten tabs the settings had, each as it was.
struct SettingsSectionContent: View {
  let section: SettingsSection

  var body: some View {
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
    case .backups: BackupSettingsView()
    }
  }
}

/// The sections, and the search field above them. While a query is typed only the sections it
/// finds stay, each with the captions of the settings that matched.
struct SettingsSidebar: View {
  @Bindable var navigation: SettingsNavigation
  let environment: AppEnvironment
  /// The words of both languages, read once for the sidebar.
  @State private var words = SettingsSearch.catalogWords()
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    let found = SettingsSearch.find(navigation.query, words: words)
    List(
      selection: Binding(
        get: { navigation.section },
        set: { if let section = $0 { navigation.section = section } })
    ) {
      ForEach(found, id: \.section) { found in
        SettingsSidebarLabel(
          section: found.section,
          title: environment.language(found.section.titleKey, table: "Settings"),
          isSelected: navigation.section == found.section
        )
        .tag(found.section)
        .listRowBackground(
          navigation.section == found.section
            ? RoundedRectangle(cornerRadius: SettingsChromeMetrics.plateRadius)
              .fill(Color(theme.palette.accentTint)).padding(.horizontal, 4)
            : nil
        )
        .accessibilityIdentifier("settings.section.\(found.section.rawValue)")
        ForEach(found.captions, id: \.self) { caption in
          Button {
            navigation.section = found.section
          } label: {
            Text(verbatim: environment.language(caption.key, table: caption.table))
              .appFont(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .padding(.leading, 26)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("settings.found.\(caption.key)")
        }
      }
      if found.isEmpty {
        Text(verbatim: environment.language("settings.search.nothing", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(surfaces.sidebar)
    .searchable(
      text: $navigation.query, placement: .toolbar,
      prompt: Text(verbatim: environment.language("settings.search.prompt", table: "Settings"))
    )
    .onSubmit(of: .search) {
      if let first = found.first { navigation.section = first.section }
    }
    .accessibilityIdentifier("settings.sidebar")
  }
}

/// The corner of the settings window, to drag it larger. The Settings scene gives its window no
/// resizable frame, whatever `windowResizability` says — the window keeps the size of the tab
/// it opened on — so the window is reached from a view inside it and given one, with the
/// smallest size the tabs are laid out for. Nothing is measured and nothing is fed back into
/// the layout: the frame of the tabs follows the window, as in any other window.
private struct ResizableSettingsWindow: NSViewRepresentable {
  let minimum: CGSize

  func makeNSView(context: Context) -> NSView { Anchor(minimum: minimum) }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class Anchor: NSView {
    let minimum: CGSize
    /// SwiftUI sets the frame of its settings window again whenever it updates the scene, and
    /// takes the corner away each time; it is given back at once.
    private var watch: NSKeyValueObservation?

    init(minimum: CGSize) {
      self.minimum = minimum
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      watch = nil
      guard let window else { return }
      Self.resizable(window, minimum: minimum)
      let minimum = minimum
      watch = window.observe(\.styleMask) { window, _ in
        MainActor.assumeIsolated { Self.resizable(window, minimum: minimum) }
      }
    }

    private static func resizable(_ window: NSWindow, minimum: CGSize) {
      if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
      let floor = window.contentMinSize
      if floor.width < minimum.width || floor.height < minimum.height {
        window.contentMinSize = CGSize(
          width: max(floor.width, minimum.width), height: max(floor.height, minimum.height))
      }
    }
  }
}
