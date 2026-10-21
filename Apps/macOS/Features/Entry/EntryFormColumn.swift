import AppCore
import SwiftUI

/// The form of a new operation at the right of the main window (`EntryStyle.form`): a title with
/// «Очистить», the fields of the panel in one column, what the entry has to say, and «Сохранить».
struct EntryFormColumn<Caption: View>: View {
  @Dependency(\.environment) private var environment
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
          .appFont(.headline)
        Spacer(minLength: 8)
        Button(environment.language("entry.form.clear", table: "Entry"), action: clear)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("entry.form.clear")
      }
      .padding(.horizontal, Self.inset)
      .padding(.vertical, 12)
      Divider()
      // The fields scroll; the title above and «Save» below stay where they are.
      ScrollView {
        DetailsPanel(
          model: model, submit: save, offersTransfer: true, focusedInside: $focusedInside,
          arrangement: .column, quickLine: quickLine, kindChosen: kindChosen
        )
        .padding(Self.inset)
      }
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        caption()
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if kindChosen?.wrappedValue ?? true {
          Button(action: save) {
            Text(verbatim: environment.language("entry.save", table: "Entry"))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          // Return saves from any field of the form — a menu, the date, a checkbox — while the
          // focus is in it; with the focus in the list beside it Return is the list's.
          .keyboardShortcut(focusedInside ? .defaultAction : nil)
          .accessibilityIdentifier("entry.form.save")
        }
      }
      .padding(Self.inset)
    }
  }

  /// The margin of the column on every side.
  private static var inset: CGFloat { 16 }
}
