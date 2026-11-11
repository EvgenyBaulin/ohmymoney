#if os(macOS)
  import SwiftUI

  /// The measures of a settings card, as the design draws it (Figma «Настройки · Приватность»,
  /// 6:94918): a white card rounded 12 with a hairline border, rows of 16 × 14 with a 24-point
  /// slot for an 18-point symbol, 12 to the text, the title 14 medium over a 12-point hint 2
  /// below, the control at the right; hairlines between the rows.
  enum SettingsCardMetrics {
    static let radius: CGFloat = 12
    static let rowHorizontal: CGFloat = 16
    static let rowVertical: CGFloat = 14
    static let rowGap: CGFloat = 12
    static let iconSlot: CGFloat = 24
    static let icon: CGFloat = 18
    static let textGap: CGFloat = 2
    static let hairline: CGFloat = 1
    /// The slimmer rows of a list of switches: 11 above and below, 13 over 11.
    static let compactVertical: CGFloat = 11
    static let compactSwitchWidth: CGFloat = 40
  }

  /// A card of rows; the rows are separated by hairlines.
  struct SettingsCard<Content: View>: View {
    @Environment(\.themeSurfaces) private var surfaces
    @ViewBuilder let content: Content

    var body: some View {
      VStack(spacing: 0) { content }
        .frame(maxWidth: .infinity)
        .background(surfaces.card, in: .rect(cornerRadius: SettingsCardMetrics.radius))
        .overlay(
          RoundedRectangle(cornerRadius: SettingsCardMetrics.radius)
            .strokeBorder(surfaces.cardBorder, lineWidth: SettingsCardMetrics.hairline)
        )
    }
  }

  /// One row of a card: symbol, title and hint, and the control (a switch, a value, a chevron).
  struct SettingsCardRow<Trailing: View>: View {
    @Environment(\.themeSurfaces) private var surfaces
    var symbol: String?
    let title: String
    var hint: String?
    var showsDivider = true
    /// The row of a list of switches: no symbol, 13 over 11, 11 above and below.
    var compact = false
    /// Overrides the margin above and below the row (the design's rows with a hint are 11, not 14).
    var verticalPadding: CGFloat?
    @ViewBuilder let trailing: Trailing

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: SettingsCardMetrics.rowGap) {
          if let symbol {
            Image(systemName: symbol)
              .font(.system(size: 15))  // font-fixed: symbol in a 24 pt slot
              .foregroundStyle(surfaces.secondary)
              .frame(width: SettingsCardMetrics.iconSlot, height: SettingsCardMetrics.iconSlot)
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: SettingsCardMetrics.textGap) {
            Text(verbatim: title)
              .appFont(AppFont.system(size: compact ? 13 : 14, weight: .medium))
              .foregroundStyle(surfaces.primary)
            if let hint {
              Text(verbatim: hint)
                .appFont(compact ? AppFont.system(size: 11) : AppFont.callout)
                .foregroundStyle(surfaces.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Spacer(minLength: 8)
          trailing
        }
        .padding(.horizontal, SettingsCardMetrics.rowHorizontal)
        .padding(
          .vertical,
          verticalPadding
            ?? (compact ? SettingsCardMetrics.compactVertical : SettingsCardMetrics.rowVertical))
        if showsDivider {
          Rectangle().fill(surfaces.cardBorder.opacity(0.6))
            .frame(height: SettingsCardMetrics.hairline)
        }
      }
      .accessibilityElement(children: .contain)
    }
  }

  /// A titled group of a settings section: the title 13 semibold, 8 to the card, a footer 12
  /// under it; the group is a clear row of the grouped form, 28 from the edges (Figma «Настройки ·
  /// Основные», 52:585).
  struct SettingsCardGroup<Content: View>: View {
    let title: String?
    var footer: String?
    /// Between the title and the card: 8 in «Основные», 18 in the planning sections.
    var titleGap: CGFloat = 8
    var verticalMargin: CGFloat = 9
    @ViewBuilder let content: Content

    var body: some View {
      Section {
        VStack(alignment: .leading, spacing: titleGap) {
          if let title {
            Text(verbatim: title)
              .appFont(AppFont.system(size: 13, weight: .semibold))
              .accessibilityAddTraits(.isHeader)
          }
          SettingsCard { content }
          if let footer {
            Text(verbatim: footer)
              .appFont(AppFont.system(size: 12))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.horizontal, SettingsChromeMetrics.contentInset)
        .padding(.vertical, verticalMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
    }
  }

  /// The value of a row that opens a menu: the value 13 and a small chevron, no frame.
  struct SettingsValueMenu<Content: View>: View {
    let value: String
    @ViewBuilder let content: Content
    @Environment(\.themeSurfaces) private var surfaces

    var body: some View {
      Menu {
        content
      } label: {
        HStack(spacing: 4) {
          Text(verbatim: value)
            .appFont(AppFont.system(size: 13))
            .foregroundStyle(surfaces.secondary)
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))  // font-fixed: chevron of a value
            .foregroundStyle(surfaces.secondary)
            .accessibilityHidden(true)
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  /// A button under a card, as the design draws it (Figma 61:31123): the neutral fill rounded 8,
  /// 16 × 9 around a 13-point medium label.
  struct SettingsActionButtonStyle: ButtonStyle {
    static let radius: CGFloat = 8
    static let horizontal: CGFloat = 16
    static let vertical: CGFloat = 9
    @Environment(\.appTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .appFont(AppFont.system(size: 13, weight: .medium))
        .foregroundStyle(theme.contentPrimary)
        .padding(.horizontal, Self.horizontal)
        .padding(.vertical, Self.vertical)
        .background(theme.fillNeutral, in: .rect(cornerRadius: Self.radius))
        .contentShape(.rect(cornerRadius: Self.radius))
        .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
  }
#endif
