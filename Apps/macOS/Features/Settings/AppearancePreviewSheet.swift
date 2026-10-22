import AppCore
import SwiftUI

/// A theme tried on the owner's own data: the real Overview, Operations and Planning screens,
/// drawn small with the theme's colours, not pictures. They read the same pipeline as the main
/// window, so the preview recomputes by itself — on opening, on a change of theme or scheme, and
/// whenever the data changes — and shows «Считается…» and «Мало данных» the way every block does.
///
/// Nothing is written until «Применить»: the screens are not touched (hit testing is off), the
/// draft is a copy, and cancelling drops it.
struct AppearancePreviewSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.dismiss) private var dismiss
  @State var draft: AppearanceThemeDraft

  /// The screens are made once per sheet, so switching the theme redraws them in place.
  @State private var actions = OperationActions()
  @State private var operations = OperationsScreenState()

  /// The size a screen is laid out at, and the scale it is shown at.
  static let screenSize = CGSize(width: 1_100, height: 760)
  static let scale: CGFloat = 0.65

  init(draft: AppearanceThemeDraft) {
    _draft = State(initialValue: draft)
  }

  private var colors: AppThemeColors { draft.colors(increasedContrast: contrast == .increased) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      status
      screens
      Text(verbatim: environment.language("appearance.preview.noWrites", table: "Appearance"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
      footer
    }
    .padding(20)
    .frame(width: Self.screenSize.width * Self.scale + 40)
    .accessibilityIdentifier("appearance.preview")
    // Opened on a theme: the data is recounted so the figures shown are fresh. From then on the
    // screens follow the pipeline by themselves, as they do in the main window.
    .onAppear { compute.run() }
  }

  private var header: some View {
    HStack {
      Text(
        verbatim: environment.format(
          "appearance.preview.title", table: "Appearance",
          environment.language(draft.themeID.nameKey, table: "Themes"))
      )
      .appFont(.headline)
      Spacer()
      Picker(selection: $draft.scheme) {
        Text(verbatim: environment.language("appearance.scheme.light", table: "Appearance"))
          .tag(ColorScheme.light)
        Text(verbatim: environment.language("appearance.scheme.dark", table: "Appearance"))
          .tag(ColorScheme.dark)
      } label: {
        Text(verbatim: environment.language("appearance.scheme.title", table: "Appearance"))
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 180)
      .accessibilityIdentifier("appearance.preview.scheme")
    }
  }

  /// The state of the data under the preview, in the words of every other block.
  @ViewBuilder
  private var status: some View {
    let state = Self.state(of: compute)
    VStack(alignment: .leading, spacing: 6) {
      if state.phase != .ready {
        ComputedBlock(
          title: environment.language("appearance.preview.dataTitle", table: "Appearance"),
          state: state, style: .plain,
          emptyReason: environment.language("appearance.preview.fewData", table: "Appearance"),
          retry: nil
        ) { (_: Void) in
          EmptyView()
        }
      }
      if environment.amounts.hidesAmounts {
        note("appearance.preview.amountsHidden", symbol: "eye.slash")
      }
      if contrast == .increased {
        note("appearance.contrast.note", symbol: "circle.lefthalf.filled")
      }
    }
  }

  private func note(_ key: String, symbol: String) -> some View {
    Label {
      Text(verbatim: environment.language(key, table: "Appearance"))
    } icon: {
      Image(systemName: symbol)
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }

  /// What the pipeline says about the data the screens are made of: counting, nothing to show
  /// yet, or ready.
  static func state(of compute: ComputeStore) -> BlockState<Void> {
    if compute.isRunning && compute.snapshot == nil { return .calculating }
    guard let snapshot = compute.snapshot else {
      return compute.isRunning ? .calculating : .notEnoughData
    }
    return snapshot.dataset.entries.isEmpty ? .notEnoughData : .ready((), at: Date())
  }

  private var screens: some View {
    VStack(spacing: 8) {
      Picker(selection: $draft.screen) {
        ForEach(AppearanceThemeDraft.Screen.allCases, id: \.self) { screen in
          Text(verbatim: environment.language(screen.titleKey, table: "Appearance")).tag(screen)
        }
      } label: {
        Text(verbatim: environment.language("appearance.preview.screen", table: "Appearance"))
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityIdentifier("appearance.preview.screens")

      screen
        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
        .scaleEffect(Self.scale, anchor: .topLeading)
        .frame(
          width: Self.screenSize.width * Self.scale, height: Self.screenSize.height * Self.scale,
          alignment: .topLeading
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .accessibilityIdentifier("appearance.preview.canvas")
    }
  }

  /// The real screens, with the draft's colours and the owner's accent over them. `colorScheme`
  /// is overridden for this subtree only: the application itself stays in the appearance the Mac
  /// has until «Применить».
  @ViewBuilder
  private var screen: some View {
    let colors = self.colors
    let deps = dependencies ?? AppDependencies.missing(in: #fileID)
    Group {
      switch draft.screen {
      case .overview: OverviewView(actions: actions)
      case .operations:
        OperationsScreen(deps: deps, actions: actions, state: operations)
      case .planning: PlanningView()
      }
    }
    .background(colors.surfaceBackground)
    .environment(\.colorScheme, draft.scheme)
    .themed(colors, accent: environment.theme.accent)
    .id("\(draft.themeID.rawValue)-\(draft.scheme)-\(draft.screen.rawValue)")
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button(environment.language("appearance.preview.cancel", table: "Appearance")) {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("appearance.preview.cancel")
      Button(environment.language("appearance.preview.apply", table: "Appearance")) {
        draft.apply(to: environment.theme)
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("appearance.preview.apply")
    }
  }
}
