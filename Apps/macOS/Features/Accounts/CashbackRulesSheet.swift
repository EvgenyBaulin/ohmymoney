import AppCore
import SwiftUI

/// One row of the rules sheet: a category (none — everything else), always or one month, and
/// the percent as typed.
struct CashbackRuleRow: Identifiable, Equatable {
  /// The rule's own id, or a new one for a row added in the sheet.
  var id: UUID
  var categoryId: UUID?
  /// `nil`: always.
  var month: MonthKey?
  var percentText: String

  init(id: UUID = UUID(), categoryId: UUID? = nil, month: MonthKey? = nil, percentText: String) {
    self.id = id
    self.categoryId = categoryId
    self.month = month
    self.percentText = percentText
  }

  init(_ rule: CashbackRule) {
    self.init(
      id: rule.id, categoryId: rule.categoryId, month: rule.month,
      percentText: NumberText.plain(rule.percent.decimal))
  }

  /// The percent typed: a number from 0 to 100 with at most four decimals, «%» allowed after
  /// it; `nil` when it does not read so.
  var percent: CashbackPercent? {
    let text = percentText.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    switch CashbackInput.read(text.hasSuffix("%") ? text : text + "%") {
    case .percent(let percent): return percent
    default: return nil
    }
  }
}

/// What the payout picker of the sheet offers.
enum CashbackPayoutChoice: Hashable, CaseIterable {
  /// The account has not said.
  case unknown
  case immediately
  /// By a day of the next month.
  case later
}

/// What the rules sheet holds until «Сохранить»: the rules of the account and of each of its live
/// cards — a card's are only the ones in which it differs from the account —, and the settings
/// of the account's cashback: how its bank rounds, when it pays, where the points go. Saving
/// writes the rules of every holder edited, by key, and the settings, in one step of ⌘Z.
struct CashbackRulesDraft: Equatable {
  /// Where the rules of the account live: the account itself, then its live cards.
  let holders: [CashbackHolder]
  let accountId: UUID
  var holder: CashbackHolder
  /// The month «Только в месяце» shows.
  var month: MonthKey
  private(set) var rows: [CashbackHolder: [CashbackRuleRow]]
  /// The settings of the account's cashback as the sheet holds them.
  var settings: CashbackAccountSettings
  /// The day the payout picker offers while the bank pays «later».
  private(set) var laterDay: Int

  init(
    holders: [CashbackHolder], accountId: UUID, holder: CashbackHolder? = nil,
    rules: [CashbackRule], month: MonthKey, settings: CashbackAccountSettings = .init()
  ) {
    self.holders = holders
    self.accountId = accountId
    self.holder =
      holder.flatMap { holders.contains($0) ? $0 : nil } ?? holders.first ?? .account(accountId)
    self.month = month
    var rows: [CashbackHolder: [CashbackRuleRow]] = [:]
    for held in holders {
      rows[held] = rules.filter { $0.holder == held }.map(CashbackRuleRow.init)
    }
    self.rows = rows
    self.settings = settings
    self.laterDay = settings.payout?.day ?? 10
  }

  /// The rules shown are the account's own, and the settings with them.
  var isAccountShown: Bool { holder == .account(accountId) }

  // MARK: The settings

  var payoutChoice: CashbackPayoutChoice {
    switch settings.payout?.timing {
    case nil: .unknown
    case .immediately?: .immediately
    case .later?: .later
    }
  }

  mutating func choosePayout(_ choice: CashbackPayoutChoice) {
    switch choice {
    case .unknown: settings.payout = nil
    case .immediately: settings.payout = .immediately
    case .later: settings.payout = CashbackPayout.later(day: laterDay)
    }
  }

  /// The day of the next month the bank pays by; 31 is the end of any month.
  mutating func chooseDay(_ day: Int) {
    guard let payout = CashbackPayout.later(day: day) else { return }
    laterDay = day
    if payoutChoice == .later { settings.payout = payout }
  }

  var payoutDay: Int { settings.payout?.day ?? laterDay }

  /// The rows of the holder shown.
  var current: [CashbackRuleRow] { rows[holder] ?? [] }
  var always: [CashbackRuleRow] { current.filter { $0.month == nil } }
  var ofMonth: [CashbackRuleRow] { current.filter { $0.month == month } }
  /// The rules of other months, shown to be deleted.
  var otherMonths: [CashbackRuleRow] {
    current.filter { $0.month != nil && $0.month != month }
      .sorted { left, right in
        let (l, r) = (left.month ?? month, right.month ?? month)
        return l != r ? l > r : left.id.uuidString < right.id.uuidString
      }
  }

  mutating func add(month: MonthKey?) {
    rows[holder, default: []].append(CashbackRuleRow(month: month, percentText: ""))
  }

  mutating func remove(_ id: UUID) {
    rows[holder]?.removeAll { $0.id == id }
  }

  mutating func update(_ row: CashbackRuleRow) {
    guard let index = rows[holder]?.firstIndex(where: { $0.id == row.id }) else { return }
    rows[holder]?[index] = row
  }

  /// «Как в прошлом месяце»: the rules of the month before, for a category the month has none.
  mutating func copyLastMonth() {
    let taken = Set(ofMonth.map(\.categoryId))
    let copies = current.filter { $0.month == month.previous && !taken.contains($0.categoryId) }
      .map { rule in
        CashbackRuleRow(categoryId: rule.categoryId, month: month, percentText: rule.percentText)
      }
    rows[holder, default: []].append(contentsOf: copies)
  }

  var hasLastMonth: Bool { current.contains { $0.month == month.previous } }

  /// Rows whose percent does not read, and rows that repeat a category of the same month (or
  /// of «always») of the same holder: the second and later of each.
  var problems: Set<UUID> {
    var result: Set<UUID> = []
    for held in holders {
      var seen: Set<String> = []
      for row in rows[held] ?? [] {
        if row.percent == nil { result.insert(row.id) }
        let key = "\(row.month?.iso ?? "")|\(row.categoryId?.uuidString ?? "")"
        if !seen.insert(key).inserted { result.insert(row.id) }
      }
    }
    return result
  }

  /// The holders with a row that keeps «Сохранить» off, in the order of the picker.
  var holdersWithProblems: [CashbackHolder] {
    let problems = self.problems
    return holders.filter { held in (rows[held] ?? []).contains { problems.contains($0.id) } }
  }

  /// The holders with such a row that is not on screen with its words — a row of another card,
  /// or of another month of the card shown —: the sheet names them under the form, so that
  /// «Сохранить» is never off without a reason in sight.
  var problemsOutOfSight: [CashbackHolder] {
    let problems = self.problems
    return holders.filter { held in
      let unseen = held == holder ? otherMonths : (rows[held] ?? [])
      return unseen.contains { problems.contains($0.id) }
    }
  }

  /// A row repeats a key: said under the sheet.
  func isDuplicate(_ row: CashbackRuleRow) -> Bool {
    guard let rows = rows[holder],
      let first = rows.first(where: { $0.month == row.month && $0.categoryId == row.categoryId })
    else { return false }
    return first.id != row.id
  }

  /// The rules to save, of every holder; `nil` while a row has a problem.
  var rules: [CashbackRule]? {
    guard problems.isEmpty else { return nil }
    var result: [CashbackRule] = []
    for held in holders {
      let cardId: UUID?
      switch held {
      case .card(let id): cardId = id
      case .account: cardId = nil
      }
      for row in rows[held] ?? [] {
        guard let percent = row.percent else { return nil }
        result.append(
          CashbackRule(
            id: row.id, accountId: accountId, cardId: cardId, categoryId: row.categoryId,
            month: row.month, percent: percent))
      }
    }
    return result
  }

  /// The months «Только в месяце» offers: twelve back, two ahead, and any month with a rule.
  func months(around today: MonthKey) -> [MonthKey] {
    var months: [MonthKey] = []
    var cursor = today
    for _ in 0..<12 { cursor = cursor.previous }
    for _ in 0..<15 {
      months.append(cursor)
      cursor = cursor.next
    }
    for month in current.compactMap(\.month) where !months.contains(month) {
      months.append(month)
    }
    return months.sorted(by: >)
  }
}

/// «Правила кэшбэка»: the rules of the account, which its cards follow — «always» and «only in a
/// month» —, the rules a card keeps for itself where it differs, and, with the account's, how
/// its bank rounds the cashback, when it pays it and where the points go. «Сохранить» writes one
/// step of ⌘Z; a row that does not read is marked with a symbol and words and keeps the button
/// off.
struct CashbackRulesSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let accountId: UUID
  let finish: () -> Void

  @State private var draft: CashbackRulesDraft?
  @State private var choices: [CoreKit.Category] = []
  @State private var names: [UUID: String] = [:]
  @State private var cards: [PaymentCard] = []
  @State private var accounts: [PaymentMethod] = []
  @State private var refusal: CardRefusal?
  @State private var failed = false
  private let startHolder: CashbackHolder?

  init(accountId: UUID, holder: CashbackHolder? = nil, finish: @escaping () -> Void) {
    self.accountId = accountId
    self.startHolder = holder
    self.finish = finish
  }

  private var actions: CardActions { CardActions(environment: environment, store: store) }
  private func t(_ key: String) -> String { environment.language(key, table: CardText.table) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let draft {
        Text(
          verbatim: environment.format(
            "cashback.sheet.title", table: CardText.table,
            CardText.holderName(draft.holder, cards: cards, accounts: accounts))
        )
        .appFont(.headline)
        form(draft)
      } else {
        ProgressView()
      }
      if let draft {
        ForEach(draft.problemsOutOfSight, id: \.self) { held in
          Label {
            Text(
              verbatim: environment.format(
                "cashback.sheet.problemOn", table: CardText.table,
                CardText.holderName(held, cards: cards, accounts: accounts)))
          } icon: {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
          .appFont(.caption)
        }
      }
      if let refusal { CardRefusalNote(refusal: refusal) }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel, action: finish)
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(draft?.rules == nil || store.isWritingInBackground)
      }
    }
    .padding(20)
    .sheetFrame(width: 560, height: 620)
    .task { load() }
    .refusedWriteAlert($failed, environment)
  }

  private func load() {
    let actions = self.actions
    cards = actions.cards
    accounts = actions.accounts
    let categories = actions.categories
    names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    choices = CashbackRules.categoryChoices(
      tree: CategoryTree(categories), categories: categories,
      reconcileCategoryIds: actions.reconcileCategoryIds)
    draft = CashbackRulesDraft(
      holders: CashbackHolders.editableHolders(of: accountId, cards: cards),
      accountId: accountId, holder: startHolder, rules: actions.rules,
      month: environment.today.monthKey,
      settings: accounts.first { $0.id == accountId }.map(CashbackAccountSettings.init) ?? .init())
  }

  /// The draft of the sheet; `current` stands in only for the moment it is being replaced.
  private func binding(_ current: CashbackRulesDraft) -> Binding<CashbackRulesDraft> {
    Binding(
      get: { draft ?? current },
      set: {
        draft = $0
        refusal = nil
      })
  }

  @ViewBuilder
  private func form(_ current: CashbackRulesDraft) -> some View {
    let model = binding(current)
    Form {
      if current.holders.count > 1 {
        Picker(selection: model.holder) {
          ForEach(current.holders, id: \.self) { holder in
            Text(verbatim: holderLabel(holder)).tag(holder)
          }
        } label: {
          Text(verbatim: t("cashback.sheet.holder"))
        }
        Text(
          verbatim: t(
            current.isAccountShown ? "cashback.sheet.accountHint" : "cashback.sheet.cardHint")
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      if current.isAccountShown { settingsSections(current, model: model) }
      Section {
        ForEach(current.always) { row in ruleRow(row, model: model) }
        Button(t("cashback.sheet.addRule")) { draft?.add(month: nil) }
      } header: {
        Text(verbatim: t("cashback.sheet.always"))
      }
      Section {
        Picker(selection: model.month) {
          ForEach(current.months(around: environment.today.monthKey), id: \.self) { month in
            Text(verbatim: environment.dates.monthTitle(month)).tag(month)
          }
        } label: {
          Text(verbatim: t("cashback.sheet.monthPicker"))
        }
        ForEach(current.ofMonth) { row in ruleRow(row, model: model) }
        HStack {
          Button(t("cashback.sheet.addRule")) { draft?.add(month: current.month) }
          Button(t("cashback.sheet.copyLastMonth")) { draft?.copyLastMonth() }
            .disabled(!current.hasLastMonth)
        }
      } header: {
        Text(verbatim: t("cashback.sheet.month"))
      }
      if !current.otherMonths.isEmpty {
        Section {
          ForEach(current.otherMonths) { row in
            HStack {
              Text(verbatim: row.month.map { environment.dates.monthTitle($0) } ?? "")
                .foregroundStyle(.secondary)
              Text(verbatim: categoryName(row.categoryId))
              Spacer()
              Text(verbatim: row.percent.map { environment.money.percent($0) } ?? row.percentText)
                .monospacedDigit()
              removeButton(row)
            }
          }
        } header: {
          Text(verbatim: t("cashback.sheet.otherMonths"))
        }
      }
      Section {
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: t("cashback.sheet.hint"))
          Text(verbatim: t("cashback.sheet.expectationHint"))
        }
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  /// «Счёт «Сбер» и его карты» / «Только карта «Black»».
  private func holderLabel(_ holder: CashbackHolder) -> String {
    switch holder {
    case .account(let id):
      return environment.format(
        "cashback.sheet.holderAccount", table: CardText.table,
        accounts.first { $0.id == id }?.name ?? "")
    case .card(let id):
      return environment.format(
        "cashback.sheet.holderCard", table: CardText.table,
        cards.first { $0.id == id }?.name ?? "")
    }
  }

  /// How the bank rounds the cashback of a purchase, when it pays, and where the points go.
  @ViewBuilder
  private func settingsSections(
    _ current: CashbackRulesDraft, model: Binding<CashbackRulesDraft>
  ) -> some View {
    Section {
      Picker(selection: model.settings.rounding.precision) {
        Text(verbatim: t("cashback.rounding.whole")).tag(CashbackRounding.Precision.whole)
        Text(verbatim: t("cashback.rounding.cents")).tag(CashbackRounding.Precision.cents)
      } label: {
        Text(verbatim: t("cashback.rounding.precision"))
      }
      .accessibilityIdentifier("cashback.rounding.precision")
      Picker(selection: model.settings.rounding.direction) {
        Text(verbatim: t("cashback.rounding.nearest")).tag(CashbackRounding.Direction.nearest)
        Text(verbatim: t("cashback.rounding.down")).tag(CashbackRounding.Direction.down)
        Text(verbatim: t("cashback.rounding.up")).tag(CashbackRounding.Direction.up)
      } label: {
        Text(verbatim: t("cashback.rounding.direction"))
      }
      .accessibilityIdentifier("cashback.rounding.direction")
      Picker(
        selection: Binding(
          get: { current.payoutChoice },
          set: { choice in draft?.choosePayout(choice) })
      ) {
        Text(verbatim: t("cashback.payout.unknown")).tag(CashbackPayoutChoice.unknown)
        Text(verbatim: t("cashback.payout.immediately")).tag(CashbackPayoutChoice.immediately)
        Text(verbatim: t("cashback.payout.later")).tag(CashbackPayoutChoice.later)
      } label: {
        Text(verbatim: t("cashback.payout"))
      }
      .accessibilityIdentifier("cashback.payout")
      if current.payoutChoice == .later {
        Picker(
          selection: Binding(get: { current.payoutDay }, set: { draft?.chooseDay($0) })
        ) {
          ForEach(1...30, id: \.self) { day in
            Text(verbatim: environment.format("cashback.payout.day", table: CardText.table, day))
              .tag(day)
          }
          Text(verbatim: t("cashback.payout.lastDay")).tag(31)
        } label: {
          Text(verbatim: t("cashback.payout.dayLabel"))
        }
        .accessibilityIdentifier("cashback.payout.day")
      }
      pointsPicker(current, model: model)
    } header: {
      Text(verbatim: t("cashback.settings.header"))
    } footer: {
      Text(verbatim: t("cashback.settings.hint")).foregroundStyle(.secondary)
    }
  }

  /// «Деньгами на этот счёт» or «Баллами на счёт …».
  @ViewBuilder
  private func pointsPicker(
    _ current: CashbackRulesDraft, model: Binding<CashbackRulesDraft>
  ) -> some View {
    let chosen = current.settings.pointsAccountId
    let others = CashbackPoints.choices(for: accountId, among: accounts)
    let kept = chosen.flatMap { id in accounts.first { $0.id == id } }
    Picker(selection: model.settings.pointsAccountId) {
      Text(verbatim: t("cashback.points.money")).tag(UUID?.none)
      ForEach(others, id: \.id) { account in
        Text(
          verbatim: environment.format("cashback.points.on", table: CardText.table, account.name)
        )
        .tag(UUID?.some(account.id))
      }
      // The account the points go to now, when it is in the archive: shown until another is taken.
      if let kept, !others.contains(where: { $0.id == kept.id }) {
        Text(verbatim: environment.format("cashback.points.on", table: CardText.table, kept.name))
          .tag(UUID?.some(kept.id))
      }
    } label: {
      Text(verbatim: t("cashback.points"))
    }
    .accessibilityIdentifier("cashback.points")
  }

  private func ruleRow(_ row: CashbackRuleRow, model: Binding<CashbackRulesDraft>) -> some View {
    let problem: String? =
      row.percent == nil
      ? t("cashback.refusal.percent")
      : (draft?.isDuplicate(row) == true
        ? environment.format(
          "cashback.refusal.duplicate", table: CardText.table, categoryName(row.categoryId))
        : nil)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Picker(
          selection: Binding(
            get: { row.categoryId },
            set: { value in
              var edited = row
              edited.categoryId = value
              draft?.update(edited)
            })
        ) {
          Text(verbatim: t("cashback.everythingElse")).tag(UUID?.none)
          ForEach(choices, id: \.id) { category in
            Text(verbatim: category.parentId == nil ? category.name : "    " + category.name)
              .tag(UUID?.some(category.id))
          }
        } label: {
          Text(verbatim: t("cashback.sheet.category"))
        }
        TextField(
          text: Binding(
            get: { row.percentText },
            set: { value in
              var edited = row
              edited.percentText = value
              draft?.update(edited)
            })
        ) {
          Text(verbatim: t("cashback.sheet.percent"))
        }
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: 80)
        Text(verbatim: "%").foregroundStyle(.secondary)
        removeButton(row)
      }
      if let problem {
        Label {
          Text(verbatim: problem)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
        .appFont(.caption)
      }
    }
  }

  private func removeButton(_ row: CashbackRuleRow) -> some View {
    Button {
      draft?.remove(row.id)
    } label: {
      Image(systemName: "minus.circle")
        .accessibilityLabel(Text(verbatim: t("cashback.sheet.removeRule")))
    }
    .buttonStyle(.borderless)
    .help(t("cashback.sheet.removeRule"))
  }

  private func categoryName(_ id: UUID?) -> String {
    id.flatMap { names[$0] } ?? t("cashback.everythingElse")
  }

  private func save() {
    guard let draft, let rules = draft.rules else { return }
    let stored = accounts.first { $0.id == accountId }
    switch actions.saveRules(
      of: draft.holders, rules, account: stored.map { draft.settings.applied(to: $0) })
    {
    case .done: finish()
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}
