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
          compact ? SettingsCardMetrics.compactVertical : SettingsCardMetrics.rowVertical)
        if showsDivider {
          Rectangle().fill(surfaces.cardBorder.opacity(0.6))
            .frame(height: SettingsCardMetrics.hairline)
        }
      }
      .accessibilityElement(children: .contain)
    }
  }
#endif
