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
  /// The tiles the owner hid, and the self-showing ones waiting for their data (`auto`).
  public private(set) var hidden: Set<OverviewTile>
  /// The tiles that are compact: one figure and a caption, two to a cell when paired.
  public private(set) var compact: Set<OverviewTile>
  /// Who stands beside whom: every pair twice, once from each side. Both are compact, in one
  /// group, next to each other.
  public private(set) var partners: [OverviewTile: OverviewTile]
  /// Hidden tiles that show themselves as soon as their function has data
  /// (`OverviewCatalogItem.showsItself`) — hidden for an older build, which does not know them.
  /// A tile the owner hides or adds by hand leaves this set.
  public private(set) var auto: Set<OverviewTile>

  /// A layout from any sections and hidden tiles, made whole (`normalized`).
  public init(
    sections: [Section], hidden: Set<OverviewTile> = [], compact: Set<OverviewTile> = [],
    partners: [OverviewTile: OverviewTile] = [:], auto: Set<OverviewTile> = []
  ) {
    self.sections = sections
    self.hidden = hidden
    self.compact = compact
    self.partners = partners
    self.auto = auto
    normalize()
  }

  /// The same layout with other sections and hidden tiles: the sizes, pairs and self-showing
  /// marks stay, and `normalize` drops what no longer holds.
  private func rebuilt(sections: [Section], hidden: Set<OverviewTile>? = nil) -> OverviewLayout {
    OverviewLayout(
      sections: sections, hidden: hidden ?? self.hidden, compact: compact, partners: partners,
      auto: auto)
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

  /// The layout of a new person: the ten tiles of the answer, the self-showing ones waiting for
  /// their data, everything else one «Добавить плитку» away.
  public static let firstRun: OverviewLayout = {
    let chosen = OverviewCatalog.firstRunTiles
    let sections = OverviewTileGroup.allCases.map { group in
      let first = chosen.filter { $0.defaultGroup == group }
      let rest = OverviewTile.allCases.filter { $0.defaultGroup == group && !first.contains($0) }
      return Section(group: group, tiles: first + rest)
    }
    return OverviewLayout(
      sections: sections, hidden: Set(OverviewTile.allCases).subtracting(chosen),
      auto: Set(OverviewTile.allCases.filter { OverviewCatalog.showsItself($0) }))
  }()

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

  // MARK: - What the screen shows

  /// Whether the screen shows `tile` with `facts`: a tile that is not hidden, or a self-showing
  /// one whose function has data.
  public func isVisible(_ tile: OverviewTile, facts: OverviewFacts) -> Bool {
    if !hidden.contains(tile) { return true }
    return auto.contains(tile)
      && OverviewCatalog.item(of: tile)?.isVisibleByItself(facts) == true
  }

  /// The tiles of `group` the screen shows with `facts`, in their order.
  public func visibleTiles(in group: OverviewTileGroup, facts: OverviewFacts) -> [OverviewTile] {
    tiles(in: group).filter { isVisible($0, facts: facts) }
  }

  /// What «Добавить плитку» offers with `facts`: the tiles the screen does not show, group
  /// after group.
  public func addable(facts: OverviewFacts) -> [OverviewTile] {
    sections.flatMap { $0.tiles.filter { !isVisible($0, facts: facts) } }
  }

  /// A tile waits for its data and shows itself then.
  public func showsItself(_ tile: OverviewTile) -> Bool { auto.contains(tile) }

  // MARK: - Size and pairs

  /// The tile is compact, alone or in a pair.
  public func isCompact(_ tile: OverviewTile) -> Bool { compact.contains(tile) }

  /// The tile beside `tile` in a pair.
  public func partner(of tile: OverviewTile) -> OverviewTile? { partners[tile] }

  /// «Компактная» or «Обычная»; `nil` for a tile that cannot be compact when asked to be. Making
  /// a tile regular parts its pair, both going back to regular.
  public func setting(_ tile: OverviewTile, compact makeCompact: Bool) -> OverviewLayout? {
    if makeCompact {
      guard OverviewCatalog.canBeCompact(tile) else { return nil }
      guard !compact.contains(tile) else { return self }
      var layout = self
      layout.compact.insert(tile)
      return layout
    }
    guard compact.contains(tile) else { return self }
    return unpairing(tile)
  }

  /// Two compact tiles in one cell: `tile` goes right after `target`, in its group, and both
  /// become compact; either one's earlier partner is left alone, compact. `nil` when either
  /// cannot be compact.
  public func pairing(_ tile: OverviewTile, with target: OverviewTile) -> OverviewLayout? {
    guard tile != target, OverviewCatalog.canBeCompact(tile),
      OverviewCatalog.canBeCompact(target)
    else { return nil }
    var layout = self
    layout.compact.formUnion([tile, target])
    layout.unlink(tile)
    layout.unlink(target)
    let group = layout.group(of: target)
    let at = layout.tiles(in: group).firstIndex(of: target) ?? 0
    layout = layout.moving(tile, to: group, at: at + 1)
    layout.compact.formUnion([tile, target])
    layout.partners[tile] = target
    layout.partners[target] = tile
    layout.normalize()
    return layout.partners[tile] == target ? layout : nil
  }

  /// «Разъединить»: the pair of `tile` falls apart and both go back to regular size; `self` when
  /// it has no partner and is regular.
  public func unpairing(_ tile: OverviewTile) -> OverviewLayout {
    var layout = self
    let other = layout.partners[tile]
    layout.unlink(tile)
    layout.compact.remove(tile)
    if let other { layout.compact.remove(other) }
    layout.normalize()
    return layout
  }

  private mutating func unlink(_ tile: OverviewTile) {
    if let other = partners[tile] { partners[other] = nil }
    partners[tile] = nil
  }

  /// The tiles of `group` the screen shows with `facts`, as the cells they stand in: a tile
  /// alone, or two tiles of a pair — when both are shown; a pair with one tile hidden leaves the
  /// other as a compact tile alone.
  public func cells(in group: OverviewTileGroup, facts: OverviewFacts) -> [Cell] {
    var cells: [Cell] = []
    var taken: Set<OverviewTile> = []
    for tile in visibleTiles(in: group, facts: facts) where !taken.contains(tile) {
      taken.insert(tile)
      if let other = partners[tile], isVisible(other, facts: facts), !taken.contains(other) {
        taken.insert(other)
        cells.append(.pair(tile, other))
      } else {
        cells.append(.single(tile))
      }
    }
    return cells
  }

  /// A place of a grid: one tile, or two compact tiles sharing it.
  public enum Cell: Hashable, Sendable {
    case single(OverviewTile)
    case pair(OverviewTile, OverviewTile)

    public var tiles: [OverviewTile] {
      switch self {
      case .single(let tile): [tile]
      case .pair(let a, let b): [a, b]
      }
    }
  }

  // MARK: - Hiding and showing

  /// Whether `tile` can be hidden: it is shown, and it is not the last one shown.
  public func canHide(_ tile: OverviewTile) -> Bool {
    if auto.contains(tile) { return true }
    return !hidden.contains(tile) && shown.count > 1
  }

  /// The layout with `tile` hidden where it stands; `nil` when it cannot be — the last tile shown
  /// stays, so Overview is never left empty.
  public func hiding(_ tile: OverviewTile) -> OverviewLayout? {
    guard canHide(tile) else { return nil }
    var layout = self
    layout.hidden.insert(tile)
    layout.auto.remove(tile)
    return layout
  }

  /// The layout with `tile` shown again at its place in its group; `nil` when it is shown.
  public func showing(_ tile: OverviewTile) -> OverviewLayout? {
    guard hidden.contains(tile) else { return nil }
    var layout = self
    layout.hidden.remove(tile)
    layout.auto.remove(tile)
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
    return rebuilt(sections: sections, hidden: Set(OverviewTile.allCases).subtracting(listed))
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
    return rebuilt(sections: sections)
  }

  /// `tile` dragged onto `target`: it takes the target's place, in the target's group. In one
  /// group the target moves one place towards where the tile came from — dragged down the tile
  /// lands after it, dragged up before it; from another group the tile goes in before it. A tile
  /// dropped on itself leaves the layout as it was.
  public func dropping(_ tile: OverviewTile, onto target: OverviewTile) -> OverviewLayout {
    guard tile != target else { return self }
    // A compact tile dropped on a compact one makes a pair with it.
    if compact.contains(tile), compact.contains(target),
      let paired = pairing(tile, with: target)
    {
      return paired
    }
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
    return rebuilt(sections: sections)
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
    return rebuilt(sections: sections)
  }

  // MARK: - The text

  /// The mark of a hidden tile in the text.
  private static let hiddenMark: Character = "-"

  /// The layout as the setting keeps it.
  ///
  /// The sizes, the pairs and the self-showing tiles come after the groups, each in a part of
  /// its own — `compact:a,b;pairs:c+d;auto:e` —, written only when there is something to say. A
  /// build that does not know them skips the parts and reads the groups as before.
  public func encode() -> String {
    var parts = sections.map { section in
      section.group.rawValue + ":"
        + section.tiles.map { (hidden.contains($0) ? "-" : "") + $0.rawValue }
        .joined(separator: ",")
    }
    let order = sections.flatMap(\.tiles)
    let single = order.filter { compact.contains($0) && partners[$0] == nil }
    if !single.isEmpty {
      parts.append(Self.compactPart + ":" + single.map(\.rawValue).joined(separator: ","))
    }
    var pairs: [String] = []
    var seen: Set<OverviewTile> = []
    for tile in order where !seen.contains(tile) {
      guard let other = partners[tile] else { continue }
      seen.formUnion([tile, other])
      pairs.append(tile.rawValue + "+" + other.rawValue)
    }
    if !pairs.isEmpty { parts.append(Self.pairsPart + ":" + pairs.joined(separator: ",")) }
    let waiting = order.filter { auto.contains($0) }
    if !waiting.isEmpty {
      parts.append(Self.autoPart + ":" + waiting.map(\.rawValue).joined(separator: ","))
    }
    return parts.joined(separator: ";")
  }

  private static let compactPart = "compact"
  private static let pairsPart = "pairs"
  private static let autoPart = "auto"

  /// The layout a kept text says; `nil` for no text, or a text that names no known group — then
  /// the list of the builds before groups is read instead (`init(tiles:)`).
  public static func decode(_ stored: String?) -> OverviewLayout? {
    guard let stored else { return nil }
    var sections: [Section] = []
    var hidden: Set<OverviewTile> = []
    // A tile named again — in its group or another — is passed over whole: the first mention
    // gives both its place and whether it is hidden.
    var named: Set<OverviewTile> = []
    var compact: Set<OverviewTile> = []
    var partners: [OverviewTile: OverviewTile] = [:]
    var auto: Set<OverviewTile> = []
    for part in stored.split(separator: ";", omittingEmptySubsequences: true) {
      let halves = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      let head = halves[0].trimmingCharacters(in: .whitespaces)
      if [compactPart, pairsPart, autoPart].contains(head) {
        let words = halves.count > 1 ? halves[1].split(separator: ",") : []
        for word in words {
          let names = word.split(separator: "+").map {
            OverviewTile(rawValue: $0.trimmingCharacters(in: .whitespaces))
          }
          switch head {
          case compactPart:
            if let first = names.first, let tile = first { compact.insert(tile) }
          case autoPart:
            if let first = names.first, let tile = first { auto.insert(tile) }
          default:
            if names.count == 2, let a = names[0], let b = names[1], a != b,
              partners[a] == nil, partners[b] == nil
            {
              partners[a] = b
              partners[b] = a
            }
          }
        }
        continue
      }
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
    return OverviewLayout(
      sections: sections, hidden: hidden, compact: compact, partners: partners, auto: auto)
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
    normalizeSizes()
  }

  /// Sizes and pairs that still hold: only a tile that can be compact is, a pair is two compact
  /// tiles of one group side by side, a tile waits for its data only while it is hidden and
  /// shows itself.
  private mutating func normalizeSizes() {
    compact = compact.filter { OverviewCatalog.canBeCompact($0) }
    var kept: [OverviewTile: OverviewTile] = [:]
    for section in sections {
      for index in section.tiles.indices.dropLast() {
        let a = section.tiles[index]
        let b = section.tiles[index + 1]
        guard partners[a] == b, partners[b] == a, OverviewCatalog.canBeCompact(a),
          OverviewCatalog.canBeCompact(b), kept[a] == nil, kept[b] == nil
        else { continue }
        kept[a] = b
        kept[b] = a
      }
    }
    partners = kept
    compact.formUnion(kept.keys)
    auto = auto.filter { hidden.contains($0) && OverviewCatalog.showsItself($0) }
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
