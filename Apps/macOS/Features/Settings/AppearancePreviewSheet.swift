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

  /// The size a screen is laid out at, and the scale it is shown at, on a wide sheet.
  static let screenSize = CGSize(width: 1_100, height: 760)
  static let scale: CGFloat = 0.65
  /// The size of the screens of a phone, which a narrow sheet lays them out at.
  static let phoneScreenSize = CGSize(width: 390, height: 760)
  /// The widest a sheet can be and still hold the wide screens.
  static let wideFrom: CGFloat = 700

  /// The width the sheet has for the screens, as measured; `0` until it is.
  @State private var available: CGFloat = 0

  /// How the screens are laid out and scaled in a sheet `availableWidth` wide: the Mac's sheet
  /// and a tablet's hold the wide screens, a phone's holds the screens of a phone at their own
  /// size, so nothing runs off the edge. Unmeasured, the wide layout.
  static func canvas(availableWidth: CGFloat) -> (size: CGSize, scale: CGFloat) {
    guard availableWidth > 0 else { return (screenSize, scale) }
    if availableWidth >= wideFrom {
      return (screenSize, min(scale, availableWidth / screenSize.width))
    }
    return (phoneScreenSize, min(1, availableWidth / phoneScreenSize.width))
  }

  private var canvas: (size: CGSize, scale: CGFloat) { Self.canvas(availableWidth: available) }

  init(draft: AppearanceThemeDraft) {
    _draft = State(initialValue: draft)
  }

  private var colors: AppThemeColors { draft.colors(increasedContrast: contrast == .increased) }

  var body: some View {
    #if os(macOS)
      content
        .padding(20)
        .frame(width: Self.screenSize.width * Self.scale + 40)
    #else
      // On a phone or a tablet the sheet scrolls: the header, the screen and the buttons do not
      // fit one above the other.
      ScrollView {
        content
          .padding(20)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.width - 40
          } action: {
            available = $0
          }
      }
    #endif
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      status
      screens
      Text(verbatim: environment.language("appearance.preview.noWrites", table: "Appearance"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
      footer
    }
    .accessibilityIdentifier("appearance.preview")
    // Opened on a theme: the data is recounted so the figures shown are fresh. From then on the
    // screens follow the pipeline by themselves, as they do in the main window.
    .onAppear { compute.run() }
  }

  private var header: some View {
    // Side by side where there is room; the switch under the title where there is not.
    ViewThatFits(in: .horizontal) {
      HStack {
        title
        Spacer()
        schemePicker.frame(width: 180)
      }
      VStack(alignment: .leading, spacing: 8) {
        title
        schemePicker
      }
    }
  }

  private var title: some View {
    Text(
      verbatim: environment.format(
        "appearance.preview.title", table: "Appearance",
        environment.language(draft.themeID.nameKey, table: "Themes"))
    )
    .appFont(.headline)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var schemePicker: some View {
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
    .accessibilityIdentifier("appearance.preview.scheme")
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

      let canvas = self.canvas
      screen
        .frame(width: canvas.size.width, height: canvas.size.height)
        .scaleEffect(canvas.scale, anchor: .topLeading)
        .frame(
          width: canvas.size.width * canvas.scale, height: canvas.size.height * canvas.scale,
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
