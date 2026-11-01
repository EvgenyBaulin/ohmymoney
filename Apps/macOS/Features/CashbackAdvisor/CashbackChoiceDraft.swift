import AppCore
import Foundation

/// What the sheet of the month's choice holds until «Сохранить»: the categories the bank offers
/// this month (label, percent, taken or not), how many the bank lets take, and the bank's table
/// «категория банка → ваша». Saving writes the offers, the bank's table, and the month's rules of
/// the account for the labels taken.
struct CashbackChoiceDraft: Equatable {
  struct Row: Identifiable, Equatable {
    var id: UUID
    var label: String
    var percentText: String
    var chosen: Bool

    init(id: UUID = UUID(), label: String = "", percentText: String = "", chosen: Bool = false) {
      self.id = id
      self.label = label
      self.percentText = percentText
      self.chosen = chosen
    }

    var percent: CashbackPercent? {
      let text = percentText.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { return nil }
      if case .percent(let percent)? = CashbackInput.read(text.hasSuffix("%") ? text : text + "%") {
        return percent
      }
      return nil
    }

    var isBlank: Bool { label.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  let accountId: UUID
  let bankId: UUID?
  let month: MonthKey
  var rows: [Row]
  /// How many categories the bank lets take this month.
  var pick: Int
  /// The bank's table, by the label as compared (`BankCategoryMapping.normalized`): the
  /// category a label stands for. Labels of other months keep their rows untouched.
  var mapping: [String: UUID]
  /// The rows of the bank's table as stored, to keep a label's other categories and the ids.
  let storedMappings: [BankCategoryMapping]

  init(
    accountId: UUID, bankId: UUID?, month: MonthKey, offers: [CashbackOffer],
    mappings: [BankCategoryMapping], previousChosen: Int? = nil
  ) {
    self.accountId = accountId
    self.bankId = bankId
    self.month = month
    let own = offers.filter { $0.accountId == accountId && $0.month == month }
    rows = own.map {
      Row(
        id: $0.id, label: $0.label, percentText: NumberText.plain($0.percent.decimal),
        chosen: $0.chosen)
    }
    if rows.isEmpty { rows = [Row()] }
    let chosen = own.filter(\.chosen).count
    pick = max(1, chosen > 0 ? chosen : (previousChosen ?? 3))
    let ofBank = mappings.filter { $0.bankId == bankId }
    storedMappings = ofBank
    var map: [String: UUID] = [:]
    for row in ofBank where map[BankCategoryMapping.normalized(row.label)] == nil {
      map[BankCategoryMapping.normalized(row.label)] = row.categoryId
    }
    mapping = map
  }

  /// Rows whose percent does not read (blank rows are dropped on save).
  var problems: Set<UUID> {
    Set(rows.filter { !$0.isBlank && $0.percent == nil }.map(\.id))
  }

  var canSave: Bool { problems.isEmpty }

  /// The offers to save: every row with a label and a percent.
  var offers: [CashbackOffer] {
    rows.compactMap { row in
      guard !row.isBlank, let percent = row.percent else { return nil }
      return CashbackOffer(
        id: row.id, accountId: accountId, month: month,
        label: row.label.trimmingCharacters(in: .whitespaces), percent: percent,
        chosen: row.chosen)
    }
  }

  /// The bank's table to save: each label of a row with the category chosen for it, the other
  /// rows of the bank kept as they were.
  var mappings: [BankCategoryMapping] {
    guard let bankId else { return [] }
    var result = storedMappings
    for row in rows where !row.isBlank {
      let key = BankCategoryMapping.normalized(row.label)
      let others = result.filter { BankCategoryMapping.normalized($0.label) != key }
      let kept = result.filter { BankCategoryMapping.normalized($0.label) == key }
      guard let category = mapping[key] else {
        result = others
        continue
      }
      if kept.contains(where: { $0.categoryId == category }) { continue }
      // The label's first category is the one the sheet edits; a second stays.
      let rest = kept.dropFirst()
      let id = kept.first?.id ?? UUID()
      result =
        others + [
          BankCategoryMapping(
            id: id, bankId: bankId, label: row.label.trimmingCharacters(in: .whitespaces),
            categoryId: category)
        ] + rest
    }
    return result
  }

  /// The best choices for a month like the last ones, best first.
  func best(
    spending: [UUID: AmountE4], tree: CategoryTree, accountCap: AmountE4?
  )
    -> [CashbackChoiceAdvisor.Pick]
  {
    CashbackChoiceAdvisor.best(
      offers: offers, pick: pick, bankId: bankId, mappings: mappings, spending: spending,
      tree: tree, accountCap: accountCap)
  }

  /// Takes exactly the offers of a pick.
  mutating func take(_ pick: CashbackChoiceAdvisor.Pick) {
    let ids = Set(pick.offerIds)
    for index in rows.indices { rows[index].chosen = ids.contains(rows[index].id) }
  }

  /// The rules of the account after the save: every rule but the account's own of this month,
  /// and the month's rules of the labels taken.
  func rules(replacing existing: [CashbackRule]) -> [CashbackRule] {
    let others = existing.filter {
      !($0.accountId == accountId && $0.cardId == nil && $0.month == month)
    }
    let ofMonth = existing.filter {
      $0.accountId == accountId && $0.cardId == nil && $0.month == month
    }
    let chosen = offers.filter(\.chosen)
    return others
      + CashbackChoiceAdvisor.rules(
        for: chosen, bankId: bankId, mappings: mappings, existing: ofMonth)
  }

  /// The labels taken that stand for no category of the bank's table: they write no rule.
  var unmappedChosen: [String] {
    offers.filter { $0.chosen && mapping[BankCategoryMapping.normalized($0.label)] == nil }
      .map(\.label)
  }
}
