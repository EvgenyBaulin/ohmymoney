import AppCore
import SwiftUI

// MARK: - Rows of cells

extension OverviewCard {
  /// The gap between the two cards of a pair: 12 pt on a phone, as the design draws it.
  static var pairSpacing: CGFloat {
    #if os(iOS)
      12
    #else
      8
    #endif
  }

  /// The tiles that take two columns of a grid of four, as the design draws the limits.
  static let doubleTiles: Set<OverviewTile> = [.limits]

  /// How many columns of the grid a cell takes. In a grid of four whose places have fixed widths
  /// (`halves`), a chart, a list and the limits take two, as the design lays them; otherwise a
  /// chart or a list takes the whole width and the limits one — a flexible grid would size a
  /// column two tiles wide by its content and leave the row uneven. Everything else — a tile or a
  /// pair — takes one.
  static func span(of cell: OverviewLayout.Cell, columns: Int, halves: Bool = true) -> Int {
    guard case .single(let tile) = cell else { return 1 }
    if halves, columns >= maxColumns, OverviewCatalog.isWide(tile) || doubleTiles.contains(tile) {
      return 2
    }
    if OverviewCatalog.isWide(tile) { return max(1, columns) }
    return 1
  }

  /// The cells in rows of `columns`: each row is filled in order while the cells' spans fit;
  /// a cell that does not fit begins the next row.
  static func rows(
    _ cells: [OverviewLayout.Cell], columns: Int, halves: Bool = true
  ) -> [[OverviewLayout.Cell]] {
    packed(cells, columns: columns) { span(of: $0, columns: columns, halves: halves) }
  }

  /// The items in rows of `columns` by the columns each takes.
  static func packed<Item>(
    _ items: [Item], columns: Int, span: (Item) -> Int
  ) -> [[Item]] {
    let size = max(1, columns)
    var rows: [[Item]] = []
    var row: [Item] = []
    var used = 0
    for item in items {
      let width = min(size, max(1, span(item)))
      if used + width > size, !row.isEmpty {
        rows.append(row)
        row = []
        used = 0
      }
      row.append(item)
      used += width
      if used == size {
        rows.append(row)
        row = []
        used = 0
      }
    }
    if !row.isEmpty { rows.append(row) }
    return rows
  }
}

extension OverviewScreen {
  /// What the books say about the functions the self-showing tiles hang on; nothing before the
  /// first data arrives.
  @MainActor
  static func facts(_ snapshot: DataSnapshot?) -> OverviewFacts {
    snapshot.map { OverviewFiguresStore.shared.facts(for: $0) } ?? .none
  }
}

// MARK: - A cell

/// A place of the grid: one tile, or two compact tiles side by side. The Mac's debt pair shares
/// one card and a divider; editing keeps each tile's own controls and «Разъединить».
struct OverviewCellView: View {
  @Dependency(\.environment) private var environment
  let cell: OverviewLayout.Cell
  let actions: OperationActions
  let screen: OverviewScreen
  @Environment(\.layoutIdiom) private var idiom
  @Environment(\.appTheme) private var theme

  static func sharesCard(
    _ cell: OverviewLayout.Cell, idiom: LayoutIdiom, editing: Bool
  ) -> Bool {
    guard idiom == .mac, !editing, case .pair(let first, let second) = cell else { return false }
    return Set([first, second]) == Set([OverviewTile.owedToMe, .iOwe])
  }

  var body: some View {
    switch cell {
    case .single(let tile):
      OverviewTileFrame(tile: tile, actions: actions, screen: screen)
    case .pair(let first, let second):
      VStack(alignment: .leading, spacing: 6) {
        if Self.sharesCard(cell, idiom: LayoutIdiom.resolved(idiom), editing: screen.isEditing) {
          HStack(alignment: .top, spacing: StyleMetrics.compactTilePadding) {
            OverviewTileFrame(tile: first, actions: actions, screen: screen, embedded: true)
              .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
              .overlay(theme.borderHairline)
              .accessibilityHidden(true)
              .accessibilityIdentifier("overview.debts.divider")
            OverviewTileFrame(tile: second, actions: actions, screen: screen, embedded: true)
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }
          .fixedSize(horizontal: false, vertical: true)
          .contentCard(fillsHeight: true)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("overview.debts")
        } else {
          HStack(alignment: .top, spacing: OverviewCard.pairSpacing) {
            OverviewTileFrame(tile: first, actions: actions, screen: screen)
            OverviewTileFrame(tile: second, actions: actions, screen: screen)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
        if screen.isEditing {
          HStack(spacing: 6) {
            Image(systemName: "link")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(verbatim: environment.language("overview.edit.pair", table: "Overview"))
              .appFont(.caption)
              .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(environment.language("overview.edit.unpair", table: "Overview")) {
              OverviewTilesActions.unpair(environment, first)
            }
            .controlSize(.small)
            .accessibilityIdentifier("overview.edit.unpair.\(first.rawValue)")
          }
        }
      }
      .accessibilityElement(children: .contain)
    }
  }
}

// MARK: - The size of a tile

/// «Компактная» or «Обычная» and «Разъединить», for a tile that can be compact; nothing for the
/// others.
struct OverviewSizeMenu: View {
  @Dependency(\.environment) private var environment
  let tile: OverviewTile

  var body: some View {
    if OverviewCatalog.canBeCompact(tile) {
      let layout = environment.overviewLayout
      if layout.isCompact(tile) {
        Button(t("overview.edit.sizeRegular")) {
          OverviewTilesActions.setCompact(environment, tile, false)
        }
      } else {
        Button(t("overview.edit.sizeCompact")) {
          OverviewTilesActions.setCompact(environment, tile, true)
        }
      }
      if layout.partner(of: tile) != nil {
        Button(t("overview.edit.unpair")) { OverviewTilesActions.unpair(environment, tile) }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}

// MARK: - Add a tile

/// «Добавить плитку»: the pairs that are good side by side — «Можно ставить рядом» —, the tiles
/// not shown, and the tiles that are not built yet, listed as «в работе» and not to be chosen.
struct OverviewAddMenu: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    let facts = OverviewScreen.facts(compute.snapshot)
    let layout = environment.overviewLayout
    let addable = layout.addable(facts: facts)
    let pairs = OverviewAddMenuContent.pairs(addable: addable)
    Menu {
      if !pairs.isEmpty {
        Section(t("overview.add.pairs")) {
          ForEach(pairs, id: \.id) { pair in
            if let tiles = pair.tiles {
              Button(
                "\(OverviewTileText.name(of: tiles.0, environment)) + \(OverviewTileText.name(of: tiles.1, environment))"
              ) {
                OverviewTilesActions.addPair(environment, tiles.0, tiles.1)
              }
            }
          }
        }
      }
      Section(t("overview.add.single")) {
        ForEach(addable) { tile in
          Button(singleTitle(tile)) { OverviewTilesActions.show(environment, tile) }
        }
      }
      Section(t("overview.add.unbuilt")) {
        ForEach(OverviewCatalog.unbuilt) { item in
          Button(
            "\(environment.language(item.nameKey, table: "Overview")) — \(t("overview.add.inProgress"))"
          ) {}
          .disabled(true)
        }
      }
    } label: {
      Label(t("overview.edit.add"), systemImage: "plus")
    }
    .menuStyle(.button)
    .fixedSize()
    .accessibilityIdentifier("overview.edit.add")
  }

  /// The name of a tile; «— можно ставить рядом» where a pair is suggested for it.
  private func singleTitle(_ tile: OverviewTile) -> String {
    let name = OverviewTileText.name(of: tile, environment)
    guard OverviewCatalog.suggestedPartner(of: tile) != nil else { return name }
    return "\(name) — \(t("overview.add.sideBySide"))"
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}

/// What the menu offers, apart from the view so a test reads it.
enum OverviewAddMenuContent {
  /// The suggested pairs whose both tiles are built and can be added now.
  static func pairs(addable: [OverviewTile]) -> [OverviewPairSuggestion] {
    OverviewCatalog.suggestedPairs.filter { pair in
      guard let tiles = pair.tiles else { return false }
      return addable.contains(tiles.0) && addable.contains(tiles.1)
    }
  }
}

// MARK: - What the owner can do with sizes and pairs

extension OverviewTilesActions {
  /// «Компактная» or «Обычная». Returns whether the layout changed.
  @discardableResult
  static func setCompact(
    _ environment: AppEnvironment, _ tile: OverviewTile, _ compact: Bool
  )
    -> Bool
  {
    guard let changed = environment.overviewLayout.setting(tile, compact: compact),
      changed != environment.overviewLayout
    else { return false }
    environment.overviewLayout = changed
    return true
  }

  /// «Разъединить»: both tiles go back to regular size. Returns whether the layout changed.
  @discardableResult
  static func unpair(_ environment: AppEnvironment, _ tile: OverviewTile) -> Bool {
    let layout = environment.overviewLayout
    guard layout.partner(of: tile) != nil else { return false }
    environment.overviewLayout = layout.unpairing(tile)
    return true
  }

  /// A compact tile onto another compact one. Returns whether they are a pair now.
  @discardableResult
  static func pair(
    _ environment: AppEnvironment, _ tile: OverviewTile, with target: OverviewTile
  )
    -> Bool
  {
    guard let paired = environment.overviewLayout.pairing(tile, with: target) else { return false }
    environment.overviewLayout = paired
    return true
  }

  /// A suggested pair, from «Добавить плитку»: both tiles shown, side by side.
  @discardableResult
  static func addPair(
    _ environment: AppEnvironment, _ first: OverviewTile, _ second: OverviewTile
  )
    -> Bool
  {
    var layout = environment.overviewLayout
    if let shown = layout.showing(first) { layout = shown }
    if let shown = layout.showing(second) { layout = shown }
    guard let paired = layout.pairing(second, with: first) else { return false }
    environment.overviewLayout = paired
    return true
  }
}
