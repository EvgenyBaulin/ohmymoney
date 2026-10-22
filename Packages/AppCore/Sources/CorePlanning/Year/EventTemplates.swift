import CoreKit
import Foundation

/// One article of the budget of an event (the stored form of a future table
/// `event_budget_items`: `id`, `event_id`, `title`, `planned_e4`, `sort`). Every article has
/// its own planned sum; the sums add up to the budget of the event.
public struct EventBudgetItem: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var eventId: UUID
  public var title: String
  public var plannedE4: AmountE4
  public var sort: Int

  public init(
    id: UUID = UUID(), eventId: UUID, title: String, plannedE4: AmountE4, sort: Int = 0
  ) {
    self.id = id
    self.eventId = eventId
    self.title = title
    self.plannedE4 = plannedE4
    self.sort = sort
  }

  enum CodingKeys: String, CodingKey {
    case id
    case eventId = "event_id"
    case title
    case plannedE4 = "planned_e4"
    case sort
  }
}

/// One article of a template: a share of the budget.
public struct EventTemplateLine: Hashable, Sendable, Codable {
  /// For a built-in template a string-catalog key (`event.template.moving.movers`); for the
  /// owner's own, the text they wrote.
  public var title: String
  /// Share of the budget in basis points; the shares of a template add up to 10 000.
  public var shareBp: Int

  public init(title: String, shareBp: Int) {
    self.title = title
    self.shareBp = shareBp
  }
}

/// A type of big event with its usual articles: «Переезд — грузчики, аренда авто, коробки,
/// залог, первый месяц».
public struct EventTemplate: Identifiable, Hashable, Sendable, Codable {
  /// `builtin.moving` … for the ready ones, a UUID string for the owner's.
  public var id: String
  /// A catalog key for a built-in template, the owner's text for their own.
  public var name: String
  public var isBuiltIn: Bool
  public var eventKind: EventKind
  /// The budget the template starts with; the owner changes it when they use it.
  public var totalE4: AmountE4
  public var lines: [EventTemplateLine]

  public init(
    id: String, name: String, isBuiltIn: Bool, eventKind: EventKind = .other,
    totalE4: AmountE4, lines: [EventTemplateLine]
  ) {
    self.id = id
    self.name = name
    self.isBuiltIn = isBuiltIn
    self.eventKind = eventKind
    self.totalE4 = totalE4
    self.lines = lines
  }

  enum CodingKeys: String, CodingKey {
    case id, name
    case isBuiltIn = "built_in"
    case eventKind = "event_kind"
    case totalE4 = "total_e4"
    case lines
  }

  /// The articles for an event with this budget (the template's own when `total` is `nil`):
  /// every share rounded and the last one taking what is left, so the articles always add up
  /// to the budget exactly. `localize` turns the catalog key of a built-in title into text; an
  /// owner's own title is left as it is.
  public func items(
    eventId: UUID, total: AmountE4? = nil, localize: (String) -> String = { $0 }
  ) -> [EventBudgetItem] {
    let budget = total ?? totalE4
    let weights = lines.map { AmountE4(raw: Int64($0.shareBp)) }
    let whole = AmountE4.sum(weights)
    let sums = budget.allocated(proportionallyTo: weights, outOf: whole)
    return lines.indices.map { index in
      EventBudgetItem(
        eventId: eventId, title: isBuiltIn ? localize(lines[index].title) : lines[index].title,
        plannedE4: sums[index], sort: index)
    }
  }
}

public enum EventTemplates {
  /// The four ready templates, in the order they are offered. Titles are string-catalog keys.
  /// The totals are only a place to start (what the example of the plan names for a move; the
  /// rest alike in size) and the owner types their own.
  public static let builtIn: [EventTemplate] = [
    EventTemplate(
      id: "builtin.moving", name: "event.template.moving", isBuiltIn: true,
      totalE4: AmountE4(whole: 150_000),
      lines: shares(
        "event.template.moving",
        [
          ("movers", 2_000), ("car", 1_500), ("boxes", 500), ("deposit", 3_500),
          ("firstMonth", 2_500),
        ])),
    EventTemplate(
      id: "builtin.wedding", name: "event.template.wedding", isBuiltIn: true,
      totalE4: AmountE4(whole: 500_000),
      lines: shares(
        "event.template.wedding",
        [
          ("venue", 3_500), ("catering", 3_000), ("attire", 1_000), ("photo", 1_000),
          ("decor", 700), ("rings", 500), ("other", 300),
        ])),
    EventTemplate(
      id: "builtin.renovation", name: "event.template.renovation", isBuiltIn: true,
      totalE4: AmountE4(whole: 300_000),
      lines: shares(
        "event.template.renovation",
        [
          ("materials", 4_500), ("work", 3_500), ("furniture", 1_200), ("delivery", 300),
          ("reserve", 500),
        ])),
    EventTemplate(
      id: "builtin.admission", name: "event.template.admission", isBuiltIn: true,
      eventKind: .other, totalE4: AmountE4(whole: 200_000),
      lines: shares(
        "event.template.admission",
        [
          ("tuition", 6_000), ("fees", 500), ("housing", 2_000), ("books", 700), ("travel", 800),
        ])),
  ]

  private static func shares(_ prefix: String, _ rows: [(String, Int)]) -> [EventTemplateLine] {
    rows.map { EventTemplateLine(title: "\(prefix).\($0.0)", shareBp: $0.1) }
  }

  public static func builtIn(id: String) -> EventTemplate? {
    builtIn.first { $0.id == id }
  }

  /// «Сохранить как шаблон»: the owner's template from an event's articles. The shares follow
  /// the planned sums (the last takes what is left, so they add up to 10 000); with no sums at
  /// all the articles share equally. `nil` without any article.
  public static func saving(
    name: String, items: [EventBudgetItem], id: UUID = UUID()
  ) -> EventTemplate? {
    let sorted = items.sorted { ($0.sort, $0.title) < ($1.sort, $1.title) }
    guard !sorted.isEmpty else { return nil }
    let total = AmountE4.sum(sorted.map(\.plannedE4))
    let whole = AmountE4(raw: 10_000)
    let weights =
      total.raw > 0
      ? sorted.map(\.plannedE4) : sorted.map { _ in AmountE4(raw: 1) }
    let basis = whole.allocated(
      proportionallyTo: weights, outOf: total.raw > 0 ? total : AmountE4(raw: Int64(sorted.count)))
    return EventTemplate(
      id: id.uuidString, name: name, isBuiltIn: false, totalE4: total,
      lines: sorted.indices.map {
        EventTemplateLine(title: sorted[$0].title, shareBp: Int(basis[$0].raw))
      })
  }
}

/// The owner's templates in the exchange file between devices: JSON under the key
/// `eventTemplates` of the archive's `settings.json`, versioned so a newer file is skipped by
/// an older app instead of misread. Built-in templates never travel: every device has them.
public struct EventTemplateFile: Hashable, Sendable, Codable {
  public static let settingsKey = "eventTemplates"
  public static let formatVersion = 1

  public var formatVersion: Int
  public var templates: [EventTemplate]

  public init(templates: [EventTemplate]) {
    self.formatVersion = Self.formatVersion
    self.templates = templates.filter { !$0.isBuiltIn }
  }

  enum CodingKeys: String, CodingKey {
    case formatVersion = "format_version"
    case templates
  }

  /// Stable bytes: sorted keys, templates in the order given.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  /// The owner's templates of a file; `nil` for a file of a newer format, an empty list for
  /// no templates. Throws for text that is not this file at all. A template with a share total
  /// other than 10 000 or no articles is dropped.
  public static func templates(from data: Data) throws -> [EventTemplate]? {
    let file = try JSONDecoder().decode(EventTemplateFile.self, from: data)
    guard file.formatVersion <= Self.formatVersion else { return nil }
    return file.templates.filter { template in
      !template.isBuiltIn && !template.lines.isEmpty
        && template.lines.reduce(0) { $0 + $1.shareBp } == 10_000
    }
  }

  /// `existing` with `incoming` merged in by id: a template already there is replaced by the
  /// incoming one, a new one is added; built-in ones are never touched.
  public static func merge(existing: [EventTemplate], incoming: [EventTemplate]) -> [EventTemplate]
  {
    var result = existing
    for template in incoming where !template.isBuiltIn {
      if let index = result.firstIndex(where: { $0.id == template.id }) {
        result[index] = template
      } else {
        result.append(template)
      }
    }
    return result
  }
}
