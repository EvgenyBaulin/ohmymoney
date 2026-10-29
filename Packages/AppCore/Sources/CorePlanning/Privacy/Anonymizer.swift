import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The neutral words that take the place of the owner's names, one stem per kind: «Человек 1»,
/// «Место 2», «Событие 3».
public struct AnonymizerLabels: Hashable, Sendable {
  public var person: String
  public var place: String
  public var event: String
  public var account: String
  public var bank: String
  public var accountGroup: String
  public var card: String
  public var goal: String
  public var debt: String
  public var debtGroup: String
  public var asset: String
  public var ownedItem: String
  public var wish: String
  public var shoppingItem: String
  public var tag: String
  public var rule: String
  public var scheduledPayment: String
  public var expectedIncome: String
  public var dayNote: String
  public var eventItem: String
  public var eventTemplate: String
  public var ruleText: String

  public static let russian = AnonymizerLabels(
    person: "Человек", place: "Место", event: "Событие", account: "Счёт", bank: "Банк",
    accountGroup: "Группа счетов", card: "Карта", goal: "Цель", debt: "Долг",
    debtGroup: "Группа долга", asset: "Имущество", ownedItem: "Вещь", wish: "Желание",
    shoppingItem: "Покупка", tag: "Метка", rule: "Правило", scheduledPayment: "Платёж",
    expectedIncome: "Поступление", dayNote: "Заметка", eventItem: "Статья",
    eventTemplate: "Шаблон", ruleText: "Текст")

  public static let english = AnonymizerLabels(
    person: "Person", place: "Place", event: "Event", account: "Account", bank: "Bank",
    accountGroup: "Account group", card: "Card", goal: "Goal", debt: "Debt",
    debtGroup: "Debt group", asset: "Asset", ownedItem: "Item", wish: "Wish",
    shoppingItem: "Purchase", tag: "Tag", rule: "Rule", scheduledPayment: "Payment",
    expectedIncome: "Income", dayNote: "Note", eventItem: "Line", eventTemplate: "Template",
    ruleText: "Text")
}

/// The copy of the data that can be shown to somebody else: every word the owner wrote is
/// replaced, every number stays.
///
/// **What changes** — the free text and the names:
/// * operations: the description, the place of the warranty, the statement's own key and
///   hash; an outside key (a bank's reference) is dropped, the keys the app writes
///   (`sched:`, `alloc:` …) stay; parts: the comment;
/// * people (name, aliases, birthday, gift budget), places and events (name, aliases),
///   accounts, banks, groups of accounts, cards (name, aliases, last four digits, comment);
/// * goals, debts (name, comment, the groups and descriptions of the journal), what the loans
///   cost (name), assets and their valuations, owned things, wishes (name, link, comment),
///   the shopping list, tags, rules (name and the text a rule looks for), the day notes;
/// * scheduled payments (name, cancel link), expected incomes (name), the articles and own
///   templates of events, the notes of bank conditions, the reminder text for a debtor;
/// * transfers: the comment and an outside key; the words the model was taught
///   (`feedback`) are cleared; the dismissed anomalies and the saved filters and reports are
///   dropped altogether — their text names things.
///
/// **What does not change** — sums, dates, currencies, rates, kinds, categories (the tree is
/// the app's, not a name of a person), grades, links between records (every id stays, so a
/// part still points at the same operation, person and event), the amount's expression,
/// settings that are numbers.
///
/// Numbers go by the order of the records in the data, so the same data always gives the same
/// copy. The original is a value and is never touched.
public enum Anonymizer {
  /// The places of the data this copy looks after, for a test and for the report to the
  /// owner. Anything not named here is a number, a date, a link or a token.
  public static let coveredFields: [String] = [
    "transaction.note", "transaction.warrantyWhere", "transaction.dedupKey",
    "transaction.externalId (outside keys)", "part.note",
    "person.name", "person.aliases", "person.birthday", "person.giftBudget",
    "place.name", "place.aliases", "event.name", "paymentMethod.name", "paymentMethod.aliases",
    "bank.name", "accountGroup.name", "card.name", "card.aliases", "card.last4", "card.details",
    "goal.name", "debt.name", "debt.note", "debtEntry.groupName", "debtEntry.description",
    "debtEntry.note", "debtCost.name", "asset.name", "asset.note", "assetValuation.note",
    "ownedItem.name", "ownedItem.note", "wish.name", "wish.url", "wish.note",
    "shoppingItem.name", "shoppingItem.note", "tag.name", "rule.name", "rule.textContains",
    "dayNote.text", "scheduledPayment.name", "scheduledPayment.cancelURL",
    "expectedIncome.name", "eventBudgetItem.title", "eventTemplate.name (own)",
    "eventTemplate.lines.title (own)", "bankConditions.note", "debtSettings.nudgeTemplate",
    "transfer.note", "transfer.externalId (outside keys)", "feedback.text",
    "dismissals (dropped)", "savedViews (dropped)",
  ]

  /// The prefixes of the keys the app itself writes into `external_id`; nothing of the
  /// owner's is in them but ids.
  static let ownKeyPrefixes = [
    "sched:", "reimb:", "reconcile:", "transfer:", "writeoff:", "debtinterest:", "debtmarkup:",
    "debtcost:", "instreturn:", "pledgeloss:", "ccinterest:", "npd:", "tax:", "alloc:",
  ]

  static func ownKey(_ key: String?) -> String? {
    guard let key, ownKeyPrefixes.contains(where: key.hasPrefix) else { return nil }
    return key
  }

  public static func apply(
    to dataset: Dataset, labels: AnonymizerLabels = .russian
  ) -> Dataset {
    var d = dataset

    // Operations and their parts.
    for index in d.entries.indices {
      d.entries[index].transaction.note = nil
      d.entries[index].transaction.warrantyWhere = nil
      d.entries[index].transaction.dedupKey = nil
      d.entries[index].transaction.externalId = ownKey(d.entries[index].transaction.externalId)
      for part in d.entries[index].parts.indices { d.entries[index].parts[part].note = nil }
    }

    // Reference books.
    for (number, index) in d.people.indices.enumerated() {
      d.people[index].name = name(labels.person, number)
      d.people[index].aliases = []
      d.people[index].birthday = nil
      d.people[index].giftBudgetE4 = nil
    }
    for (number, index) in d.places.indices.enumerated() {
      d.places[index].name = name(labels.place, number)
      d.places[index].aliases = []
    }
    for (number, index) in d.events.indices.enumerated() {
      d.events[index].name = name(labels.event, number)
    }
    for (number, index) in d.paymentMethods.indices.enumerated() {
      d.paymentMethods[index].name = name(labels.account, number)
      d.paymentMethods[index].aliases = []
    }
    for (number, index) in d.banks.indices.enumerated() {
      d.banks[index].name = name(labels.bank, number)
    }
    for (number, index) in d.accountGroups.indices.enumerated() {
      d.accountGroups[index].name = name(labels.accountGroup, number)
    }
    for (number, index) in d.cards.indices.enumerated() {
      d.cards[index].name = name(labels.card, number)
      d.cards[index].aliases = []
      d.cards[index].last4 = nil
      d.cards[index].details = nil
    }
    for (number, index) in d.goals.indices.enumerated() {
      d.goals[index].name = name(labels.goal, number)
    }
    // Live and deleted debts are numbered as one run, live first.
    var debtNumber = 0
    for index in d.debts.indices {
      d.debts[index].name = name(labels.debt, debtNumber)
      d.debts[index].note = nil
      debtNumber += 1
    }
    for index in d.deletedDebts.indices {
      d.deletedDebts[index].name = name(labels.debt, debtNumber)
      d.deletedDebts[index].note = nil
      debtNumber += 1
    }
    for index in d.debtCosts.indices { d.debtCosts[index].name = nil }
    for (number, index) in d.assets.indices.enumerated() {
      d.assets[index].name = name(labels.asset, number)
      d.assets[index].note = nil
    }
    for index in d.assetValuations.indices { d.assetValuations[index].note = nil }
    for (number, index) in d.ownedItems.indices.enumerated() {
      d.ownedItems[index].name = name(labels.ownedItem, number)
      d.ownedItems[index].note = nil
    }
    for (number, index) in d.wishes.indices.enumerated() {
      d.wishes[index].name = name(labels.wish, number)
      d.wishes[index].url = nil
      d.wishes[index].note = nil
    }
    for (number, index) in d.shoppingItems.indices.enumerated() {
      d.shoppingItems[index].name = name(labels.shoppingItem, number)
      d.shoppingItems[index].note = nil
    }
    for (number, index) in d.tagBook.tags.indices.enumerated() {
      d.tagBook.tags[index].name = name(labels.tag, number)
    }
    for (number, index) in d.rules.indices.enumerated() {
      d.rules[index].name = name(labels.rule, number)
      d.rules[index].conditions = d.rules[index].conditions.enumerated().map { position, item in
        if case .textContains = item {
          return .textContains(name(labels.ruleText, number * 100 + position))
        }
        return item
      }
    }
    for (number, index) in d.dayNotes.indices.enumerated() {
      d.dayNotes[index].text = name(labels.dayNote, number)
    }
    var bank = d.bankData
    for index in bank.conditions.indices { bank.conditions[index].note = nil }
    d.bankData = bank

    // Planning.
    for (number, index) in d.planning.scheduled.indices.enumerated() {
      d.planning.scheduled[index].name = name(labels.scheduledPayment, number)
      d.planning.scheduled[index].cancelURL = nil
    }
    for (number, index) in d.planning.expected.indices.enumerated() {
      d.planning.expected[index].name = name(labels.expectedIncome, number)
    }
    var groupNames: [String: String] = [:]
    for index in d.planning.debtEntries.indices {
      if let group = d.planning.debtEntries[index].groupName {
        if groupNames[group] == nil {
          groupNames[group] = name(labels.debtGroup, groupNames.count)
        }
        d.planning.debtEntries[index].groupName = groupNames[group]
      }
      d.planning.debtEntries[index].description = nil
      d.planning.debtEntries[index].note = nil
    }
    var year = d.yearPlan
    for (number, index) in year.eventItems.indices.enumerated() {
      year.eventItems[index].title = name(labels.eventItem, number)
    }
    var templateNumber = 0
    for index in year.eventTemplates.indices where !year.eventTemplates[index].isBuiltIn {
      year.eventTemplates[index].name = name(labels.eventTemplate, templateNumber)
      templateNumber += 1
      for line in year.eventTemplates[index].lines.indices {
        year.eventTemplates[index].lines[line].title = name(labels.eventItem, line)
      }
    }
    d.yearPlan = year

    // Transfers, the model's memory, the lists that name things.
    for index in d.transfers.indices {
      d.transfers[index].note = nil
      d.transfers[index].externalId = ownKey(d.transfers[index].externalId)
    }
    for index in d.feedback.indices { d.feedback[index].text = "" }
    d.dismissals = []
    d.savedViews = SavedViewsBook()
    d.debtSettings.nudgeTemplate = nil

    d.version &+= 1
    return d
  }

  private static func name(_ stem: String, _ zeroBased: Int) -> String {
    "\(stem) \(zeroBased + 1)"
  }

  /// Every word of the owner's the copy is meant to lose, from the original: names, aliases,
  /// comments, descriptions. A test (and the export, as a last check) looks that none of
  /// them is left in the copy.
  public static func sensitiveTexts(of dataset: Dataset) -> Set<String> {
    var texts: [String?] = []
    for entry in dataset.entries {
      texts.append(entry.transaction.note)
      texts.append(entry.transaction.warrantyWhere)
      texts.append(contentsOf: entry.parts.map(\.note))
    }
    texts += dataset.people.map(\.name) + dataset.people.flatMap(\.aliases)
    texts += dataset.places.map(\.name) + dataset.places.flatMap(\.aliases)
    texts += dataset.events.map(\.name)
    texts += dataset.paymentMethods.map(\.name) + dataset.paymentMethods.flatMap(\.aliases)
    texts += dataset.banks.map(\.name) + dataset.accountGroups.map(\.name)
    texts += dataset.cards.map(\.name) + dataset.cards.flatMap(\.aliases)
    texts += dataset.cards.map(\.details)
    texts += dataset.goals.map(\.name)
    texts += (dataset.debts + dataset.deletedDebts).flatMap { [$0.name, $0.note] }
    texts += dataset.assets.flatMap { [$0.name, $0.note] }
    texts += dataset.ownedItems.flatMap { [$0.name, $0.note] }
    texts += dataset.wishes.flatMap { [$0.name, $0.url, $0.note] }
    texts += dataset.shoppingItems.flatMap { [$0.name, $0.note] }
    texts += dataset.tagBook.tags.map(\.name) + dataset.rules.map(\.name)
    texts += dataset.dayNotes.map(\.text)
    texts += dataset.planning.scheduled.map(\.name) + dataset.planning.expected.map(\.name)
    texts += dataset.planning.debtEntries.flatMap { [$0.groupName, $0.description, $0.note] }
    texts += dataset.transfers.map(\.note)
    texts += dataset.feedback.map(\.text)
    return Set(
      texts.compactMap { $0 }.map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })
  }
}
