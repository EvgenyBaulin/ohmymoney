import AppCore
import SwiftUI

/// The form of a new operation at the right of the main window (`EntryStyle.form`): a title with
/// «Очистить», the fields of the panel in one column, what the entry has to say, and «Записать».
struct EntryFormColumn<Caption: View>: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  @Bindable var model: EntryDraftModel
  /// Whether a field of the form has the keyboard: Return is «Save» only then.
  @Binding var focusedInside: Bool
  let save: () -> Void
  let clear: () -> Void
  /// The line of quick entry over the fields (`QuickEntryFlow`), in the focus of the panel.
  var quickLine: ((FocusState<PanelFocus?>.Binding) -> AnyView)? = nil
  /// Whether the kind of the next operation has been chosen: until it is, the column holds the
  /// quick line and the kinds alone, and no «Сохранить». `nil`: the fields are always there.
  var kindChosen: Binding<Bool>? = nil
  @ViewBuilder let caption: () -> Caption

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: environment.language("entry.form.title", table: "Entry"))
          .appFont(EntryType.formTitle)
          .accessibilityIdentifier("entry.form.title")
        Spacer(minLength: 8)
        Button(environment.language("entry.form.clear", table: "Entry"), action: clear)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("entry.form.clear")
      }
      .padding([.horizontal, .top], EntryFormMetrics.inset)
      .padding(.bottom, EntryFormMetrics.gap)
      // The fields scroll; the title above and «Записать» below stay where they are.
      ScrollView {
        DetailsPanel(
          model: model, submit: save, offersTransfer: true, focusedInside: $focusedInside,
          arrangement: .column, quickLine: quickLine, kindChosen: kindChosen
        )
        .padding(.horizontal, EntryFormMetrics.inset)
      }
      VStack(alignment: .leading, spacing: EntryFormMetrics.gap) {
        caption()
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if kindChosen?.wrappedValue ?? true {
          Button(action: save) {
            Text(verbatim: environment.language("entry.save", table: "Entry"))
          }
          .buttonStyle(EntryFormSaveStyle(fill: surfaces.accent, ink: surfaces.onAccent))
          // Return saves from any field of the form — a menu, the date, a checkbox — while the
          // focus is in it; with the focus in the list beside it Return is the list's.
          .keyboardShortcut(focusedInside ? .defaultAction : nil)
          .accessibilityIdentifier("entry.form.save")
        }
      }
      .padding(.horizontal, EntryFormMetrics.inset)
      .padding(.vertical, EntryFormMetrics.gap)
    }
    .background(surfaces.card)
  }
}

/// «Записать» of the form and of the ↓ panel: the accent, rounded 8, its word 11 pt, 16 × 8
/// inside — the design's main button on the Mac.
struct EntryFormSaveStyle: ButtonStyle {
  let fill: Color
  let ink: Color
  /// Across the column (the form), or as wide as its word (the foot of the ↓ panel).
  var stretches = true
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .appFont(EntryType.save)
      .foregroundStyle(ink)
      .padding(.horizontal, EntryFormMetrics.saveHorizontal)
      .padding(.vertical, EntryFormMetrics.saveVertical)
      .frame(maxWidth: stretches ? .infinity : nil)
      .background(fill, in: RoundedRectangle(cornerRadius: EntryFormMetrics.saveRadius))
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
      .contentShape(RoundedRectangle(cornerRadius: EntryFormMetrics.saveRadius))
  }
}
