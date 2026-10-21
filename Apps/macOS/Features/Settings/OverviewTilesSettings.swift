import AppCore
import SwiftUI

/// Settings → «Оформление» → «Плитки обзора»: how Overview lays out its tiles. The rows go group
/// by group — «Деньги», «План», «Анализ» in the owner's order — each group's name above its
/// tiles. A tile is dragged with the mouse onto the row whose place it takes, in its group or in
/// another one, or onto a group's name to go first in that group; a group is dragged by its name
/// onto another group's name (`draggable` and `dropDestination`: the grouped form of macOS is
/// drawn by SwiftUI, not a table, and `onMove` would do nothing in it). The box of a tile shows or
/// hides it — a hidden tile keeps its place — and the last tile shown cannot be hidden. VoiceOver
/// moves a tile by the actions «Выше», «Ниже» and «Перенести в «…»» of its row, and a group by
/// «Группу выше» and «Группу ниже», as there are no arrows to press. A preference of the owner's,
/// like the theme: kept in `UserDefaults`, carried by the transfer archive, not a step of ⌘Z. The
/// same layout is edited on Overview itself («Изменить»).
struct OverviewTilesSection: View {
  @Dependency(\.environment) private var environment
  /// The row a dragged tile or group is over: it is shaded where the drop will land.
  @State private var targeted: String?

  var body: some View {
    let layout = environment.overviewLayout
    Section {
      ForEach(layout.groups) { group in
        groupRow(group, layout)
        ForEach(layout.tiles(in: group)) { tile in
          tileRow(tile, layout)
        }
      }
    } header: {
      Text(verbatim: t("settings.tiles"))
        .accessibilityIdentifier("settings.tiles")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text(
          verbatim: environment.format(
            "settings.tiles.count", table: "Settings", layout.shown.count,
            OverviewTile.allCases.count)
        )
        .monospacedDigit()
        Text(verbatim: t("settings.tiles.hint"))
          .fixedSize(horizontal: false, vertical: true)
        Button(t("settings.tiles.reset")) { OverviewTilesActions.reset(environment) }
          .disabled(layout.isStandard)
      }
      .appFont(.callout)
      .foregroundStyle(.secondary)
    }
  }

  /// The name of a group: dragged to reorder the groups, a place to drop a tile (it goes first)
  /// or another group (it takes this one's place).
  private func groupRow(_ group: OverviewTileGroup, _ layout: OverviewLayout) -> some View {
    let key = "group:" + group.rawValue
    return HStack(spacing: 8) {
      Text(verbatim: OverviewTileText.groupName(of: group, environment))
        .appFont(.headline)
      Spacer()
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.tertiary)
        .help(t("settings.tiles.groupDrag"))
        .accessibilityHidden(true)
    }
    .padding(.top, layout.groups.first == group ? 0 : 6)
    .contentShape(Rectangle())
    .background { shade(key) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
    .accessibilityIdentifier("settings.tiles.group.\(group.rawValue)")
    .accessibilityActions {
      ForEach(OverviewTilesActions.groupMoves(environment, group), id: \.self) { step in
        Button(t(step < 0 ? "settings.tiles.groupUp" : "settings.tiles.groupDown")) {
          OverviewTilesActions.moveGroup(environment, group, by: step)
        }
      }
    }
    .draggable(OverviewTilesActions.payload(of: group)) {
      Text(verbatim: OverviewTileText.groupName(of: group, environment)).padding(6)
    }
    .dropDestination(for: String.self) { payloads, _ in
      payloads.contains { OverviewTilesActions.drop(environment, $0, onto: group) }
    } isTargeted: {
      target(key, $0)
    }
  }

  /// A tile: its box and its name, a grip that says it can be dragged, the actions for VoiceOver
  /// where the tile can go, and the same moves to another group in its context menu.
  private func tileRow(_ tile: OverviewTile, _ layout: OverviewLayout) -> some View {
    let name = OverviewTileText.name(of: tile, environment)
    let key = "tile:" + tile.rawValue
    return HStack(spacing: 8) {
      Toggle(
        isOn: Binding(
          get: { !layout.isHidden(tile) },
          set: { _ in OverviewTilesActions.toggle(environment, tile) })
      ) {
        Text(verbatim: name)
      }
      .toggleStyle(.checkbox)
      .disabled(!OverviewTilesActions.canSwitch(environment, tile))
      .accessibilityIdentifier("settings.tiles.\(tile.rawValue)")
      .accessibilityActions {
        ForEach(OverviewTilesActions.moves(environment, tile, amongShown: false), id: \.self) {
          step in
          Button(t(step < 0 ? "settings.entry.moveUp" : "settings.entry.moveDown")) {
            OverviewTilesActions.move(environment, tile, by: step, amongShown: false)
          }
        }
        ForEach(OverviewTilesActions.otherGroups(environment, tile)) { group in
          Button(moveToTitle(group)) { OverviewTilesActions.move(environment, tile, to: group) }
        }
      }
      Spacer()
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.tertiary)
        .help(t("settings.tiles.drag"))
        .accessibilityHidden(true)
    }
    .padding(.leading, 12)
    .contentShape(Rectangle())
    .background { shade(key) }
    .contextMenu {
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
      return OverviewTilesActions.drop(environment, dragged, onto: tile)
    } isTargeted: {
      target(key, $0)
    }
  }

  @ViewBuilder
  private func shade(_ key: String) -> some View {
    if targeted == key {
      RoundedRectangle(cornerRadius: 4).fill(.quaternary)
    }
  }

  private func target(_ key: String, _ isTargeted: Bool) {
    if isTargeted {
      targeted = key
    } else if targeted == key {
      targeted = nil
    }
  }

  private func moveToTitle(_ group: OverviewTileGroup) -> String {
    environment.format(
      "settings.tiles.moveTo", table: "Settings", OverviewTileText.groupName(of: group, environment)
    )
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }
}

/// What the section and the editing on Overview do, apart from the views so a test reads it
/// without a window. Every change is written at once (`AppEnvironment.overviewLayout`), and
/// Overview lays its groups out again.
@MainActor
enum OverviewTilesActions {
  // MARK: Showing and hiding

  /// Whether the box of `tile` can change: a hidden tile can always be shown again, a shown one
  /// hidden unless it is the last one shown.
  static func canSwitch(_ environment: AppEnvironment, _ tile: OverviewTile) -> Bool {
    let layout = environment.overviewLayout
    return layout.isHidden(tile) || layout.canHide(tile)
  }

  /// Shows a hidden tile at its place or hides a shown one. Returns whether the layout changed —
  /// the last tile shown is refused, and nothing is written.
  @discardableResult
  static func toggle(_ environment: AppEnvironment, _ tile: OverviewTile) -> Bool {
    let layout = environment.overviewLayout
    return layout.isHidden(tile) ? show(environment, tile) : hide(environment, tile)
  }

  /// Hides `tile`; `false` for the last tile shown or one hidden already.
  @discardableResult
  static func hide(_ environment: AppEnvironment, _ tile: OverviewTile) -> Bool {
    guard let changed = environment.overviewLayout.hiding(tile) else { return false }
    environment.overviewLayout = changed
    return true
  }

  /// Shows a hidden `tile` again at its place in its group; `false` when it is shown.
  @discardableResult
  static func show(_ environment: AppEnvironment, _ tile: OverviewTile) -> Bool {
    guard let changed = environment.overviewLayout.showing(tile) else { return false }
    environment.overviewLayout = changed
    return true
  }

  // MARK: Dragging

  /// What a dragged row or tile carries: the tile, marked as one, so text dragged in from
  /// elsewhere is never read as a tile.
  static func payload(of tile: OverviewTile) -> String {
    tilePrefix + tile.rawValue
  }

  /// What a dragged group carries.
  static func payload(of group: OverviewTileGroup) -> String {
    groupPrefix + group.rawValue
  }

  /// The tile a dragged row carries; nil for anything else dropped.
  static func tile(_ payload: String) -> OverviewTile? {
    guard payload.hasPrefix(tilePrefix) else { return nil }
    return OverviewTile(rawValue: String(payload.dropFirst(tilePrefix.count)))
  }

  /// The group a dragged group carries; nil for anything else dropped.
  static func group(_ payload: String) -> OverviewTileGroup? {
    guard payload.hasPrefix(groupPrefix) else { return nil }
    return OverviewTileGroup(rawValue: String(payload.dropFirst(groupPrefix.count)))
  }

  private static let tilePrefix = "ohmymoney.overview.tile:"
  private static let groupPrefix = "ohmymoney.overview.group:"

  /// `tile` dropped onto `target`: it takes the target's place, in the target's group. Returns
  /// whether the drop was taken — onto itself nothing moves.
  @discardableResult
  static func drop(
    _ environment: AppEnvironment, _ tile: OverviewTile, onto target: OverviewTile
  ) -> Bool {
    write(environment, environment.overviewLayout.dropping(tile, onto: target))
  }

  /// Something dropped onto the name of `group`: a tile goes first in the group, a group takes
  /// its place. Returns whether the drop was taken.
  @discardableResult
  static func drop(
    _ environment: AppEnvironment, _ payload: String, onto group: OverviewTileGroup
  ) -> Bool {
    let layout = environment.overviewLayout
    if let tile = tile(payload) {
      return write(environment, layout.moving(tile, to: group, at: 0))
    }
    if let dragged = Self.group(payload) {
      return write(environment, layout.droppingGroup(dragged, onto: group))
    }
    return false
  }

  // MARK: Moving by steps, for VoiceOver

  /// «Выше» (`by: -1`) or «Ниже» (`by: 1`) in the group of `tile`; on Overview, where hidden
  /// tiles are not seen, past them (`amongShown`).
  @discardableResult
  static func move(
    _ environment: AppEnvironment, _ tile: OverviewTile, by step: Int, amongShown: Bool
  ) -> Bool {
    guard let changed = environment.overviewLayout.moving(tile, by: step, amongShown: amongShown)
    else { return false }
    return write(environment, changed)
  }

  /// The moves VoiceOver offers on `tile`, as steps: −1 for «Выше», 1 for «Ниже» — only where the
  /// tile can go in its group.
  static func moves(
    _ environment: AppEnvironment, _ tile: OverviewTile, amongShown: Bool
  ) -> [Int] {
    [-1, 1].filter {
      environment.overviewLayout.neighbour(of: tile, by: $0, amongShown: amongShown) != nil
    }
  }

  /// «Перенести в «…»»: `tile` goes to the end of `group`.
  @discardableResult
  static func move(
    _ environment: AppEnvironment, _ tile: OverviewTile, to group: OverviewTileGroup
  ) -> Bool {
    guard environment.overviewLayout.group(of: tile) != group else { return false }
    return write(environment, environment.overviewLayout.moving(tile, to: group))
  }

  /// The groups `tile` can be moved to: every group but its own, in their order.
  static func otherGroups(
    _ environment: AppEnvironment, _ tile: OverviewTile
  ) -> [OverviewTileGroup] {
    let layout = environment.overviewLayout
    return layout.groups.filter { $0 != layout.group(of: tile) }
  }

  /// «Группу выше» (`by: -1`) or «Группу ниже» (`by: 1`).
  @discardableResult
  static func moveGroup(
    _ environment: AppEnvironment, _ group: OverviewTileGroup, by step: Int
  ) -> Bool {
    guard let changed = environment.overviewLayout.movingGroup(group, by: step) else {
      return false
    }
    return write(environment, changed)
  }

  /// The moves VoiceOver offers on a group: −1 and 1 where it can go.
  static func groupMoves(_ environment: AppEnvironment, _ group: OverviewTileGroup) -> [Int] {
    [-1, 1].filter { environment.overviewLayout.movingGroup(group, by: $0) != nil }
  }

  // MARK: The rest

  /// «Сбросить»: every tile shown, the twelve cards of the first Overview first, every tile in
  /// its default group, the groups in their first order.
  static func reset(_ environment: AppEnvironment) {
    environment.overviewLayout = .standard
  }

  /// Collapses an open group of Overview or opens a collapsed one — a habit of this Mac.
  static func toggleCollapsed(_ environment: AppEnvironment, _ group: OverviewTileGroup) {
    if environment.overviewCollapsed.contains(group) {
      environment.overviewCollapsed.remove(group)
    } else {
      environment.overviewCollapsed.insert(group)
    }
  }

  /// Writes `layout` when it differs; whether it did.
  private static func write(_ environment: AppEnvironment, _ layout: OverviewLayout) -> Bool {
    guard layout != environment.overviewLayout else { return false }
    environment.overviewLayout = layout
    return true
  }
}
