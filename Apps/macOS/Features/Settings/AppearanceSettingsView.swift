import AppCore
import SwiftUI

/// Settings → Appearance: light, dark or the system's, the one accent colour of the app, and the
/// tiles of Overview (`OverviewTilesSection`).
///
/// No restart hint here, unlike the language next door: the theme applies at once —
/// `NSApp.appearance` for every window, alert and panel, the SwiftUI environment for the accent.
struct AppearanceSettingsView: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    @Bindable var theme = environment.theme
    Form {
      Section {
        Picker(selection: $theme.scheme) {
          ForEach(AppTheme.Scheme.allCases, id: \.self) { scheme in
            Text(verbatim: environment.language(scheme.settingsKey, table: "Settings"))
              .tag(scheme)
          }
        } label: {
          Text(verbatim: environment.language("settings.appearance.scheme", table: "Settings"))
        }
        .pickerStyle(.inline)
      } footer: {
        Text(verbatim: environment.language("settings.appearance.hint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      Section {
        // A row of circles, as in System Settings. The chosen one is ringed, and its name
        // stands under the title of the row, so nothing is told by the colour alone.
        LabeledContent {
          AccentSwatches(selection: $theme.accent) { accent in
            environment.language(accent.settingsKey, table: "Settings")
          }
        } label: {
          Text(verbatim: environment.language("settings.appearance.accent", table: "Settings"))
          Text(verbatim: environment.language(theme.accent.settingsKey, table: "Settings"))
            .accessibilityIdentifier("settings.appearance.accent.chosen")
        }
      } footer: {
        Text(verbatim: environment.language("settings.appearance.accentHint", table: "Settings"))
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
    .padding()
    .accessibilityIdentifier("settings.appearance")
  }
}

extension AppearanceSettingsView {
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

/// The accents as circles of their colours. Each says its name on hover and to VoiceOver; the
/// chosen one wears a ring, which reads with a colour filter and with «Увеличить контраст».
/// «Системный» is painted in the accent the Mac has now.
struct AccentSwatches: View {
  @Binding var selection: AppTheme.Accent
  let name: (AppTheme.Accent) -> String

  static let diameter: CGFloat = 18

  var body: some View {
    HStack(spacing: 10) {
      ForEach(AppTheme.Accent.allCases, id: \.self) { accent in
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
            .contentShape(Circle())
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
