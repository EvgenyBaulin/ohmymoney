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

  /// «Стоит посмотреть» is no tile of Overview: its full list opens from «Все» of «Что сделать
  /// сейчас». A pair that held it keeps its other tile alone.
  static func withoutWorthALook(_ cells: [OverviewLayout.Cell]) -> [OverviewLayout.Cell] {
    cells.compactMap { cell in
      switch cell {
      case .single(let tile): tile == .worthALook ? nil : cell
      case .pair(let first, let second):
        if first == .worthALook {
          .single(second)
        } else if second == .worthALook {
          .single(first)
        } else {
          cell
        }
      }
    }
  }

  /// The groups the screen shows, in the owner's order: outside editing a group with no tile
  /// shown is left out; while editing every group is there, to drop a tile into.
  static func groups(
    of layout: OverviewLayout, editing: Bool, facts: OverviewFacts = .none
  ) -> [OverviewTileGroup] {
    editing
      ? layout.groups
      : layout.groups.filter {
        layout.visibleTiles(in: $0, facts: facts).contains { $0 != .worthALook }
      }
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
  @Environment(\.overviewEditsInChrome) private var editsInChrome
  let screen: OverviewScreen

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      LastRecordLine()
      Spacer(minLength: 8)
      if screen.isEditing {
        OverviewAddMenu()
        // «Готово» stands in the navigation bar on a phone, beside the title.
        if !editsInChrome {
          Button(t("overview.edit.done")) { screen.done() }
            .buttonStyle(.primaryAction)
            .accessibilityIdentifier("overview.edit.done")
        }
      } else if !editsInChrome {
        // One orange button with words at the right edge, the grey ones before it.
        HStack(spacing: StyleMetrics.headerButtonGap) {
          Button(t("overview.edit")) { screen.edit() }
            .buttonStyle(.quietAction)
            .accessibilityIdentifier("overview.edit")
          Button(t("overview.newOperation")) {
            NotificationCenter.default.post(name: .focusEntryLine, object: nil)
          }
          .buttonStyle(.primaryAction)
          .accessibilityIdentifier("overview.newOperation")
        }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}

/// A place of the grid of Overview: a cell of tiles, or one of the two cards that explain the main
/// card — «Из чего складывается сумма» and «Что сделать сейчас». Those two stand side by side
/// after the tiles of the first group shown, as the design lays them, but are no tiles: they are
/// never dragged, hidden or added.
enum OverviewGridItem: Hashable {
  case cell(OverviewLayout.Cell)
  case freeSumParts
  case doNow

  /// The columns it takes: each of the two cards half of a grid of four with fixed widths
  /// (`halves`), one otherwise.
  static func span(of item: OverviewGridItem, columns: Int, halves: Bool = true) -> Int {
    switch item {
    case .cell(let cell): OverviewCard.span(of: cell, columns: columns, halves: halves)
    case .freeSumParts, .doNow: halves && columns >= OverviewCard.maxColumns ? 2 : 1
    }
  }

  /// The items of a group in rows of `columns`.
  static func rows(
    _ items: [OverviewGridItem], columns: Int, halves: Bool = true
  ) -> [[OverviewGridItem]] {
    OverviewCard.packed(items, columns: columns) {
      span(of: $0, columns: columns, halves: halves)
    }
  }

  /// Which of the two cards stand above the groups and which join the tiles. In one column — the
  /// phone — «Что сделать сейчас» stands right under the main card, as the phone's frame draws
  /// it; otherwise both join the tiles of the first group laid out.
  static func placed(
    _ items: [OverviewGridItem], columns: Int
  ) -> (above: [OverviewGridItem], amongTiles: [OverviewGridItem]) {
    let above = columns == 1 ? items.filter { $0 == .doNow } : []
    return (above, items.filter { !above.contains($0) })
  }

  /// The group the two cards join: the first whose tiles are laid out; `nil` when none is, and
  /// they stand above the groups.
  static func doNowGroup(
    in groups: [OverviewTileGroup], laysOut: (OverviewTileGroup) -> Bool
  ) -> OverviewTileGroup? {
    groups.first(where: laysOut)
  }
}

/// The tiles of Overview in their groups: each group's name — a click collapses or opens it — and
/// under it its tiles in rows of `columns`. The cards of a row share its height: every grid is
/// laid out at its natural height, and every card then fills the row it stands in. Every card in
/// it is a tile of the one style (`CardStyle.tile`).
struct OverviewGroupedGrid: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let columns: Int
  /// The width of the page; each place of the grid is laid out at its share of it — so a tile
  /// is as wide in every group as in the frame, whatever its content asks for. Zero before the
  /// page is measured.
  var width: CGFloat = 0
  let actions: OperationActions
  let screen: OverviewScreen

  /// The gap between groups and under a group's name: 10 on the Mac; 20 and 8 on a phone and a
  /// tablet.
  static var groupGap: CGFloat {
    #if os(iOS)
      20
    #else
      StyleMetrics.stackGap
    #endif
  }
  static var nameGap: CGFloat {
    #if os(iOS)
      8
    #else
      StyleMetrics.stackGap
    #endif
  }

  var body: some View {
    let layout = environment.overviewLayout
    let editing = screen.isEditing
    let facts = OverviewScreen.facts(compute.snapshot)
    let groups = OverviewScreen.groups(of: layout, editing: editing, facts: facts)
    let (above, extras) = OverviewGridItem.placed(
      Self.extras(compute.snapshot, environment), columns: columns)
    let doNowGroup =
      !extras.isEmpty
      ? OverviewGridItem.doNowGroup(in: groups) { group in
        OverviewScreen.showsTiles(
          of: group, collapsed: environment.overviewCollapsed, editing: editing)
          && !OverviewScreen.withoutWorthALook(layout.cells(in: group, facts: facts)).isEmpty
      } : nil
    VStack(alignment: .leading, spacing: Self.groupGap) {
      ForEach(above + (doNowGroup == nil ? extras : []), id: \.self) {
        item($0, fillsHeight: false)
      }
      ForEach(groups) { group in
        VStack(alignment: .leading, spacing: Self.nameGap) {
          OverviewGroupHeader(group: group, screen: screen)
          if OverviewScreen.showsTiles(
            of: group, collapsed: environment.overviewCollapsed, editing: editing)
          {
            let cells = OverviewScreen.withoutWorthALook(layout.cells(in: group, facts: facts))
            if cells.isEmpty {
              OverviewEmptyGroup(group: group)
            } else {
              grid(cells.map(OverviewGridItem.cell) + (group == doNowGroup ? extras : []))
            }
          }
        }
      }
    }
    .environment(\.cardStyle, .tile)
  }

  /// The items in rows of `columns`; a chart or a list takes two columns of four, or a row of
  /// its own in a narrower grid.
  private func grid(_ items: [OverviewGridItem]) -> some View {
    Grid(
      alignment: .topLeading, horizontalSpacing: OverviewCard.columnGap,
      verticalSpacing: OverviewCard.rowGap
    ) {
      ForEach(OverviewGridItem.rows(items, columns: columns, halves: width > 0), id: \.self) {
        row in
        GridRow {
          ForEach(row, id: \.self) { place in
            let span = OverviewGridItem.span(of: place, columns: columns, halves: width > 0)
            item(place, fillsHeight: true)
              .frame(
                width: width > 0
                  ? OverviewCard.width(of: span, in: width, columns: columns) : nil
              )
              .gridCellColumns(span)
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private func item(_ place: OverviewGridItem, fillsHeight: Bool) -> some View {
    switch place {
    case .cell(let cell): OverviewCellView(cell: cell, actions: actions, screen: screen)
    case .freeSumParts: OverviewFreeSumPartsCard(fillsHeight: fillsHeight)
    case .doNow: OverviewDoNowCard(screen: screen, fillsHeight: fillsHeight)
    }
  }

  /// The two cards that explain the main card, each only when it has something to show.
  @MainActor
  static func extras(
    _ snapshot: DataSnapshot?, _ environment: AppEnvironment
  ) -> [OverviewGridItem] {
    guard let snapshot else { return [] }
    var items: [OverviewGridItem] = []
    if FreeSumParts.make(OverviewHeadline.configured(snapshot).free) != nil {
      items.append(.freeSumParts)
    }
    if !OverviewDoNow.list(snapshot: snapshot, environment: environment).isEmpty {
      items.append(.doNow)
    }
    return items
  }
}

/// The name of a group. Outside editing a click collapses or opens the group; while editing it is
/// dragged to reorder the groups and takes a tile (first in the group) or a group (its place).
struct OverviewGroupHeader: View {
  @Dependency(\.environment) private var environment
  let group: OverviewTileGroup
  let screen: OverviewScreen
  @State private var targeted = false

  /// The name of a group is a heading of 15 pt semibold on the phone, as the design draws the
  /// headings of its sections; on the Mac a quiet secondary line of 14 semibold.
  static var nameFont: AppFont {
    #if os(iOS)
      .subheadline.weight(.semibold)
    #else
      StyleType.groupName
    #endif
  }
  static var nameIsPrimary: Bool {
    #if os(iOS)
      true
    #else
      false
    #endif
  }

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
        HStack(spacing: StyleMetrics.groupNameGap) {
          Text(verbatim: name)
            .appFont(Self.nameFont)
            .foregroundStyle(Self.nameIsPrimary ? .primary : .secondary)
          Image(systemName: "chevron.down")
            .appFont(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: StyleMetrics.groupChevron, height: StyleMetrics.groupChevron)
            .rotationEffect(.degrees(collapsed ? -90 : 0))
            .accessibilityHidden(true)
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
struct OverviewTileFrame: View {
  @Dependency(\.environment) private var environment
  let tile: OverviewTile
  let actions: OperationActions
  let screen: OverviewScreen
  @State private var targeted = false

  var body: some View {
    if screen.isEditing {
      editing
    } else {
      OverviewCardView(
        tile: tile, actions: actions, compact: environment.overviewLayout.isCompact(tile)
      )
      .contentShape(Rectangle())
      .onTapGesture { screen.open(tile) }
      .accessibilityElement(children: .contain)
      .accessibilityAction(named: Text(verbatim: t("overview.why"))) { screen.open(tile) }
    }
  }

  private var editing: some View {
    let name = OverviewTileText.name(of: tile, environment)
    let canHide = environment.overviewLayout.canHide(tile)
    return OverviewCardView(
      tile: tile, actions: actions, compact: environment.overviewLayout.isCompact(tile)
    )
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
    .overlay(alignment: .bottomTrailing) {
      if environment.overviewLayout.isCompact(tile) {
        Text(verbatim: t("overview.edit.compactBadge"))
          .appFont(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.quaternary, in: Capsule())
          .padding(6)
          .accessibilityHidden(true)
      }
    }
    .contextMenu {
      OverviewSizeMenu(tile: tile)
      ForEach(OverviewTilesActions.otherGroups(environment, tile)) { group in
        Button(moveToTitle(group)) { OverviewTilesActions.move(environment, tile, to: group) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityActions {
      OverviewSizeMenu(tile: tile)
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
