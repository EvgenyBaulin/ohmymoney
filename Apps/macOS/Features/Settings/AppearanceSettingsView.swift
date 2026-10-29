import AppCore
import SwiftUI

/// Settings → Appearance: «Светлая / Тёмная / Авто», the thirty colour themes (a click opens a
/// preview on the owner's own data), the accent over the theme, the size of the text, the style
/// of the currency, and the tiles of Overview (`OverviewTilesSection`).
///
/// No restart hint here, unlike the language next door: the theme applies at once —
/// `NSApp.appearance` for every window, alert and panel, the SwiftUI environment for the colours
/// and the accent (`AppThemeModifier`).
struct AppearanceSettingsView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  /// The theme whose preview sheet is open.
  @State private var previewing: ThemeID?

  /// «Светлая», «Тёмная», «Авто» — in this order.
  static let schemeOrder: [AppTheme.Scheme] = [.light, .dark, .system]

  var body: some View {
    @Bindable var theme = environment.theme
    Form {
      Section {
        Picker(selection: $theme.scheme) {
          ForEach(Self.schemeOrder, id: \.self) { scheme in
            Text(verbatim: Self.schemeTitle(scheme, environment)).tag(scheme)
          }
        } label: {
          Text(verbatim: environment.language("settings.appearance.scheme", table: "Settings"))
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings.appearance.scheme")
      } footer: {
        Text(verbatim: environment.language("settings.appearance.hint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      Section {
        ThemeStrip(
          chosen: theme.themeID, scheme: colorScheme,
          name: { environment.language($0.nameKey, table: "Themes") },
          chosenLabel: environment.language("appearance.theme.chosen", table: "Appearance"),
          open: { previewing = $0 })
      } header: {
        Text(verbatim: environment.language("appearance.themes.title", table: "Appearance"))
          .settingsHeaderStyle()
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: environment.language("appearance.themes.hint", table: "Appearance"))
          if contrast == .increased {
            Text(verbatim: environment.language("appearance.contrast.note", table: "Appearance"))
          }
        }
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }

      Section {
        // «Как в теме», then a row of circles, as in System Settings. The chosen one is ringed,
        // and its name stands under the title of the row, so nothing is told by colour alone.
        #if os(iOS)
          // A phone has no room for the title and eleven choices side by side: the choices wrap
          // under the title.
          VStack(alignment: .leading, spacing: 10) {
            accentTitle(theme.accent)
            AccentSwatches(selection: $theme.accent) { accent in
              Self.accentTitle(accent, environment)
            }
          }
          .padding(.vertical, 4)
        #else
          LabeledContent {
            AccentSwatches(selection: $theme.accent) { accent in
              Self.accentTitle(accent, environment)
            }
          } label: {
            accentTitle(theme.accent)
          }
        #endif
      } footer: {
        Text(verbatim: environment.language("appearance.accent.hint", table: "Appearance"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      Section {
        Picker(selection: $theme.fontSize) {
          ForEach(AppFontSize.allCases, id: \.self) { size in
            Text(verbatim: environment.language(size.settingsKey, table: "Settings")).tag(size)
          }
        } label: {
          Text(verbatim: environment.language("settings.appearance.fontSize", table: "Settings"))
        }
        .accessibilityIdentifier("settings.appearance.fontSize")

        Picker(selection: $theme.currencyStyle) {
          ForEach(CurrencyStyle.allCases, id: \.self) { style in
            Text(verbatim: Self.currencyStyleTitle(style, environment)).tag(style)
          }
        } label: {
          Text(
            verbatim: environment.language("settings.appearance.currencyStyle", table: "Settings"))
        }
        .accessibilityIdentifier("settings.appearance.currencyStyle")
      } footer: {
        Text(verbatim: environment.language("settings.appearance.textHint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      OverviewTilesSection()
    }
    .formStyle(.grouped)
    #if os(macOS)
      .padding()
    #endif
    .accessibilityIdentifier("settings.appearance")
    // A sheet is a host of its own: the dependencies are handed over.
    .sheet(item: $previewing) { id in
      AppearancePreviewSheet(
        draft: AppearanceThemeDraft(
          from: environment.theme, themeID: id, systemScheme: colorScheme)
      )
      .handingOver(dependencies)
    }
  }
}

extension AppearanceSettingsView {
  /// «Акцент» and under it the name of the chosen one, so nothing is told by colour alone.
  @ViewBuilder
  fileprivate func accentTitle(_ accent: AppTheme.Accent) -> some View {
    Text(verbatim: environment.language("settings.appearance.accent", table: "Settings"))
    Text(verbatim: Self.accentTitle(accent, environment))
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("settings.appearance.accent.chosen")
  }
}

extension ThemeID: Identifiable {
  public var id: String { rawValue }
}

extension AppearanceSettingsView {
  static func schemeTitle(_ scheme: AppTheme.Scheme, _ environment: AppEnvironment) -> String {
    let key =
      switch scheme {
      case .light: "appearance.scheme.light"
      case .dark: "appearance.scheme.dark"
      case .system: "appearance.scheme.auto"
      }
    return environment.language(key, table: "Appearance")
  }

  static func accentTitle(_ accent: AppTheme.Accent, _ environment: AppEnvironment) -> String {
    environment.language(accent.title.key, table: accent.title.table)
  }

  /// A choice of «Валюта» with what it writes: «Значок — 1,250 ₽», «Код — 1,250 RUB»,
  /// «Название — 1,250 руб.» (in English «Name» shows the code, and says so).
  static func currencyStyleTitle(_ style: CurrencyStyle, _ environment: AppEnvironment) -> String {
    let sample = MoneyFormatter(locale: environment.language.locale, currencyStyle: style)
      .exact(AmountE4(whole: 1_250))
    return environment.format(
      "settings.appearance.currencyStyle.choice", table: "Settings",
      environment.language(style.settingsKey, table: "Settings"), sample)
  }
}

/// «Как в теме», then the accents as circles of their colours. Each says its name on hover and to
/// VoiceOver; the chosen one wears a ring, which reads with a colour filter and with «Увеличить
/// контраст». «Системный» is painted in the accent the Mac has now.
struct AccentSwatches: View {
  @Binding var selection: AppTheme.Accent
  let name: (AppTheme.Accent) -> String

  static let diameter: CGFloat = 18
  /// Room around a circle that is part of its button but not of its picture.
  static var touchMargin: CGFloat {
    #if os(iOS)
      10
    #else
      0
    #endif
  }

  var body: some View {
    FlowRow(spacing: 10, lineSpacing: 8) {
      let followsTheme = selection == .theme
      Button {
        selection = .theme
      } label: {
        Text(verbatim: name(.theme))
          .appFont(.callout)
          .padding(.horizontal, 10)
          .padding(.vertical, 3)
          .overlay(
            Capsule().strokeBorder(
              followsTheme ? AnyShapeStyle(.primary) : AnyShapeStyle(.separator),
              lineWidth: followsTheme ? 2 : 1)
          )
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(followsTheme ? [.isSelected] : [])
      .accessibilityIdentifier("settings.appearance.accent.theme")

      ForEach(AppTheme.Accent.allCases.filter { $0 != .theme }, id: \.self) { accent in
        let chosen = accent == selection
        Button {
          selection = accent
        } label: {
          Circle()
            .fill(accent.swatch)
            .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
            .frame(width: Self.diameter, height: Self.diameter)
            .padding(3)
            .overlay {
              if chosen {
                Circle().strokeBorder(.primary, lineWidth: 2)
              }
            }
            // A finger needs 44 pt to hit; the pointer is happy with the circle.
            .padding(Self.touchMargin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name(accent))
        .accessibilityLabel(Text(verbatim: name(accent)))
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        .accessibilityIdentifier("settings.appearance.accent.\(accent.rawValue)")
      }
    }
    .accessibilityElement(children: .contain)
  }
}

/// The thirty themes as cards in a grid. A card shows the name, five dots of the theme's colours
/// in the scheme now on screen, and a check on the chosen one; a click opens the preview.
struct ThemeStrip: View {
  let chosen: ThemeID
  let scheme: ColorScheme
  let name: (ThemeID) -> String
  let chosenLabel: String
  let open: (ThemeID) -> Void

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
      ForEach(ThemeCatalog.all, id: \.id) { theme in
        card(theme)
      }
    }
    .accessibilityIdentifier("settings.appearance.themes")
  }

  private func card(_ theme: Theme) -> some View {
    let palette = scheme == .dark ? theme.dark : theme.light
    let isChosen = theme.id == chosen
    let outline = Color(isChosen ? palette.accentDefault : palette.borderCard)
    return Button {
      open(theme.id)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(verbatim: name(theme.id))
            .appFont(.callout)
            .foregroundStyle(Color(palette.contentPrimary))
            .lineLimit(1)
          Spacer(minLength: 4)
          if isChosen {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(Color(palette.accentDefault))
          }
        }
        HStack(spacing: 6) {
          ForEach(Array(ThemeSwatches.colors(of: theme, scheme: scheme).enumerated()), id: \.offset)
          {
            _, color in
            Circle().fill(Color(color)).frame(width: 14, height: 14)
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(palette.surfaceCard), in: RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12).strokeBorder(outline, lineWidth: isChosen ? 2 : 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(verbatim: name(theme.id)))
    .accessibilityValue(Text(verbatim: isChosen ? chosenLabel : ""))
    .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    .accessibilityIdentifier("settings.appearance.theme.\(theme.id.rawValue)")
  }
}
