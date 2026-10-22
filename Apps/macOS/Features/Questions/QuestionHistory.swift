import AppCore
import Foundation

/// The questions the owner asked lately, newest first, so one is asked again with a click.
/// Kept on this Mac only (`questions.history`): it is a habit, not data, and the questions
/// name categories and places, so it is not in the archive or in the exchange files either.
struct QuestionHistory: Hashable, Sendable, Codable {
  static let limit = 20
  static let settingsKey = "questions.history"

  struct Item: Hashable, Sendable, Codable, Identifiable {
    var text: String
    var askedAt: Date

    var id: String { NameKey.fold(text) }
  }

  private(set) var items: [Item]

  init(items: [Item] = []) {
    self.items = Array(Self.settled(items).prefix(Self.limit))
  }

  /// Newest first, a question asked twice kept once (the case and «ё» not counting), blanks
  /// dropped.
  private static func settled(_ items: [Item]) -> [Item] {
    var seen = Set<String>()
    return items.sorted { $0.askedAt > $1.askedAt }.compactMap { item in
      let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, seen.insert(NameKey.fold(text)).inserted else { return nil }
      return Item(text: text, askedAt: item.askedAt)
    }
  }

  /// This question was just asked: it goes first, an older copy of it goes away, the oldest
  /// falls off past the limit.
  func recording(_ text: String, at date: Date) -> QuestionHistory {
    QuestionHistory(items: [Item(text: text, askedAt: date)] + items)
  }

  func removing(_ item: Item) -> QuestionHistory {
    QuestionHistory(items: items.filter { $0.id != item.id })
  }

  static let empty = QuestionHistory()

  var json: String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = (try? encoder.encode(self)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  init(json: String?) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let decoded = json.flatMap { try? decoder.decode(QuestionHistory.self, from: Data($0.utf8)) }
    self = decoded ?? QuestionHistory()
  }
}

/// Where the habits of the palette and the question line are kept: `UserDefaults`, under keys
/// that a data set (demo, sample) gets its own copy of, so a synthetic session never leaves its
/// questions in the owner's list.
enum QuestionsStorage {
  static func key(_ name: String, dataSet: AppPaths.DataSet? = AppPaths.dataSet) -> String {
    dataSet.map { "\(name).\($0.rawValue)" } ?? name
  }

  static func loadHistory(_ defaults: UserDefaults = .standard) -> QuestionHistory {
    QuestionHistory(json: defaults.string(forKey: key(QuestionHistory.settingsKey)))
  }

  static func save(_ history: QuestionHistory, _ defaults: UserDefaults = .standard) {
    defaults.set(history.json, forKey: key(QuestionHistory.settingsKey))
  }

  static func loadRecents(_ defaults: UserDefaults = .standard) -> PaletteRecents {
    PaletteRecents(json: defaults.string(forKey: key(PaletteRecents.settingsKey)))
  }

  static func save(_ recents: PaletteRecents, _ defaults: UserDefaults = .standard) {
    defaults.set(recents.json, forKey: key(PaletteRecents.settingsKey))
  }
}
