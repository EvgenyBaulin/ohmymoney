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

/// The history survives navigation between screens, so the strip follows the root's store.
/// After undo it keeps the redo button available, including when no earlier undo remains.
struct TouchHistoryBar: View {
  let store: TransactionsStore
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    let actions = TouchHistoryAction.available(in: store)
    if !actions.isEmpty {
      ViewThatFits(in: .horizontal) {
        buttons(actions, vertical: false)
        buttons(actions, vertical: true)
      }
      .padding(6)
      .background(surfaces.card, in: .rect(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12).strokeBorder(surfaces.cardBorder, lineWidth: 0.5)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("history.banner")
    }
  }

  private func buttons(_ actions: [TouchHistoryAction], vertical: Bool) -> some View {
    let layout =
      vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
    return layout {
      ForEach(actions, id: \.self) { action in
        Button {
          action.perform(in: store)
        } label: {
          Label(environment.language(action.titleKey), systemImage: action.symbol)
            .appFont(.callout)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
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
