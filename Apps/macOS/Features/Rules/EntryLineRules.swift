import AppCore
import Foundation

/// The line with its «#tags» taken out before it is read: the parser never sees them, so a tag
/// is neither a place nor a word of the note.
struct TaggingInterpreter: LineInterpreter {
  let base: any LineInterpreter

  func read(_ text: String, today: DateOnly, kind: TransactionKind?) -> InputLineReading {
    base.read(TagText.extract(from: text).text, today: today, kind: kind)
  }
}

/// The rules seen from the entry line, before Enter: what they say about the line as typed, in a
/// single sentence under it. Nothing is written by looking.
@MainActor
enum EntryLineRules {
  /// The facts of a line, from what the parser read of it and, where the line is silent about
  /// the account or the card, from the draft of the panel.
  static func subject(
    reading: InputLineReading, noteWords: String, places: [UUID: Place],
    fallback: TransactionDraft?, tree: CategoryTree, calendar: CalendarContext, now: Date
  ) -> RuleSubject {
    let parsed = reading.parsed
    let day = parsed.date ?? calendar.day(of: now)
    let clock = reading.timeOfDay ?? calendar.timeOfDay(now)
    var texts: [String] = []
    if let place = parsed.placeId.flatMap({ places[$0] }) {
      texts.append(place.name)
      texts.append(contentsOf: place.aliases)
    }
    if !parsed.note.isEmpty { texts.append(parsed.note) }
    if !noteWords.isEmpty { texts.append(noteWords) }
    var rubles: AmountE4?
    if let amount = parsed.amount, parsed.currency == nil || parsed.currency == .rub {
      rubles = try? AmountE4(decimal: amount)
    }
    var scope: Set<UUID> = []
    if let id = fallback?.parts.first?.categoryId {
      scope.insert(id)
      if let parent = tree.parent(of: id) { scope.insert(parent.id) }
    }
    return RuleSubject(
      kind: parsed.kind, placeId: parsed.placeId,
      accountId: parsed.paymentMethodId ?? fallback?.paymentMethodId,
      cardId: parsed.cardId ?? (parsed.withoutCard ? nil : fallback?.cardId),
      amountRubE4: rubles, weekday: calendar.weekdayIndex(day),
      minuteOfDay: clock.hour * 60 + clock.minute, texts: texts,
      parts: [RuleSubject.PartFacts(partId: nil, categoryScope: scope, text: "")])
  }

  /// One line for under the entry line: «По правилу «Пятёрочка»: Продукты · #еда». `nil` when no
  /// rule applies. The rules that matched are named in the order of the list.
  static func hint(
    _ verdict: RuleVerdict, rules: [Rule], wording: RuleWording
  ) -> String? {
    guard !verdict.matchedRuleIds.isEmpty else { return nil }
    var results: [String] = []
    if let category = verdict.category { results.append(wording.names.category(category.value)) }
    if let place = verdict.place { results.append(wording.names.places[place.value] ?? "?") }
    if let quality = verdict.quality { results.append(wording.qualityName(quality.value)) }
    if let who = verdict.forWhom {
      switch who.value {
      case .group(let group): results.append(wording.environment.label(for: group))
      case .person(let id): results.append(wording.names.people[id] ?? "?")
      }
    }
    for tag in verdict.tags { results.append("#" + (wording.names.tags[tag.value] ?? "?")) }
    guard !results.isEmpty else { return nil }
    let named = verdict.matchedRuleIds.compactMap { id in rules.first { $0.id == id } }
      .map { "«" + wording.title($0) + "»" }
    return RulesText.format(
      "entryrule.hint", wording.environment, named.joined(separator: ", "),
      results.joined(separator: " · "))
  }

  /// The tags typed in the line, for the caption: «#отпуск #турция».
  static func tagsCaption(_ names: [String]) -> String? {
    names.isEmpty ? nil : names.map { "#" + $0 }.joined(separator: " ")
  }
}

extension TransactionsStore {
  /// Puts tags on the parts of a saved operation as one step of ⌘Z: the typed names (made when
  /// the dictionary has none of the name) and the tags the rules named.
  @discardableResult
  public func tag(
    parts partIds: [UUID], names: [String], ruleTagIds: [UUID], file: String = #fileID
  ) -> Bool {
    guard !refuses("tag(parts:names:ruleTagIds:)", file), let spending, !isWritingInBackground
    else { return false }
    do {
      let before = try spending.tagBook()
      var (after, ids) = before.resolving(names: names)
      for id in ruleTagIds where after.tag(id) != nil && !ids.contains(id) { ids.append(id) }
      guard !ids.isEmpty, !partIds.isEmpty else { return true }
      for part in partIds { after.links += after.attaching(ids, to: part) }
      guard after != before else { return true }
      let applied = try spending.apply(TagEdit(before: before, after: after))
      record(
        Landed(step: .spending(.tagEdit(applied)), write: StoreWrite(planningChanged: true)))
      return true
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }
}
