import AppCore
import SwiftUI

extension OverviewTileText {
  static func groupNameKey(of group: OverviewTileGroup) -> String {
    "overview.group.\(group.rawValue)"
  }

  /// «Деньги», «План», «Анализ».
  static func groupName(of group: OverviewTileGroup, _ environment: AppEnvironment) -> String {
    environment.language(groupNameKey(of: group), table: table)
  }
}

/// What Overview itself is doing with its tiles: shown as they are — a click on a tile opens
/// «Почему так» — or edited («Изменить»), when tiles and groups are dragged, hidden and added back
/// and a click opens nothing. Apart from the view so a test drives it without a window.
@MainActor
@Observable
final class OverviewScreen {
  /// «Изменить» is on: the tiles can be dragged, hidden and added back.
  private(set) var isEditing = false
  /// The tile whose «Почему так» is open.
  var why: OverviewTile?

  /// A click on `tile`: «Почему так» opens, except while editing — then nothing does. Returns
  /// whether it opened.
  @discardableResult
  func open(_ tile: OverviewTile) -> Bool {
    guard !isEditing else { return false }
    why = tile
    return true
  }

  /// «Изменить».
  func edit() {
    why = nil
    isEditing = true
  }

  /// «Готово».
  func done() {
    isEditing = false
  }

  /// The groups the screen shows, in the owner's order: outside editing a group with no tile
  /// shown is left out; while editing every group is there, to drop a tile into.
  static func groups(of layout: OverviewLayout, editing: Bool) -> [OverviewTileGroup] {
    editing ? layout.groups : layout.groups.filter { !layout.shownTiles(in: $0).isEmpty }
  }

  /// Whether the tiles of `group` are laid out under its name: unless it is collapsed — and
  /// while editing always, so a tile can be dropped among them.
  static func showsTiles(
    of group: OverviewTileGroup, collapsed: Set<OverviewTileGroup>, editing: Bool
  ) -> Bool {
    editing || !collapsed.contains(group)
  }
}

/// The bar above the tiles: «Последняя запись» at the left, and at the right «Изменить», or while
/// editing «Добавить плитку» (the hidden tiles, a menu) and «Готово».
struct OverviewEditBar: View {
  @Dependency(\.environment) private var environment
  let screen: OverviewScreen

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      LastRecordLine()
      Spacer(minLength: 8)
      if screen.isEditing {
        let hidden = environment.overviewLayout.hiddenInOrder
        Menu {
          ForEach(hidden) { tile in
            Button(OverviewTileText.name(of: tile, environment)) {
              OverviewTilesActions.show(environment, tile)
            }
          }
        } label: {
          Label(t("overview.edit.add"), systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(hidden.isEmpty)
        .accessibilityIdentifier("overview.edit.add")
        Button(t("overview.edit.done")) { screen.done() }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("overview.edit.done")
      } else {
        Button(t("overview.edit")) { screen.edit() }
          .accessibilityIdentifier("overview.edit")
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}

/// The tiles of Overview in their groups: each group's name — a click collapses or opens it — and
/// under it its tiles in rows of `columns`. The cards of a row share its height: every grid is
/// laid out at its natural height, and every card then fills the row it stands in.
struct OverviewGroupedGrid: View {
  @Dependency(\.environment) private var environment
  let columns: Int
  let actions: OperationActions
  let screen: OverviewScreen

  var body: some View {
    let layout = environment.overviewLayout
    let editing = screen.isEditing
    VStack(alignment: .leading, spacing: 14) {
      ForEach(OverviewScreen.groups(of: layout, editing: editing)) { group in
        VStack(alignment: .leading, spacing: 8) {
          OverviewGroupHeader(group: group, screen: screen)
          if OverviewScreen.showsTiles(
            of: group, collapsed: environment.overviewCollapsed, editing: editing)
          {
            let tiles = layout.shownTiles(in: group)
            if tiles.isEmpty {
              OverviewEmptyGroup(group: group)
            } else {
              grid(tiles)
            }
          }
        }
      }
    }
  }

  private func grid(_ tiles: [OverviewTile]) -> some View {
    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
      ForEach(OverviewCard.rows(tiles, columns: columns), id: \.self) { row in
        GridRow {
          ForEach(row) { tile in
            OverviewTileFrame(tile: tile, actions: actions, screen: screen)
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// The name of a group. Outside editing a click collapses or opens the group; while editing it is
/// dragged to reorder the groups and takes a tile (first in the group) or a group (its place).
private struct OverviewGroupHeader: View {
  @Dependency(\.environment) private var environment
  let group: OverviewTileGroup
  let screen: OverviewScreen
  @State private var targeted = false

  var body: some View {
    let name = OverviewTileText.groupName(of: group, environment)
    if screen.isEditing {
      HStack(spacing: 6) {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(verbatim: name)
          .appFont(.headline)
        Spacer()
      }
      .padding(.vertical, 2)
      .contentShape(Rectangle())
      .background {
        if targeted { RoundedRectangle(cornerRadius: 6).fill(.quaternary) }
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("overview.group.\(group.rawValue)")
      .accessibilityActions {
        ForEach(OverviewTilesActions.groupMoves(environment, group), id: \.self) { step in
          Button(t(step < 0 ? "overview.edit.groupUp" : "overview.edit.groupDown")) {
            OverviewTilesActions.moveGroup(environment, group, by: step)
          }
        }
      }
      .draggable(OverviewTilesActions.payload(of: group)) {
        Text(verbatim: name).appFont(.headline).padding(6)
      }
      .dropDestination(for: String.self) { payloads, _ in
        payloads.contains { OverviewTilesActions.drop(environment, $0, onto: group) }
      } isTargeted: {
        targeted = $0
      }
    } else {
      let collapsed = environment.overviewCollapsed.contains(group)
      Button {
        withAnimation(.snappy) { OverviewTilesActions.toggleCollapsed(environment, group) }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .appFont(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .accessibilityHidden(true)
          Text(verbatim: name)
            .appFont(.headline)
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(.isHeader)
      .accessibilityValue(
        Text(verbatim: t(collapsed ? "overview.group.collapsed" : "overview.group.open"))
      )
      .accessibilityHint(
        Text(verbatim: t(collapsed ? "overview.group.expand" : "overview.group.collapse"))
      )
      .accessibilityIdentifier("overview.group.\(group.rawValue)")
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}

/// A group with no tile shown, while editing: a place to drop a tile into.
private struct OverviewEmptyGroup: View {
  @Dependency(\.environment) private var environment
  let group: OverviewTileGroup
  @State private var targeted = false

  var body: some View {
    Text(verbatim: environment.language("overview.edit.dropHere", table: "Overview"))
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 64)
      .background {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
          .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator))
      }
      .dropDestination(for: String.self) { payloads, _ in
        payloads.contains { OverviewTilesActions.drop(environment, $0, onto: group) }
      } isTargeted: {
        targeted = $0
      }
  }
}

/// One tile of the grid. Outside editing a click on the card — not on a button, a menu or a chart
/// inside it, which keep their own clicks — opens «Почему так», and nothing can be dragged. While
/// editing the card's own controls rest, the tile is dragged onto another tile to take its place,
/// «−» hides it (not the last one shown), and VoiceOver moves it by «Выше», «Ниже» and «Перенести
/// в «…»».
private struct OverviewTileFrame: View {
  @Dependency(\.environment) private var environment
  let tile: OverviewTile
  let actions: OperationActions
  let screen: OverviewScreen
  @State private var targeted = false

  var body: some View {
    if screen.isEditing {
      editing
    } else {
      OverviewCardView(tile: tile, actions: actions)
        .contentShape(Rectangle())
        .onTapGesture { screen.open(tile) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(verbatim: t("overview.why"))) { screen.open(tile) }
    }
  }

  private var editing: some View {
    let name = OverviewTileText.name(of: tile, environment)
    let canHide = environment.overviewLayout.canHide(tile)
    return OverviewCardView(tile: tile, actions: actions)
      .allowsHitTesting(false)
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 4]))
          .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator))
          .contentShape(Rectangle())
      }
      .overlay(alignment: .topLeading) {
        Button {
          _ = withAnimation(.snappy) { OverviewTilesActions.hide(environment, tile) }
        } label: {
          Image(systemName: "minus.circle.fill")
            .appFont(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, canHide ? Color.red : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canHide)
        .help(environment.format("overview.edit.hide", table: "Overview", name))
        .accessibilityLabel(
          Text(verbatim: environment.format("overview.edit.hide", table: "Overview", name))
        )
        .accessibilityIdentifier("overview.edit.hide.\(tile.rawValue)")
        .offset(x: -7, y: -7)
      }
      .contextMenu {
        ForEach(OverviewTilesActions.otherGroups(environment, tile)) { group in
          Button(moveToTitle(group)) { OverviewTilesActions.move(environment, tile, to: group) }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text(verbatim: name))
      .accessibilityActions {
        ForEach(OverviewTilesActions.moves(environment, tile, amongShown: true), id: \.self) {
          step in
          Button(t(step < 0 ? "overview.edit.moveUp" : "overview.edit.moveDown")) {
            OverviewTilesActions.move(environment, tile, by: step, amongShown: true)
          }
        }
        ForEach(OverviewTilesActions.otherGroups(environment, tile)) { group in
          Button(moveToTitle(group)) { OverviewTilesActions.move(environment, tile, to: group) }
        }
      }
      .draggable(OverviewTilesActions.payload(of: tile)) {
        Text(verbatim: name).padding(6)
      }
      .dropDestination(for: String.self) { payloads, _ in
        guard let dragged = payloads.lazy.compactMap(OverviewTilesActions.tile).first
        else { return false }
        return withAnimation(.snappy) {
          OverviewTilesActions.drop(environment, dragged, onto: tile)
        }
      } isTargeted: {
        targeted = $0
      }
  }

  private func moveToTitle(_ group: OverviewTileGroup) -> String {
    environment.format(
      "overview.edit.moveTo", table: "Overview", OverviewTileText.groupName(of: group, environment))
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}
