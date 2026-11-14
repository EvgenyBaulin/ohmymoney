import SwiftUI

/// Both touch controls and hardware shortcuts use the store's own history.
enum TouchHistoryAction: CaseIterable, Hashable {
  case undo, redo

  var titleKey: String { self == .undo ? "action.undo" : "action.redo" }
  var symbol: String { self == .undo ? "arrow.uturn.backward" : "arrow.uturn.forward" }
  var modifiers: EventModifiers { self == .undo ? .command : [.command, .shift] }

  @MainActor
  static func available(in store: TransactionsStore) -> [Self] {
    allCases.filter { $0 == .undo ? store.canUndo : store.canRedo }
  }

  @MainActor
  func perform(in store: TransactionsStore) {
    switch self {
    case .undo: store.undo()
    case .redo: store.redo()
    }
  }
}

/// Where the history strip floats: over the content, above the bar of the sections and clear of
/// the round «+» on its right, never in the home-indicator zone and never taking room from the
/// screen under it.
@MainActor
enum TouchHistoryPlacement {
  static let sideMargin: CGFloat = PhoneMetrics.screenMargin
  /// What the strip leaves free at its right for the «+» and its margin.
  static let trailingReserve: CGFloat =
    PhoneEntryButton.diameter + PhoneEntryButton.sideMargin + 8

  /// The room under the strip: the «+»'s own on a phone (so the two stand on one line above the
  /// pill of the bar), above the corner button of a tablet.
  static func bottomInset(
    placement: NavLayout.Placement, barHeight: CGFloat, onPhone: Bool
  ) -> CGFloat {
    onPhone
      ? PhoneEntryButton.bottomPadding(placement: placement, barHeight: barHeight)
      : EntryPlusMetrics.padScrollClearance
  }
}

/// Floats `bar` over the content at the bottom as an overlay: the content keeps its size.
struct FloatingTouchHistory<Bar: View>: ViewModifier {
  let bottomInset: CGFloat
  let onPhone: Bool
  let bar: Bar

  func body(content: Content) -> some View {
    content.overlay(alignment: onPhone ? .bottomLeading : .bottom) {
      bar
        .padding(.leading, onPhone ? TouchHistoryPlacement.sideMargin : 0)
        .padding(.trailing, onPhone ? TouchHistoryPlacement.trailingReserve : 0)
        .padding(.bottom, bottomInset)
    }
  }
}

/// The history survives navigation between screens, so the strip follows the root's store.
/// After undo it keeps the redo button available, including when no earlier undo remains.
struct TouchHistoryBar: View {
  let store: TransactionsStore
  @Dependency(\.environment) private var environment

  var body: some View {
    let actions = TouchHistoryAction.available(in: store)
    if !actions.isEmpty {
      GlassCapsule(insets: EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)) {
        // Named buttons when the room holds them, else the symbols alone (each still named for
        // VoiceOver): the strip is always one row, never taller than the room above the bar.
        ViewThatFits(in: .horizontal) {
          buttons(actions, named: true)
          buttons(actions, named: false)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("history.banner")
    }
  }

  private func buttons(_ actions: [TouchHistoryAction], named: Bool) -> some View {
    HStack(spacing: 4) {
      ForEach(actions, id: \.self) { action in
        Button {
          action.perform(in: store)
        } label: {
          Label(environment.language(action.titleKey), systemImage: action.symbol)
            .labelStyle(.automatic)
            .modifier(HistoryLabelStyle(named: named))
            .appFont(.callout)
            .padding(.horizontal, named ? 12 : 10)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("history.\(action)")
      }
    }
  }
}

struct TouchHistoryShortcuts: View {
  let store: TransactionsStore

  var body: some View {
    ForEach(TouchHistoryAction.allCases, id: \.self) { action in
      Button("") { action.perform(in: store) }
        .keyboardShortcut("z", modifiers: action.modifiers)
        .disabled(!TouchHistoryAction.available(in: store).contains(action))
        .accessibilityHidden(true)
    }
    .opacity(0)
    .frame(width: 0, height: 0)
  }
}

/// The name beside the symbol, or the symbol alone.
private struct HistoryLabelStyle: ViewModifier {
  let named: Bool

  func body(content: Content) -> some View {
    if named {
      content.labelStyle(.titleAndIcon)
    } else {
      content.labelStyle(.iconOnly)
    }
  }
}
