import AppCore
import Foundation

/// What the rules and the tags have done to the entry being written: the tags typed in the line
/// and in the panel, what the owner's rules said about it, and the fields the rules filled — so
/// that a line edited further takes back what only a rule had put there. Fields the owner chose
/// are never touched: «ваш выбор в строке > правило > история > модель».
struct EntryRuleState: Equatable {
  /// «#отпуск» words of the line, as typed.
  var lineTags: [String] = []
  /// Tags added in the ↓ panel.
  var panelTags: [String] = []
  /// What the rules say about the entry now.
  var verdict = RuleVerdict()
  /// Rule tags the owner took off in the panel.
  var dismissedTagIds: Set<UUID> = []
  var filled = Filled()

  /// The values the rules put into the draft.
  struct Filled: Equatable {
    var category: UUID?
    var place: UUID?
    var quality: Quality?
    var forWhom: RuleForWhom?
  }

  /// The tags the entry will carry by name: the line's and the panel's, each once.
  var typedTags: [String] {
    var seen: Set<String> = []
    return (lineTags + panelTags).filter { seen.insert(TagName.key($0)).inserted }
  }

  /// The rule tags that stay.
  var ruleTags: [RuledValue<UUID>] {
    verdict.tags.filter { !dismissedTagIds.contains($0.value) }
  }
}

extension EntryDraftModel {
  /// Takes back what the rules put into the draft, if it is still what they put: call before
  /// the line is read again, so history and the model get their say where no rule applies now.
  func retractRules() {
    let filled = ruleState.filled
    guard draft.parts.indices.contains(0) else { return }
    if let category = filled.category, draft.parts[0].categoryId == category,
      draft.parts[0].categorySource == .template
    {
      draft.parts[0].categoryId = nil
      draft.parts[0].categorySource = .manual
    }
    if let place = filled.place, draft.placeId == place { draft.placeId = nil }
    if let quality = filled.quality, draft.parts[0].quality == quality,
      draft.parts[0].qualitySource == .manual
    {
      draft.parts[0].quality = nil
      draft.parts[0].qualitySource = nil
    }
    if let who = filled.forWhom {
      switch who {
      case .group(let group):
        if draft.parts[0].forWhom == group, draft.parts[0].forPersonId == nil {
          draft.parts[0].forWhom = .me
        }
      case .person(let id):
        if draft.parts[0].forPersonId == id { draft.parts[0].forPersonId = nil }
      }
    }
    ruleState.filled = EntryRuleState.Filled()
  }

  /// The facts of the draft the rules read: kind, place, account, card, the amount in rubles
  /// when it is known, the day of the week and the time, the words of the place and the note,
  /// and the category of the first part. Without a rate the amount is left out, and a condition
  /// on the amount does not hold.
  func ruleSubject(calendar: CalendarContext) -> RuleSubject {
    let tree = categoryTree
    let placeName = draft.placeId.flatMap { id in places.first { $0.id == id } }
    var texts: [String] = []
    if let placeName {
      texts.append(placeName.name)
      texts.append(contentsOf: placeName.aliases)
    }
    if let note = draft.note { texts.append(note) }
    let rubles: AmountE4? = {
      guard !draft.amount.isZero else { return nil }
      if draft.currency == .rub { return draft.amount }
      guard let conversion = conversion(of: draft) else { return nil }
      return try? conversion.rubles(draft.amount)
    }()
    let day = calendar.day(of: draft.occurredAt)
    let clock = calendar.timeOfDay(draft.occurredAt)
    let first = draft.parts.first
    var scope: Set<UUID> = []
    if let id = first?.categoryId {
      scope.insert(id)
      if let parent = tree.parent(of: id) { scope.insert(parent.id) }
    }
    return RuleSubject(
      kind: draft.kind, placeId: draft.placeId, accountId: draft.paymentMethodId,
      cardId: draft.cardId, amountRubE4: rubles, weekday: calendar.weekdayIndex(day),
      minuteOfDay: clock.hour * 60 + clock.minute, texts: texts,
      parts: [
        RuleSubject.PartFacts(
          partId: nil, categoryScope: scope, text: NameKey.fold(first?.note ?? ""))
      ])
  }

  /// Reads the draft against the rules and fills what the owner has not chosen. New operations
  /// only: a saved one is never touched by a rule.
  func applyRules(_ rules: [Rule], lineTags: [String], calendar: CalendarContext) {
    ruleState.lineTags = lineTags
    guard !editsSavedOperation, !rules.isEmpty, transfer == nil else {
      ruleState.verdict = RuleVerdict()
      return
    }
    let verdict = RuleEngine.evaluate(ruleSubject(calendar: calendar), rules: rules, tree: categoryTree)
    ruleState.verdict = verdict
    guard draft.parts.indices.contains(0) else { return }
    var filled = EntryRuleState.Filled()
    // A goal contribution stays in Goals, a debt payment where the debt puts it, a refund where
    // its purchase was, money back has no category: the rules of the past leave these alone
    // (`BulkEditRule`), and so do the rules of the line. The verdict still names the rule.
    let part = draft.parts[0]
    let protected =
      isGoalContribution(part) || part.goalId != nil || draft.debtId != nil
      || refundTarget != nil || part.refundOfPartId != nil || draft.kind == .reimbursement

    if let place = verdict.place, draft.placeId == nil,
      places.contains(where: { $0.id == place.value })
    {
      draft.placeId = place.value
      filled.place = place.value
    }
    if let category = verdict.category, !protected, isRuleFillable(category.value) {
      let part = draft.parts[0]
      let theirs = part.categorySource != .manual || part.categoryId == nil
      if theirs, part.categoryId != category.value {
        if categoryTree.parent(of: category.value) != nil {
          setSubcategory(category.value, forPartAt: 0, source: .template)
        } else {
          setCategory(category.value, forPartAt: 0, source: .template)
        }
      }
      if draft.parts[0].categoryId == category.value, draft.parts[0].categorySource == .template {
        filled.category = category.value
      }
    }
    if let quality = verdict.quality, !protected, hasQuality,
      draft.parts[0].qualitySource != .manual
    {
      draft.parts[0].quality = quality.value
      draft.parts[0].qualitySource = .manual
      filled.quality = quality.value
    }
    if let who = verdict.forWhom, !protected, has(.forWhom), !draft.parts[0].reimbursable,
      draft.parts[0].forWhom == .me, draft.parts[0].forPersonId == nil
    {
      switch who.value {
      case .group(let group) where group != .me:
        draft.parts[0].forWhom = group
        filled.forWhom = who.value
      case .person(let id) where people.contains(where: { $0.id == id }):
        draft.parts[0].forPersonId = id
        filled.forWhom = who.value
      default: break
      }
    }
    ruleState.filled = filled
  }

  /// A category a rule may put into the draft: one the pickers offer for this kind.
  private func isRuleFillable(_ id: UUID) -> Bool {
    guard let category = categoryTree[id], !category.archived,
      categoryTree.systemRole(of: id) == nil
    else { return false }
    return category.kind == draft.kind.categoryKind
  }

  /// Adds a tag typed in the panel («#отпуск» or «отпуск»); whether it was a tag at all.
  @discardableResult
  func addPanelTag(_ text: String) -> Bool {
    guard let name = TagName.normalized(text) else { return false }
    let key = TagName.key(name)
    guard !ruleState.typedTags.contains(where: { TagName.key($0) == key }) else { return true }
    ruleState.panelTags.append(name)
    return true
  }

  func removePanelTag(_ name: String) {
    let key = TagName.key(name)
    ruleState.panelTags.removeAll { TagName.key($0) == key }
  }

  /// A rule tag the owner does not want on this operation.
  func dismissRuleTag(_ id: UUID) { ruleState.dismissedTagIds.insert(id) }
}
