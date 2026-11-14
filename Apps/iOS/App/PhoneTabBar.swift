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

/// Whether the bottom bar names only the open tab (a setting of «Оформление» on the phone). Off by
/// default: every tab shows its name. Kept on the device, not carried by the archive.
enum PhoneTabLabels {
  static let activeOnlyKey = "phone.tabLabels.activeOnly"
}

/// One section of the bar: a line symbol; the active one opens into a pill of the accent with
/// its name beside the symbol. The name is also the accessibility label of the inactive ones.
struct NavBarButton: View {
  let title: String
  let symbol: String
  let isActive: Bool
  let colors: NavBarColors
  /// Every tab shows its name under the symbol; the open one sits in the pill. When off, only the
  /// open tab has a name, beside its symbol.
  var labelsOnAll = false
  let action: () -> Void

  init(
    title: String, symbol: String, isActive: Bool, colors: NavBarColors, labelsOnAll: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.symbol = symbol
    self.isActive = isActive
    self.colors = colors
    self.labelsOnAll = labelsOnAll
    self.action = action
  }

  /// The room a tab keeps at its sides. With every name shown the tabs share the width of the
  /// bar and the longest name («Планирование») has to fit in what is left, scaled down to 0.7
  /// at most: a wide margin turned it into «Планиров…».
  static func horizontalPadding(isActive: Bool, labelsOnAll: Bool) -> CGFloat {
    if labelsOnAll { return 3 }
    return isActive ? 14 : 10
  }

  var body: some View {
    Button(action: action) {
      Group {
        if labelsOnAll {
          VStack(spacing: 2) {
            Image(systemName: symbol)
              .imageScale(.large)
              .symbolVariant(.none)
            Text(verbatim: title)
              .appFont(.caption2.weight(.medium))
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
        } else {
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
        }
      }
      .foregroundStyle(isActive ? colors.activeContent : colors.icon)
      .padding(.horizontal, Self.horizontalPadding(isActive: isActive, labelsOnAll: labelsOnAll))
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
  @AppStorage(PhoneTabLabels.activeOnlyKey) private var activeLabelOnly = false

  /// The height of the fade the screens wear over the bar.
  static let fadeHeight: CGFloat = 56

  var body: some View {
    let colors = NavBarColors(theme: theme, colorScheme: colorScheme, contrast: contrast)
    HStack(spacing: 0) {
      ForEach(layout.visible) { item in
        NavBarButton(
          title: title(item), symbol: item.symbol, isActive: router.current == item,
          colors: colors, labelsOnAll: !activeLabelOnly
        ) { router.open(nav: item) }
        .frame(maxWidth: router.current == item && activeLabelOnly ? nil : .infinity)
        // Only a bar that labels the active tab alone lets it widen; with every label shown the
        // tabs share the width equally, or the active one squeezed the rest to «Tra…».
        .layoutPriority(router.current == item && activeLabelOnly ? 1 : 0)
      }
      NavBarButton(
        title: moreTitle, symbol: "ellipsis", isActive: router.isMoreLit(visible: layout.visible),
        colors: colors, labelsOnAll: !activeLabelOnly
      ) { router.open(PhoneRoute(tab: .more)) }
      .frame(
        maxWidth: router.isMoreLit(visible: layout.visible) && activeLabelOnly ? nil : .infinity
      )
      .layoutPriority(router.isMoreLit(visible: layout.visible) && activeLabelOnly ? 1 : 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(colors.background, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    // The bar floats: a margin on every side, the page shows around it (design: tab bar pill).
    .padding(.horizontal, PhoneMetrics.screenMargin)
    .padding(.top, 6)
    .padding(.bottom, PhoneMetrics.barBottomMargin)
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
