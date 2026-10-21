import Foundation

/// How Overview lays its tiles out: the three groups in the owner's order, every tile in one of
/// them in the owner's order, and which tiles are hidden. Every tile of the catalog is always in
/// the layout — a hidden one keeps its place in its group and comes back there when it is shown
/// again — and at least one tile is shown.
///
/// Kept as text (`encode`, `decode`) in the setting `overview.layout` and in the transfer
/// archive: `money:monthToDate,-limits,upcoming;plan:event;analysis:topCategories` — the groups
/// in their order, each with its tiles in theirs, a hidden tile marked by «-». Whatever the text
/// says — written by another build, carried from another Mac, edited by hand — it reads as a
/// layout the screen can show: unknown groups and tiles go, a group or a tile named twice keeps
/// its first place, a group not named comes after the named ones, a tile not named is put at
/// the end of its default group — shown, unless it waits to be added (`isShownUnnamed`) —, and a
/// text that hides every tile shows the first one.
public struct OverviewLayout: Hashable, Sendable {
  /// One group and its tiles, the hidden ones among them.
  public struct Section: Hashable, Sendable {
    public var group: OverviewTileGroup
    public var tiles: [OverviewTile]

    public init(group: OverviewTileGroup, tiles: [OverviewTile]) {
      self.group = group
      self.tiles = tiles
    }
  }

  /// The groups in their order, each with every tile it holds.
  public private(set) var sections: [Section]
  /// The tiles the owner hid.
  public private(set) var hidden: Set<OverviewTile>

  /// A layout from any sections and hidden tiles, made whole (`normalized`).
  public init(sections: [Section], hidden: Set<OverviewTile> = []) {
    self.sections = sections
    self.hidden = hidden
    normalize()
  }

  /// The layout of a flat list of tiles — the setting of the builds before groups, or none: the
  /// tiles of the list keep their order, the tiles the list lacks follow in the order of the
  /// catalog, every tile in its default group, and all of them shown but the ones that wait to
  /// be added (`isShownUnnamed`).
  public init(tiles: [OverviewTile]) {
    var ordered: [OverviewTile] = []
    for tile in tiles + OverviewTile.allCases where !ordered.contains(tile) {
      ordered.append(tile)
    }
    self.init(
      sections: OverviewTileGroup.allCases.map { group in
        Section(group: group, tiles: ordered.filter { $0.defaultGroup == group })
      },
      hidden: Set(OverviewTile.allCases.filter { !$0.isShownUnnamed && !tiles.contains($0) }))
  }

  /// The layout of an owner who never chose: the twelve cards of the first Overview first, in
  /// their order, then the rest, each in its default group.
  public static let standard = OverviewLayout(tiles: OverviewTiles.standard)

  /// Nothing to reset: the layout is the standard one.
  public var isStandard: Bool { self == Self.standard }

  // MARK: - Reading

  /// The groups in their order.
  public var groups: [OverviewTileGroup] { sections.map(\.group) }

  /// Every tile of `group`, the hidden ones among them, in their order.
  public func tiles(in group: OverviewTileGroup) -> [OverviewTile] {
    sections.first { $0.group == group }?.tiles ?? []
  }

  /// The tiles of `group` the screen shows, in their order.
  public func shownTiles(in group: OverviewTileGroup) -> [OverviewTile] {
    tiles(in: group).filter { !hidden.contains($0) }
  }

  /// Every tile the screen shows, group after group.
  public var shown: [OverviewTile] {
    sections.flatMap { $0.tiles.filter { !hidden.contains($0) } }
  }

  /// The hidden tiles, group after group: what «Добавить плитку» offers.
  public var hiddenInOrder: [OverviewTile] {
    sections.flatMap { $0.tiles.filter { hidden.contains($0) } }
  }

  /// The group `tile` stands in.
  public func group(of tile: OverviewTile) -> OverviewTileGroup {
    sections.first { $0.tiles.contains(tile) }?.group ?? tile.defaultGroup
  }

  public func isHidden(_ tile: OverviewTile) -> Bool { hidden.contains(tile) }

  // MARK: - Hiding and showing

  /// Whether `tile` can be hidden: it is shown, and it is not the last one shown.
  public func canHide(_ tile: OverviewTile) -> Bool {
    !hidden.contains(tile) && shown.count > 1
  }

  /// The layout with `tile` hidden where it stands; `nil` when it cannot be — the last tile shown
  /// stays, so Overview is never left empty.
  public func hiding(_ tile: OverviewTile) -> OverviewLayout? {
    guard canHide(tile) else { return nil }
    var layout = self
    layout.hidden.insert(tile)
    return layout
  }

  /// The layout with `tile` shown again at its place in its group; `nil` when it is shown.
  public func showing(_ tile: OverviewTile) -> OverviewLayout? {
    guard hidden.contains(tile) else { return nil }
    var layout = self
    layout.hidden.remove(tile)
    return layout
  }

  /// The layout that shows exactly `tiles` — what a flat list of the builds before groups asks
  /// for: every tile keeps its group, the listed tiles of a group come first in the order of the
  /// list, the others follow hidden in their order. An empty list, or one naming no tile, leaves
  /// the layout as it is.
  public func showingOnly(_ tiles: [OverviewTile]) -> OverviewLayout {
    var listed: [OverviewTile] = []
    for tile in tiles where !listed.contains(tile) { listed.append(tile) }
    guard !listed.isEmpty else { return self }
    let sections = sections.map { section in
      Section(
        group: section.group,
        tiles: listed.filter { section.tiles.contains($0) }
          + section.tiles.filter { !listed.contains($0) })
    }
    return OverviewLayout(
      sections: sections, hidden: Set(OverviewTile.allCases).subtracting(listed))
  }

  // MARK: - Moving tiles

  /// The layout with `tile` moved into `group` before the tile at `index` of that group's tiles
  /// (hidden ones counted, `tile` itself counted where it stands now), or at its end when `index`
  /// is `nil` or past it. Hidden or shown, the tile stays so.
  public func moving(
    _ tile: OverviewTile, to group: OverviewTileGroup, at index: Int? = nil
  ) -> OverviewLayout {
    guard var target = sections.firstIndex(where: { $0.group == group }) else { return self }
    var sections = sections
    var position = index.map { min(max($0, 0), sections[target].tiles.count) }
    if let from = sections[target].tiles.firstIndex(of: tile), let wanted = position,
      from < wanted
    {
      position = wanted - 1
    }
    for index in sections.indices {
      sections[index].tiles.removeAll { $0 == tile }
    }
    target = sections.firstIndex(where: { $0.group == group }) ?? target
    let at = min(position ?? sections[target].tiles.count, sections[target].tiles.count)
    sections[target].tiles.insert(tile, at: at)
    return OverviewLayout(sections: sections, hidden: hidden)
  }

  /// `tile` dragged onto `target`: it takes the target's place, in the target's group. In one
  /// group the target moves one place towards where the tile came from — dragged down the tile
  /// lands after it, dragged up before it; from another group the tile goes in before it. A tile
  /// dropped on itself leaves the layout as it was.
  public func dropping(_ tile: OverviewTile, onto target: OverviewTile) -> OverviewLayout {
    guard tile != target else { return self }
    let group = group(of: target)
    let tiles = tiles(in: group)
    guard let to = tiles.firstIndex(of: target) else { return self }
    if let from = tiles.firstIndex(of: tile), from < to {
      return moving(tile, to: group, at: to + 1)
    }
    return moving(tile, to: group, at: to)
  }

  /// The neighbour `tile` would trade places with by one step (−1 up, 1 down) in its group: the
  /// next tile that way, or the next shown one when `amongShown` — on Overview, where hidden
  /// tiles are not seen. `nil` at the edge of the group.
  public func neighbour(
    of tile: OverviewTile, by step: Int, amongShown: Bool
  ) -> OverviewTile? {
    let group = group(of: tile)
    let tiles = tiles(in: group)
    guard step != 0, var index = tiles.firstIndex(of: tile) else { return nil }
    let direction = step < 0 ? -1 : 1
    repeat {
      index += direction
      guard tiles.indices.contains(index) else { return nil }
    } while amongShown && hidden.contains(tiles[index])
    return tiles[index]
  }

  /// «Выше» (−1) or «Ниже» (1): `tile` trades places with its neighbour in its group; `nil` at
  /// the edge of the group.
  public func moving(_ tile: OverviewTile, by step: Int, amongShown: Bool) -> OverviewLayout? {
    guard let neighbour = neighbour(of: tile, by: step, amongShown: amongShown) else {
      return nil
    }
    let group = group(of: tile)
    guard let at = tiles(in: group).firstIndex(of: neighbour) else { return nil }
    return moving(tile, to: group, at: step < 0 ? at : at + 1)
  }

  // MARK: - Moving groups

  /// The layout with `group` one place up (−1) or down (1); `nil` at the edge.
  public func movingGroup(_ group: OverviewTileGroup, by step: Int) -> OverviewLayout? {
    guard let from = groups.firstIndex(of: group) else { return nil }
    let to = from + (step < 0 ? -1 : 1)
    guard step != 0, sections.indices.contains(to) else { return nil }
    var sections = sections
    sections.swapAt(from, to)
    return OverviewLayout(sections: sections, hidden: hidden)
  }

  /// `group` dragged onto `target`: it takes the target's place, the target moving one place
  /// towards where the group came from. Onto itself nothing moves.
  public func droppingGroup(
    _ group: OverviewTileGroup, onto target: OverviewTileGroup
  ) -> OverviewLayout {
    guard group != target, let from = groups.firstIndex(of: group),
      let to = groups.firstIndex(of: target)
    else { return self }
    var sections = sections
    let section = sections.remove(at: from)
    sections.insert(section, at: to)
    return OverviewLayout(sections: sections, hidden: hidden)
  }

  // MARK: - The text

  /// The mark of a hidden tile in the text.
  private static let hiddenMark: Character = "-"

  /// The layout as the setting keeps it.
  public func encode() -> String {
    sections.map { section in
      section.group.rawValue + ":"
        + section.tiles.map { (hidden.contains($0) ? "-" : "") + $0.rawValue }
        .joined(separator: ",")
    }
    .joined(separator: ";")
  }

  /// The layout a kept text says; `nil` for no text, or a text that names no known group — then
  /// the list of the builds before groups is read instead (`init(tiles:)`).
  public static func decode(_ stored: String?) -> OverviewLayout? {
    guard let stored else { return nil }
    var sections: [Section] = []
    var hidden: Set<OverviewTile> = []
    // A tile named again — in its group or another — is passed over whole: the first mention
    // gives both its place and whether it is hidden.
    var named: Set<OverviewTile> = []
    for part in stored.split(separator: ";", omittingEmptySubsequences: true) {
      let halves = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard
        let group = OverviewTileGroup(
          rawValue: halves[0].trimmingCharacters(in: .whitespaces)),
        !sections.contains(where: { $0.group == group })
      else { continue }
      var tiles: [OverviewTile] = []
      let words = halves.count > 1 ? halves[1].split(separator: ",") : []
      for word in words {
        var name = word.trimmingCharacters(in: .whitespaces)
        let isHidden = name.first == hiddenMark
        if isHidden { name.removeFirst() }
        guard let tile = OverviewTile(rawValue: name.trimmingCharacters(in: .whitespaces)),
          named.insert(tile).inserted
        else { continue }
        tiles.append(tile)
        if isHidden { hidden.insert(tile) }
      }
      sections.append(Section(group: group, tiles: tiles))
    }
    guard !sections.isEmpty else { return nil }
    return OverviewLayout(sections: sections, hidden: hidden)
  }

  /// Makes the layout whole: every group once, the named ones first; every tile once, at its first
  /// place; a tile not placed at the end of its default group, shown unless it waits to be added;
  /// hidden only what is placed;
  /// at least one tile shown — the first one when all were hidden.
  private mutating func normalize() {
    var seenGroups: Set<OverviewTileGroup> = []
    var seenTiles: Set<OverviewTile> = []
    var whole: [Section] = []
    for section in sections where !seenGroups.contains(section.group) {
      seenGroups.insert(section.group)
      var tiles: [OverviewTile] = []
      for tile in section.tiles where !seenTiles.contains(tile) {
        seenTiles.insert(tile)
        tiles.append(tile)
      }
      whole.append(Section(group: section.group, tiles: tiles))
    }
    for group in OverviewTileGroup.allCases where !seenGroups.contains(group) {
      whole.append(Section(group: group, tiles: []))
    }
    var placedLate: Set<OverviewTile> = []
    for tile in OverviewTile.allCases where !seenTiles.contains(tile) {
      if let index = whole.firstIndex(where: { $0.group == tile.defaultGroup }) {
        whole[index].tiles.append(tile)
        placedLate.insert(tile)
      }
    }
    sections = whole
    hidden = hidden.intersection(seenTiles).subtracting(placedLate)
      .union(placedLate.filter { !$0.isShownUnnamed })
    if shown.isEmpty, let first = sections.lazy.flatMap(\.tiles).first {
      hidden.remove(first)
    }
  }

  // MARK: - Collapsed groups

  /// The collapsed groups as the setting `overview.collapsed` of this Mac keeps them: their raw
  /// values in the order of the catalog, joined by commas.
  public static func encodeCollapsed(_ groups: Set<OverviewTileGroup>) -> String {
    OverviewTileGroup.allCases.filter(groups.contains).map(\.rawValue).joined(separator: ",")
  }

  /// The collapsed groups a kept text names; unknown words go, nothing is none.
  public static func decodeCollapsed(_ stored: String?) -> Set<OverviewTileGroup> {
    guard let stored else { return [] }
    return Set(
      stored.split(separator: ",").compactMap {
        OverviewTileGroup(rawValue: $0.trimmingCharacters(in: .whitespaces))
      })
  }
}
