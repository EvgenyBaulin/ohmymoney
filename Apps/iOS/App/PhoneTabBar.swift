import SwiftUI

/// The colours of the bar: the `tab/*` tokens of the theme in the scheme on view. The theme
/// itself is the one the environment carries (the first, until the owner chooses another);
/// «Увеличить контраст» always means the contrast theme.
struct NavBarColors {
  let background: Color
  let icon: Color
  let activeContent: Color
  let pill: Color

  init(
    theme: AppThemeColors, colorScheme: ColorScheme, contrast: ColorSchemeContrast
  ) {
    let resolved = ThemeResolver.resolve(
      theme: theme.id, colorScheme: colorScheme, increasedContrast: contrast == .increased)
    background = resolved.tabBackground
    icon = resolved.tabIcon
    activeContent = resolved.tabActiveContent
    pill = resolved.accentDefault
  }
}

/// One section of the bar: a line symbol; the active one opens into a pill of the accent with
/// its name beside the symbol. The name is also the accessibility label of the inactive ones.
struct NavBarButton: View {
  let title: String
  let symbol: String
  let isActive: Bool
  let colors: NavBarColors
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .imageScale(.large)
          .symbolVariant(.none)
        if isActive {
          Text(verbatim: title)
            .appFont(.footnote.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
      }
      .foregroundStyle(isActive ? colors.activeContent : colors.icon)
      .padding(.horizontal, isActive ? 14 : 10)
      .frame(minWidth: 44, minHeight: 44)
      .background {
        if isActive { Capsule().fill(colors.pill) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
    .animation(.snappy(duration: 0.2), value: isActive)
  }
}

/// The bar at the bottom of the phone: four sections the owner chose and «Ещё». The entry bar
/// floats above it; the screens above fade into the colour of the page over the last 56 points.
struct PhoneTabBar: View {
  let layout: NavLayout
  let router: PhoneRouter
  let title: (NavItem) -> String
  let moreTitle: String

  @Environment(\.appTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  /// The height of the fade the screens wear over the bar.
  static let fadeHeight: CGFloat = 56

  var body: some View {
    let colors = NavBarColors(theme: theme, colorScheme: colorScheme, contrast: contrast)
    HStack(spacing: 0) {
      ForEach(layout.visible) { item in
        NavBarButton(
          title: title(item), symbol: item.symbol, isActive: router.current == item,
          colors: colors
        ) { router.open(nav: item) }
        .frame(maxWidth: router.current == item ? nil : .infinity)
        .layoutPriority(router.current == item ? 1 : 0)
      }
      NavBarButton(
        title: moreTitle, symbol: "ellipsis", isActive: router.isMoreLit(visible: layout.visible),
        colors: colors
      ) { router.open(PhoneRoute(tab: .more)) }
      .frame(maxWidth: router.isMoreLit(visible: layout.visible) ? nil : .infinity)
      .layoutPriority(router.isMoreLit(visible: layout.visible) ? 1 : 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(colors.background, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    // The bar floats: a margin on every side, the page shows around it (design: tab bar pill).
    .padding(.horizontal, 16)
    .padding(.top, 6)
    .padding(.bottom, 8)
  }
}

/// The fade over the bottom of a screen that stands above the bar of the phone: the colour of
/// the page, from clear to solid, so the content goes under the bar and not through it.
struct NavBarFade: View {
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    LinearGradient(
      colors: [surfaces.background.opacity(0), surfaces.background],
      startPoint: .top, endPoint: .bottom
    )
    .frame(height: PhoneTabBar.fadeHeight)
    .allowsHitTesting(false)
  }
}

private struct NavBarFadesKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Whether the screens fade into the page over their bottom edge: the bar of the phone is
  /// under them. A view never given a value does not fade.
  var fadesOverNavBar: Bool {
    get { self[NavBarFadesKey.self] }
    set { self[NavBarFadesKey.self] = newValue }
  }
}
