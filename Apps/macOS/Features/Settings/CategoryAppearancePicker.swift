import AppCore
import SwiftUI

/// Names of the strings of the category mark picker.
enum CategoryAppearanceText {
  /// The String Catalog key (table `Settings`) of a symbol's name, for VoiceOver and conflicts.
  static func iconNameKey(_ icon: String) -> String { "categories.icon.\(icon)" }
}

/// A round mark of a category: its symbol on the tint of its tone, or a dashed circle when it
/// has no symbol of its own. The same drawing the rows of «Операции» use, at any size.
/// Decoration: the name of the category stands next to it.
struct CategoryMarkView: View {
  @Environment(\.appTheme) private var theme
  let icon: String?
  let tone: CategoryTone?
  var side: CGFloat = 28

  var body: some View {
    let palette = theme.palette
    let shown = tone ?? .accent
    Image(systemName: icon ?? "circle.dashed")
      .font(.system(size: side * 0.45, weight: .semibold))  // font-fixed: grows with the mark
      .frame(width: side, height: side)
      .foregroundStyle(icon == nil ? Color(palette.contentSecondary) : Color(shown.ink(in: palette)))
      .background(
        icon == nil ? Color(palette.contentSecondaryTint) : Color(shown.tint(in: palette)),
        in: .circle
      )
      .accessibilityHidden(true)
  }
}

/// The popover of a category's mark: a grid of symbols and a row of colours, each chosen with one
/// click and written at once. The chosen symbol and colour are told by a ring and a check, never
/// by colour alone, and every one has a name for VoiceOver and for hover.
struct CategoryAppearancePicker: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  /// What the category says of its own; the picker marks these.
  let appearance: CategoryAppearance
  /// Called with the whole new appearance after each click.
  let choose: (CategoryAppearance) -> Void

  private let columns = [GridItem(.adaptive(minimum: 38, maximum: 44), spacing: 6)]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: environment.language("categories.appearance.icon", table: "Settings"))
        .appFont(.headline)
      LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
        ForEach(CategoryIcon.all, id: \.self) { icon in
          iconButton(icon)
        }
      }
      Button(environment.language("categories.appearance.noIcon", table: "Settings")) {
        choose(CategoryAppearance(icon: nil, color: appearance.color))
      }
      .disabled(appearance.icon == nil)

      Divider()

      Text(verbatim: environment.language("categories.appearance.color", table: "Settings"))
        .appFont(.headline)
      HStack(spacing: 8) {
        ForEach(CategoryTone.allCases, id: \.self) { tone in
          toneButton(tone)
        }
      }
      Button(environment.language("categories.appearance.noColor", table: "Settings")) {
        choose(CategoryAppearance(icon: appearance.icon, color: nil))
      }
      .disabled(appearance.color == nil)

      Text(verbatim: environment.language("categories.appearance.hint", table: "Settings"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(width: 340)
  }

  private func iconButton(_ icon: String) -> some View {
    let chosen = appearance.icon == icon
    let palette = theme.palette
    let name = environment.language(CategoryAppearanceText.iconNameKey(icon), table: "Settings")
    return Button {
      choose(CategoryAppearance(icon: icon, color: appearance.color))
    } label: {
      Image(systemName: icon)
        .font(.system(size: 17, weight: .medium))  // font-fixed: a picture in a fixed cell
        .frame(width: 36, height: 36)
        .foregroundStyle(Color(palette.contentPrimary))
        .background(chosen ? Color(palette.accentTint) : .clear, in: .circle)
        .overlay(Circle().strokeBorder(chosen ? Color(palette.accentDefault) : .clear, lineWidth: 2))
    }
    .buttonStyle(.plain)
    .help(Text(verbatim: name))
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityAddTraits(chosen ? .isSelected : [])
  }

  private func toneButton(_ tone: CategoryTone) -> some View {
    let chosen = appearance.color == tone.key
    let palette = theme.palette
    let name = environment.language(tone.nameKey, table: "Settings")
    return Button {
      choose(CategoryAppearance(icon: appearance.icon, color: tone.key))
    } label: {
      Image(systemName: chosen ? "checkmark" : "circle.fill")
        .font(.system(size: 13, weight: .bold))  // font-fixed: a picture in a fixed cell
        .frame(width: 30, height: 30)
        .foregroundStyle(Color(tone.ink(in: palette)))
        .background(Color(tone.tint(in: palette)), in: .circle)
        .overlay(Circle().strokeBorder(chosen ? Color(tone.ink(in: palette)) : .clear, lineWidth: 2))
    }
    .buttonStyle(.plain)
    .help(Text(verbatim: name))
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityAddTraits(chosen ? .isSelected : [])
  }
}
