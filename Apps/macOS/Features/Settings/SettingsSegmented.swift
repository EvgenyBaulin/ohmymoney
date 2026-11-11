import SwiftUI

/// The measures of the controls the settings share, as the design draws them (Figma «Настройки ·
/// Оформление», 6:168900): a segmented control is a track with 2 around it, every choice 14 × 6
/// inside, 13 point text; a theme tile 104 × 58; an accent circle 26. Plain numbers, so a test
/// holds them.
enum SettingsControlMetrics {
  static let trackPadding: CGFloat = 2
  static let trackRadius: CGFloat = 17
  static let choiceRadius: CGFloat = 15
  static let choiceHorizontal: CGFloat = 14
  static let choiceVertical: CGFloat = 6
  static let blockGap: CGFloat = 18
  static let labelGap: CGFloat = 8
  static let themeTile = CGSize(width: 104, height: 58)
  static let themeTileRadius: CGFloat = 10
  static let themeTilePadding = CGSize(width: 10, height: 9)
  static let themeDotsHeight: CGFloat = 10
  static let themeGap: CGFloat = 10
  static let accentCircle: CGFloat = 26
  static let accentFollowsRadius: CGFloat = 16
  static let accentFollowsPadding = CGSize(width: 12, height: 6)
  static let fontAndCurrencyGap: CGFloat = 40
  static let labelIcon: CGFloat = 16
}

/// «Светлая · Тёмная · Авто»: a pill track with the chosen choice on the accent, the others
/// quiet. The chosen one is also semibold, so the choice never rests on colour alone.
struct SettingsSegmented<Value: Hashable>: View {
  @Binding var selection: Value
  let choices: [Value]
  let title: (Value) -> String
  let identifier: String
  @Environment(\.appTheme) private var theme

  var body: some View {
    HStack(spacing: 0) {
      ForEach(choices, id: \.self) { choice in
        let chosen = choice == selection
        Button {
          selection = choice
        } label: {
          Text(verbatim: title(choice))
            .appFont(AppFont.body.weight(chosen ? .semibold : .medium))
            .foregroundStyle(
              chosen
                ? theme.contentOnAccent : theme.contentSecondary
            )
            .padding(.horizontal, SettingsControlMetrics.choiceHorizontal)
            .padding(.vertical, SettingsControlMetrics.choiceVertical)
            .background(
              chosen ? theme.accentDefault : .clear,
              in: .rect(cornerRadius: SettingsControlMetrics.choiceRadius)
            )
            .contentShape(.rect(cornerRadius: SettingsControlMetrics.choiceRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        .accessibilityIdentifier("\(identifier).\(String(describing: choice))")
      }
    }
    .padding(SettingsControlMetrics.trackPadding)
    .background(theme.surfaceSegmented, in: .rect(cornerRadius: SettingsControlMetrics.trackRadius))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }
}

#if os(macOS)
/// «Люди · События · Места»: the quieter tabs of a list section (Figma «Настройки · Справочники»,
/// 61:28778) — a track rounded 10 with 3 around it, the choices 12 × 5 rounded 8 with 12-point
/// text, the chosen one a white card, semibold.
enum SettingsTabsMetrics {
  static let trackPadding: CGFloat = 3
  static let trackRadius: CGFloat = 10
  static let choiceRadius: CGFloat = 8
  static let choiceHorizontal: CGFloat = 12
  static let choiceVertical: CGFloat = 5
  static let spacing: CGFloat = 2
  static let fontSize: CGFloat = 12
}

struct SettingsTabs<Value: Hashable>: View {
  @Binding var selection: Value
  let choices: [Value]
  let title: (Value) -> String
  let identifier: String
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    HStack(spacing: SettingsTabsMetrics.spacing) {
      ForEach(choices, id: \.self) { choice in
        let chosen = choice == selection
        Button {
          selection = choice
        } label: {
          Text(verbatim: title(choice))
            .appFont(
              AppFont.system(size: SettingsTabsMetrics.fontSize, weight: chosen ? .semibold : .regular)
            )
            .foregroundStyle(chosen ? surfaces.primary : surfaces.secondary)
            .padding(.horizontal, SettingsTabsMetrics.choiceHorizontal)
            .padding(.vertical, SettingsTabsMetrics.choiceVertical)
            .background(
              chosen ? surfaces.card : .clear,
              in: .rect(cornerRadius: SettingsTabsMetrics.choiceRadius)
            )
            .contentShape(.rect(cornerRadius: SettingsTabsMetrics.choiceRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        .accessibilityIdentifier("\(identifier).\(String(describing: choice))")
      }
    }
    .padding(SettingsTabsMetrics.trackPadding)
    .background(theme.surfaceSegmented, in: .rect(cornerRadius: SettingsTabsMetrics.trackRadius))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }
}
#endif
