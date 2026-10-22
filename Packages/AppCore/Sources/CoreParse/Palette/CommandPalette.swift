import CoreKit
import Foundation

/// What a line of the palette is.
public enum PaletteKind: String, Hashable, Sendable, Codable, CaseIterable {
  /// Does something: «Новый долг», «Пересчитать».
  case command
  /// Opens a screen: «Календарь», «Капитал».
  case screen
  /// Opens a thing of the owner's: an account, a debt, a goal, a category, a person.
  case account
  case debt
  case goal
  case category
  case person

  /// Commands first, then screens, then the things: the order of a list that has to
  /// settle ties.
  var weight: Int {
    switch self {
    case .command: 30
    case .screen: 20
    case .account: 14
    case .debt, .goal: 12
    case .category, .person: 10
    }
  }
}

/// One line of the palette. `id` is stable and never shown: it is what the recent list keeps,
/// and what the app maps back to an action. Every command also has a menu item of the same
/// name, so the owner can give it a shortcut in the system settings.
public struct PaletteEntry: Hashable, Sendable, Codable {
  public var id: String
  public var kind: PaletteKind
  /// The key of the title in the string catalogue; `%@` stands for `argument`.
  public var titleKey: String
  /// The name of the account, debt, goal, category or person.
  public var argument: String?
  /// The id of the thing the line opens.
  public var subjectId: UUID?
  /// The titles as they are found, in both languages, so «сбер» and «reconcile sber» both
  /// find «Сверить Сбер…».
  public var searchTitles: [String]

  public init(
    id: String, kind: PaletteKind, titleKey: String, argument: String? = nil,
    subjectId: UUID? = nil, searchTitles: [String]
  ) {
    self.id = id
    self.kind = kind
    self.titleKey = titleKey
    self.argument = argument
    self.subjectId = subjectId
    self.searchTitles = searchTitles
  }
}

/// A named thing the palette can open.
public struct PaletteNamed: Hashable, Sendable {
  public var id: UUID
  public var name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

/// What ⌘K can reach, beyond the fixed commands: accounts, debts, goals, categories and
/// people to open — not operations, which ⌘F finds.
public struct PaletteSource: Hashable, Sendable {
  public var accounts: [PaletteNamed]
  public var debts: [PaletteNamed]
  public var goals: [PaletteNamed]
  public var categories: [PaletteNamed]
  public var people: [PaletteNamed]

  public init(
    accounts: [PaletteNamed] = [], debts: [PaletteNamed] = [], goals: [PaletteNamed] = [],
    categories: [PaletteNamed] = [], people: [PaletteNamed] = []
  ) {
    self.accounts = accounts
    self.debts = debts
    self.goals = goals
    self.categories = categories
    self.people = people
  }
}

/// The fixed commands and screens, with their words in both languages.
public enum PaletteCatalog {
  struct Fixed {
    var id: String
    var kind: PaletteKind
    var russian: String
    var english: String
  }

  static let fixed: [Fixed] = [
    Fixed(
      id: "command.newOperation", kind: .command, russian: "Новая операция",
      english: "New operation"),
    Fixed(id: "command.newDebt", kind: .command, russian: "Новый долг", english: "New debt"),
    Fixed(id: "command.newGoal", kind: .command, russian: "Новая цель", english: "New goal"),
    Fixed(
      id: "command.newTransfer", kind: .command, russian: "Перевод между счетами",
      english: "Transfer between accounts"),
    Fixed(
      id: "command.reconcile", kind: .command, russian: "Сверка счёта",
      english: "Reconcile an account"),
    Fixed(
      id: "command.askQuestion", kind: .command, russian: "Задать вопрос о своих данных",
      english: "Ask about my data"),
    Fixed(id: "command.recompute", kind: .command, russian: "Пересчитать", english: "Recompute"),
    Fixed(id: "command.export", kind: .command, russian: "Экспорт", english: "Export"),
    Fixed(
      id: "command.checkForUpdates", kind: .command, russian: "Проверить обновления",
      english: "Check for updates"),
    Fixed(
      id: "command.openSettings", kind: .command, russian: "Открыть настройки",
      english: "Open settings"),
    Fixed(id: "screen.overview", kind: .screen, russian: "Обзор", english: "Overview"),
    Fixed(id: "screen.operations", kind: .screen, russian: "Операции", english: "Operations"),
    Fixed(id: "screen.calendar", kind: .screen, russian: "Календарь", english: "Calendar"),
    Fixed(id: "screen.capital", kind: .screen, russian: "Капитал", english: "Capital"),
    Fixed(id: "screen.planning", kind: .screen, russian: "Планирование", english: "Planning"),
    Fixed(id: "screen.debts", kind: .screen, russian: "Долги", english: "Debts"),
    Fixed(id: "screen.analytics", kind: .screen, russian: "Аналитика", english: "Analytics"),
    Fixed(id: "screen.reports", kind: .screen, russian: "Отчёты", english: "Reports"),
  ]

  /// The fixed entries, in the order the menu shows them.
  public static var fixedEntries: [PaletteEntry] {
    fixed.map {
      PaletteEntry(
        id: $0.id, kind: $0.kind, titleKey: "palette." + $0.id,
        searchTitles: [$0.russian, $0.english])
    }
  }

  /// Every fixed command is a menu item as well (so the owner can bind a shortcut to it in
  /// the system keyboard settings): these are their ids, in order.
  public static var menuCommandIds: [String] {
    fixed.filter { $0.kind == .command }.map(\.id)
  }

  /// The whole list: the fixed entries and, for each account, «open», «reconcile» and
  /// «transfer from»; for each debt, goal, category and person, «open».
  public static func entries(for source: PaletteSource) -> [PaletteEntry] {
    var entries = fixedEntries
    func add(
      _ items: [PaletteNamed], kind: PaletteKind, _ verb: String, russian: String,
      english: String
    ) {
      for item in items {
        entries.append(
          PaletteEntry(
            id: "\(kind.rawValue).\(verb).\(item.id.uuidString)", kind: kind,
            titleKey: "palette.\(kind.rawValue).\(verb)", argument: item.name,
            subjectId: item.id,
            searchTitles: [
              russian.replacingOccurrences(of: "%@", with: item.name),
              english.replacingOccurrences(of: "%@", with: item.name),
            ]))
      }
    }
    add(
      source.accounts, kind: .account, "open", russian: "Открыть счёт %@",
      english: "Open account %@")
    add(
      source.accounts, kind: .account, "reconcile", russian: "Сверить %@…", english: "Reconcile %@…"
    )
    add(
      source.accounts, kind: .account, "transfer", russian: "Перевод со счёта %@…",
      english: "Transfer from %@…")
    add(source.debts, kind: .debt, "open", russian: "Открыть долг %@", english: "Open debt %@")
    add(source.goals, kind: .goal, "open", russian: "Открыть цель %@", english: "Open goal %@")
    add(
      source.categories, kind: .category, "open", russian: "Открыть категорию %@",
      english: "Open category %@")
    add(
      source.people, kind: .person, "open", russian: "Открыть человека %@",
      english: "Open person %@")
    return entries
  }
}

/// The last commands the owner ran, newest first, at most five. Kept on this Mac only
/// (`palette.recent`): it is a habit, not data.
public struct PaletteRecents: Hashable, Sendable, Codable {
  public static let limit = 5
  public static let settingsKey = "palette.recent"

  public private(set) var ids: [String]

  public init(ids: [String] = []) {
    var seen = Set<String>()
    self.ids = Array(ids.filter { seen.insert($0).inserted }.prefix(Self.limit))
  }

  /// This command was just run: it goes first, the oldest falls off.
  public func recording(_ id: String) -> PaletteRecents {
    PaletteRecents(ids: [id] + ids)
  }

  /// Without what no longer exists: an account closed since.
  public func keeping(existing entries: [PaletteEntry]) -> PaletteRecents {
    let known = Set(entries.map(\.id))
    return PaletteRecents(ids: ids.filter(known.contains))
  }

  public var json: String {
    let data = (try? JSONEncoder().encode(self)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  public init(json: String?) {
    let decoded = json.flatMap {
      try? JSONDecoder().decode(PaletteRecents.self, from: Data($0.utf8))
    }
    self = decoded ?? PaletteRecents()
  }
}

/// The entries with their titles already split into words: build it once when the palette
/// opens, search it on every keystroke.
public struct PaletteIndex: Sendable {
  public let entries: [PaletteEntry]
  /// Per entry, per title, the folded words.
  let words: [[[String]]]
  private let positions: [String: Int]

  public init(_ entries: [PaletteEntry]) {
    self.entries = entries
    self.words = entries.map { $0.searchTitles.map(QuestionWords.tokens) }
    var positions: [String: Int] = [:]
    for (index, entry) in entries.enumerated() where positions[entry.id] == nil {
      positions[entry.id] = index
    }
    self.positions = positions
  }

  func entry(withId id: String) -> PaletteEntry? { positions[id].map { entries[$0] } }
}

public enum CommandPalette {
  /// The lines for a query. An empty query shows the recent commands first and then the
  /// fixed ones; a typed one shows what matches, the recent ones a little higher.
  public static func search(
    _ query: String, in entries: [PaletteEntry], recents: PaletteRecents = PaletteRecents(),
    limit: Int = 30
  ) -> [PaletteEntry] {
    search(query, in: PaletteIndex(entries), recents: recents, limit: limit)
  }

  public static func search(
    _ query: String, in index: PaletteIndex, recents: PaletteRecents = PaletteRecents(),
    limit: Int = 30
  ) -> [PaletteEntry] {
    let tokens = QuestionWords.tokens(query)
    if tokens.isEmpty {
      let recent = recents.ids.compactMap { index.entry(withId: $0) }
      let seen = Set(recent.map(\.id))
      let rest = index.entries.filter {
        ($0.kind == .command || $0.kind == .screen) && !seen.contains($0.id)
      }
      return Array((recent + rest).prefix(limit))
    }
    var scored: [(score: Int, entry: PaletteEntry)] = []
    for (position, entry) in index.entries.enumerated() {
      guard let score = score(tokens, index.words[position]) else { continue }
      var total = score + entry.kind.weight
      if let recent = recents.ids.firstIndex(of: entry.id) {
        total += 25 - 3 * recent
      }
      scored.append((total, entry))
    }
    scored.sort { left, right in
      if left.score != right.score { return left.score > right.score }
      let leftTitle = left.entry.searchTitles.first ?? ""
      let rightTitle = right.entry.searchTitles.first ?? ""
      if leftTitle != rightTitle { return leftTitle < rightTitle }
      return left.entry.id < right.entry.id
    }
    return Array(scored.prefix(limit).map(\.entry))
  }

  /// Every typed word must be found at the start of a word of a title (or be the same word
  /// in another case); `nil` when one is not. Whole words score higher than beginnings, and
  /// words found in the order typed higher than the same words out of order.
  static func score(_ tokens: [String], _ titles: [[String]]) -> Int? {
    var best: Int?
    for words in titles {
      var total = 0
      var lastPosition = -1
      var inOrder = true
      var matchedAll = true
      for token in tokens {
        var bestWord: (points: Int, position: Int)?
        // Another form of a word begins with the same letter: only then is the costlier
        // comparison worth making.
        let longToken = token.count >= 4
        let firstScalar = token.unicodeScalars.first
        for (position, word) in words.enumerated() {
          let points: Int
          if word == token {
            points = 30
          } else if word.utf8.starts(with: token.utf8) {
            points = 20
          } else if longToken, word.unicodeScalars.first == firstScalar,
            QuestionResolver.wordsMatch(token, word)
          {
            points = 15
          } else {
            continue
          }
          if bestWord == nil || points > bestWord!.points { bestWord = (points, position) }
        }
        guard let bestWord else {
          matchedAll = false
          break
        }
        total += bestWord.points
        if bestWord.position < lastPosition { inOrder = false }
        lastPosition = bestWord.position
      }
      guard matchedAll else { continue }
      if inOrder { total += 10 }
      // A title that is only what was typed beats a longer one that contains it.
      total -= max(0, words.count - tokens.count)
      if best == nil || total > best! { best = total }
    }
    return best
  }
}
