import SwiftUI

/// «Цвет счёта»: twelve circles of the palette and «Без цвета». Each says its name on hover and
/// to VoiceOver, the chosen one wears a ring (so it reads with a colour filter), and on the
/// phone a circle has 44 pt to tap.
struct AccountAccentPicker: View {
  @Binding var selection: String?
  let name: (AccountAccent) -> String
  let noneTitle: String

  static let diameter: CGFloat = 22
  /// Room around a circle that is part of its button but not of its picture.
  static var touchMargin: CGFloat {
    #if os(iOS)
      8
    #else
      0
    #endif
  }

  var body: some View {
    FlowRow(spacing: 6, lineSpacing: 6) {
      let none = AccountAccent(key: selection) == nil
      Button {
        selection = nil
      } label: {
        Text(verbatim: noneTitle)
          .appFont(.callout)
          .padding(.horizontal, 10)
          .padding(.vertical, 3)
          .overlay(
            Capsule().strokeBorder(
              none ? AnyShapeStyle(.primary) : AnyShapeStyle(.separator),
              lineWidth: none ? 2 : 1)
          )
          .frame(minHeight: Self.touchMargin == 0 ? 0 : 44)
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(none ? [.isSelected] : [])
      .accessibilityIdentifier("account.editor.accent.none")

      ForEach(AccountAccent.allCases, id: \.self) { accent in
        let chosen = AccountAccent(key: selection) == accent
        Button {
          selection = accent.key
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
            .padding(Self.touchMargin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name(accent))
        .accessibilityLabel(Text(verbatim: name(accent)))
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        .accessibilityIdentifier("account.editor.accent.\(accent.key)")
      }
    }
    .accessibilityElement(children: .contain)
  }
}
