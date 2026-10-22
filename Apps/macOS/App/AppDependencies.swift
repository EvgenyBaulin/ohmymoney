import AppCore
import OSLog
import Observation
import SwiftUI

/// Everything a window of the app needs: the environment, the store of writes and the
/// pipeline. Made once in `OhMyMoneyApp` and handed to the root view of every scene through its
/// initializer, so the compiler does not let a window forget one.
///
/// Below the root the views read it from the environment with `@Dependency`, which never
/// traps: SwiftUI's own `@Environment(SomeObservable.self)` stops the app when the object is
/// missing, and on macOS 27 the content of an inspector was laid out without it — the crash
/// of 19.09. What SwiftUI shows in a host of its own (an inspector, a sheet, a popover) gets
/// the dependencies handed over with `appDependencies(_:)`.
@MainActor
struct AppDependencies {
  let environment: AppEnvironment
  let store: TransactionsStore
  let compute: ComputeStore

  init(environment: AppEnvironment, store: TransactionsStore, compute: ComputeStore) {
    self.environment = environment
    self.store = store
    self.compute = compute
  }

  private static var standIn: AppDependencies?
  private static let log = Logger(
    subsystem: "io.github.EvgenyBaulin.ohmymoney", category: "dependencies")

  /// The files that went without, watched so the Debug badge appears the moment one does.
  @MainActor
  @Observable
  final class StandInWatch {
    static let shared = StandInWatch()
    var readers: Set<String> = []
  }

  /// Every view file that got the stand-in, so a test fails when a hand-over is missing
  /// instead of passing over a window that quietly does nothing. Who was shown without the
  /// dependencies, and what the tests read. A plain set: it is written from
  /// `Dependency.wrappedValue`, which is evaluated inside a view's `body`, and
  /// writing an observable property there is «Modifying state during view update» — the badge
  /// invalidating itself from inside the update that drew it.
  ///
  /// The badge's copy is written on the next turn of the main queue instead, so the view
  /// update that found a missing dependency is over by the time anything observes it.
  @MainActor private static var readers: Set<String> = []

  static var missingReaders: Set<String> {
    get { readers }
    set {
      readers = newValue
      let shown = newValue
      DispatchQueue.main.async { StandInWatch.shared.readers = shown }
    }
  }

  /// What a view gets when it is shown without the app's dependencies: objects attached to
  /// nothing, which never write and never count. In Debug every text of such a view says so
  /// (`AppLanguage.missingDependency`); in both builds the log gets one fault naming the
  /// view's file — never an amount or a name.
  static func missing(in reader: String) -> AppDependencies {
    // Only when this file is new. `Dependency.wrappedValue` is evaluated inside a `body`, and
    // a view without the dependencies is drawn again and again — writing the set every time
    // put a block on the main queue on every pass, and every one of them touched the
    // observable the Debug badge watches. The badge then asked for another pass, which drew
    // the view again. A set that is already what it would be written as says nothing new.
    if !readers.contains(reader) { missingReaders.insert(reader) }
    if let standIn { return standIn }
    log.fault("a view was shown without the app's dependencies: \(reader, privacy: .public)")
    // And into the journal, so a problem report carries it: a stand-in firing is a defect,
    // and the file that asked is the whole of the evidence.
    AppLog.error(
      "dependencies.missing", .ui, "a view was shown without the app's dependencies",
      [LogPair("reader", .file(reader))])
    let made = AppDependencies(
      environment: AppEnvironment(missingDependency: reader),
      store: TransactionsStore(standInFor: reader), compute: ComputeStore(calendar: .system))
    standIn = made
    return made
  }
}

extension EnvironmentValues {
  /// Optional on purpose: a window that forgot it reads `nil`, never a trap.
  @Entry var dependencies: AppDependencies? = nil

  /// The one accent colour of the app, resolved from the theme (`AppTheme`). It is handed
  /// down as a value and not only as `.tint`, because `Color.accentColor` does not follow
  /// `.tint(_:)` and the charts need a `Color` they can take `.secondary` of. The default is
  /// the system's accent, which is what the app showed before the setting existed.
  @Entry var appAccent: Color = .accentColor
}

/// Reads one of the app's dependencies below the root of a scene. When the view is shown
/// without them it gets the stand-in of `AppDependencies.missing(in:)` instead of stopping.
@MainActor
@propertyWrapper
struct Dependency<Value>: DynamicProperty {
  @Environment(\.dependencies) private var dependencies
  private let keyPath: KeyPath<AppDependencies, Value>
  private let reader: String

  init(_ keyPath: KeyPath<AppDependencies, Value>, reader: String = #fileID) {
    self.keyPath = keyPath
    self.reader = reader
  }

  var wrappedValue: Value {
    (dependencies ?? AppDependencies.missing(in: reader))[keyPath: keyPath]
  }
}

extension View {
  /// Hands the dependencies to this view and everything below it, with the locale of the
  /// interface language so Charts, date pickers and every system formatter follow the app's
  /// language. The roots of the scenes get it from `AppScenes.root`; content that
  /// SwiftUI shows in a host of its own — inspectors, sheets, popovers — gets it where it is
  /// presented.
  func appDependencies(_ deps: AppDependencies) -> some View {
    environment(\.dependencies, deps)
      .environment(\.locale, deps.environment.language.locale)
      .modifier(AppTheming(theme: deps.environment.theme))
  }
}

/// The SwiftUI half of the theme: the accent for everything `.tint(_:)` reaches, and the same
/// accent as a value for the charts. A modifier and not two lines in `appDependencies(_:)`: the
/// theme is read here, inside a `body`, so a change to it redraws what it paints instead of
/// waiting for the next window.
///
/// Light or dark is not set here: it reaches every window through `NSApp.appearance` alone
/// (`AppTheme.applyAppearance`). `preferredColorScheme` pinned the AppKit controls inside a form
/// to the scheme it named, and taking it back to «system» left them pinned — the theme picker
/// stayed white on a dark Mac.
private struct AppTheming: ViewModifier {
  let theme: AppTheme

  func body(content: Content) -> some View {
    content
      // The colours of the chosen theme and the accent over them (`AppThemeModifier`).
      .modifier(AppThemeModifier(theme: theme))
      // The size of the text chosen in Settings → Appearance, for every window and sheet.
      .modifier(AppFontSizing(size: theme.fontSize))
  }
}

extension View {
  /// Hands what a view got itself to content SwiftUI lays out in a host of its own — a sheet,
  /// a popover — below the root of a scene, where the dependencies are read, not owned.
  func handingOver(_ deps: AppDependencies?) -> some View {
    let resolved = deps ?? AppDependencies.missing(in: #fileID)
    return environment(\.dependencies, deps)
      .environment(\.locale, resolved.environment.language.locale)
      .modifier(AppTheming(theme: resolved.environment.theme))
  }
}

extension View {
  /// In Debug a window that showed anything without the app's dependencies wears a badge, so
  /// it is seen at once and not mistaken for a working window. The badge is an overlay: it
  /// never changes the size of anything below it, because a stand-in that changed sizes could
  /// rock the layout itself. In Release nothing is added.
  func standInBadge() -> some View {
    #if DEBUG
      return overlay(alignment: .topTrailing) { StandInBadge() }
    #else
      return self
    #endif
  }
}

#if DEBUG
  private struct StandInBadge: View {
    @State private var watch = AppDependencies.StandInWatch.shared

    var body: some View {
      if !watch.readers.isEmpty {
        Text(verbatim: "⚠︎ " + watch.readers.sorted().joined(separator: ", "))
          .appFont(.caption.monospaced())
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.red, in: Capsule())
          .foregroundStyle(.white)
          .padding(8)
          .allowsHitTesting(false)
          .accessibilityIdentifier("dependencies.missing")
      }
    }
  }
#endif

/// The one place a scene of the app is assembled: every window gets the same dependencies, and
/// every window starts the app — whichever comes first opens the database and runs the pipeline,
/// the others find it done (`AppLaunch`).
enum AppScenes {
  @MainActor
  static func root<Content: View>(
    _ deps: AppDependencies, window: AppWindow, launches: Bool = true,
    @ViewBuilder content: (AppDependencies) -> Content
  ) -> some View {
    content(deps)
      .appDependencies(deps)
      .standInBadge()
      // Which window was on screen when something went wrong is half of reading a report:
      // the line names it.
      .onAppear { ScreenJournal.opened(window) }
      .onDisappear { ScreenJournal.closed(window) }
      .task {
        // The test host is this very app, and its windows are built for real. Left to
        // start, they open the owner's Debug database, attach a store to it and leave
        // `AppLaunch.running` pointing at an environment no test knows about — which the
        // quit at the end of the run would then close instead of the app's own.
        // A test that wants the start calls `AppLaunch.start` itself.
        guard launches, !AppEnvironment.isTestHost else { return }
        await AppLaunch.start(deps.environment, store: deps.store, compute: deps.compute)
      }
  }
}
