import AppCore
import SwiftUI

/// The bar of a selection: how many operations, what they come to, and what can be done
/// with them.
///
/// It is a control, so it is glass. In the main window it is a second capsule above the
/// entry line, inside the same `GlassEffectContainer` (the `accessory` of `EntryBar`), so
/// the two morph into each other instead of stacking glass on glass, and it is as wide as
/// the line. In the Transactions window it floats alone at the bottom of the table, in a
/// container of its own, as wide as what it says (`hugsContent`). The buttons on it are
/// plain for the same reason.
///
/// While a bulk write too large for the main thread is on its way, a small
/// indicator stands next to the count and the buttons are inactive: the write is one step
/// of ⌘Z, and another change laid over it before it lands would get out of order. With
/// nothing selected the bar stays for the time of the write all the same, see `Form`.
struct SelectionBar: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  let actions: OperationActions
  /// As wide as its content rather than as the space it is given.
  var hugsContent = false

  /// What the bar shows.
  enum Form: Equatable {
    /// Nothing selected and nothing being written: no bar.
    case hidden
    /// Nothing selected while a large write lands — the undo of a large deletion, whose
    /// rows had left the selection, or a selection cleared with Esc while its change was on
    /// its way. The bar says only that the changes are being saved: it is the one place on
    /// screen that says why ⌘Z and the bulk menu wait.
    case writing
    /// The selection: its count, its totals and its buttons.
    case selection
  }

  nonisolated static func form(selection: Set<UUID>, writing: Bool) -> Form {
    if !selection.isEmpty { return .selection }
    return writing ? .writing : .hidden
  }

  var body: some View {
    let form = Self.form(selection: actions.selection, writing: store.isWritingInBackground)
    if form != .hidden {
      GlassCapsule {
        if form == .selection { selectionContent } else { writingContent }
      }
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .named(OperationActions.coordinateSpace))
      } action: {
        // Observed, this was the loop that took the window down on 21.09.
        // geometry: `barFrame` is `@ObservationIgnored` — nothing lays out again.
        actions.barFrame = $0
      }
      .onDisappear { actions.barFrame = .zero }
    }
  }

  /// The whole bar when it fits, a shorter one when it does not: the words of the buttons
  /// give way to their symbols, and the totals stay. In Russian the whole bar asks for 415 pt
  /// against 368 in English — and in the Transactions window at its default width, with the
  /// inspector open, the column of the table could not give that. The split then asked for
  /// one Update Constraints pass after another until AppKit threw, and the app died on a
  /// double click (23.09; the same layout loop by another door). A bar that can shrink
  /// never asks the column for more than the column has.
  private var selectionContent: some View {
    ViewThatFits(in: .horizontal) {
      selectionRow(compact: false)
      selectionRow(compact: true)
    }
  }

  private func selectionRow(compact: Bool) -> some View {
    HStack(spacing: 12) {
      Text(
        verbatim: environment.language.format(
          "selection.count", table: "Transactions", counts: actions.selection.count)
      )
      .appFont(.callout.weight(.semibold))
      .monospacedDigit()
      .lineLimit(1)
      if store.isWritingInBackground {
        WritingIndicator()
          .help(t("selection.writing"))
          .accessibilityLabel(Text(verbatim: t("selection.writing")))
      }
      RowTotalsLine(totals: store.totals(ids: actions.selection))
        .lineLimit(1)
      if hugsContent {
        Color.clear.frame(width: 4, height: 1)
      } else {
        Spacer(minLength: 8)
      }
      Group {
        Menu {
          BulkMenuItems(ids: actions.selection, actions: actions)
        } label: {
          if compact {
            Image(systemName: "pencil")
          } else {
            Text(verbatim: t("selection.change"))
          }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .help(t("selection.change"))
        .accessibilityLabel(Text(verbatim: t("selection.change")))
        .accessibilityIdentifier("selection.change")
        Button {
          actions.requestDeletion(of: actions.selection, store: store)
        } label: {
          if compact {
            Image(systemName: "trash")
          } else {
            Text(verbatim: t("selection.delete"))
          }
        }
        .buttonStyle(.borderless)
        .help(t("selection.delete"))
        .accessibilityLabel(Text(verbatim: t("selection.delete")))
        Button {
          actions.selection = []
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help(t("selection.clear"))
        .accessibilityLabel(Text(verbatim: t("selection.clear")))
      }
      .disabled(store.isWritingInBackground)
    }
  }

  /// No count and nothing to press: the indicator and the words, where the count stands.
  private var writingContent: some View {
    HStack(spacing: 8) {
      WritingIndicator()
        .accessibilityHidden(true)
      Text(verbatim: t("selection.writing"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
      if !hugsContent { Spacer(minLength: 0) }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Transactions") }
}

/// The bar's sign that a write is on its way: a symbol SwiftUI draws itself, never a
/// `ProgressView`. That one is an AppKit `NSProgressIndicator` hosted inside SwiftUI, and the
/// bar slides in and out: SwiftUI moves a hosted view by its frame transform on every render,
/// and every move dirties the constraints of the window. With the display asleep or the
/// screen locked the window renders inside its own layout, so each layout pass moved the
/// indicator again and asked for another — until AppKit ran out of Update Constraints passes
/// and threw. A drawn symbol is moved with the rest of the bar and asks the layout for nothing.
struct WritingIndicator: View {
  var body: some View {
    Image(systemName: "progress.indicator")
      .symbolEffect(.variableColor.iterative, options: .repeating)
      .foregroundStyle(.secondary)
      .imageScale(.medium)
  }
}

/// The bar of a selection in the main window when there is no entry line to carry it — the form
/// of a new operation stands at the side instead (`EntryStyle.form`): it floats alone at the
/// bottom of the list, in a container of its own, as wide as what it says, as in the window of
/// Transactions.
struct SelectionDock: View {
  let actions: OperationActions

  var body: some View {
    GlassEffectContainer {
      SelectionBar(actions: actions, hugsContent: true)
    }
    .frame(maxWidth: 560)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}
