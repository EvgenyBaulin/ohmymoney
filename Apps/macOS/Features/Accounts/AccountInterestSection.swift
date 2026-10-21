import AppCore
import AppDatabase
import SwiftUI

/// Why the interest of an account was not saved. Nothing is written then.
enum InterestIssue: Error, Hashable, Sendable {
  /// The rate does not read as a percent above zero and up to 100.
  case rate
  /// «В конце срока» without the day the deposit ends.
  case endNeeded
  /// The day it ends is not after the day it was opened.
  case endBeforeOpening
  /// The interest goes to an account that is not a live account other than this one.
  case payoutAccount
}

/// «Проценты» of the account editor, as typed until «Сохранить»: whether the balance earns
/// interest, the rate, how often it is paid and on which day, where it goes, and the days the
/// deposit was opened and ends. An end makes it a deposit, none a savings account.
struct InterestDraft: Equatable {
  var isOn: Bool
  var rateText: String
  var period: InterestPeriod
  /// The day of the month it is paid on; `nil` — not said: the day of opening, else the last
  /// day of the month.
  var day: Int?
  /// `nil` — onto this account, where it earns interest in turn.
  var payoutAccountId: UUID?
  /// `nil` — not said: the interest is counted from the first count of the account.
  var openedOn: DateOnly?
  /// `nil` — a savings account, which never ends.
  var endsOn: DateOnly?

  /// The interest an account has, or the switch off for one that earns none.
  init(_ terms: DepositTerms?) {
    isOn = terms != nil
    rateText = terms.map { NumberText.decimal($0.rate, fractionDigits: 0...4) } ?? ""
    period = terms?.period ?? .monthly
    day = terms?.day
    payoutAccountId = terms?.payoutAccountId
    openedOn = terms?.openedOn
    endsOn = terms?.endsOn
  }

  /// A deposit ends; a savings account does not.
  var isDeposit: Bool { endsOn != nil }

  /// The rate as typed, read like the rate of a debt: «16», «16,5», «16.5 %».
  var rate: Decimal? { DebtPayoff.parseRate(rateText) }

  /// The terms the draft saves: `nil` with the switch off, or why it cannot be saved.
  /// `accountId` is the account the terms are for: the interest is never paid to it by name —
  /// that is «на этот счёт».
  func terms(accountId: UUID) -> Result<DepositTerms?, InterestIssue> {
    guard isOn else { return .success(nil) }
    guard let rate, rate > 0, rate <= 100 else { return .failure(.rate) }
    if period == .atEnd, endsOn == nil { return .failure(.endNeeded) }
    if let endsOn, let openedOn, endsOn <= openedOn { return .failure(.endBeforeOpening) }
    if payoutAccountId == accountId { return .failure(.payoutAccount) }
    return .success(
      DepositTerms(
        rate: rate, period: period, day: period == .atEnd ? nil : day,
        payoutAccountId: payoutAccountId, openedOn: openedOn, endsOn: endsOn))
  }
}

/// «Проценты» in the editor of an account: «На остаток начисляются проценты», then the rate,
/// «Выплата» monthly, quarterly or at the end, its day, «Куда» — this account (the interest
/// earns in turn) or another live account —, «Открыт» and «Закрывается». With an end it is a
/// deposit, without one a savings account; the footer says that a deposit kept out of the
/// summary leaves «Можно тратить» alone.
struct AccountInterestSection: View {
  @Dependency(\.environment) private var environment
  @Binding var draft: InterestDraft
  /// The accounts the interest may go to, named as every list names them.
  let payoutChoices: [AccountCardChoices.Item]

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    Section {
      Toggle(isOn: $draft.isOn) {
        Text(verbatim: t("account.interest.toggle"))
      }
      .accessibilityIdentifier("account.interest.toggle")
      if draft.isOn {
        LabeledContent {
          HStack(spacing: 4) {
            TextField(text: $draft.rateText, prompt: Text(verbatim: "16")) {
              Text(verbatim: t("account.interest.rate"))
            }
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .appFont(.body.monospacedDigit())
            .frame(width: 80)
            .accessibilityIdentifier("account.interest.rate")
            Text(verbatim: "%").foregroundStyle(.secondary)
          }
        } label: {
          Text(verbatim: t("account.interest.rate"))
        }
        Picker(selection: $draft.period) {
          ForEach(InterestPeriod.allCases, id: \.self) { period in
            Text(verbatim: t(Self.periodKey(period))).tag(period)
          }
        } label: {
          Text(verbatim: t("account.interest.period"))
        }
        if draft.period != .atEnd {
          Picker(selection: $draft.day) {
            Text(verbatim: t("account.interest.dayNotSaid")).tag(Int?.none)
            ForEach(1...31, id: \.self) { day in
              Text(verbatim: day == 31 ? t("account.interest.dayLast") : "\(day)")
                .tag(Int?.some(day))
            }
          } label: {
            Text(verbatim: t("account.interest.day"))
          }
        }
        Picker(selection: $draft.payoutAccountId) {
          Text(verbatim: t("account.interest.toItself")).tag(UUID?.none)
          ForEach(payoutChoices) { item in
            Text(verbatim: item.name).tag(UUID?.some(item.id))
          }
        } label: {
          Text(verbatim: t("account.interest.payout"))
        }
        .accessibilityIdentifier("account.interest.payout")
        Toggle(isOn: said($draft.openedOn, starting: environment.today)) {
          Text(verbatim: t("account.interest.opened"))
        }
        .accessibilityIdentifier("account.interest.opened")
        if draft.openedOn != nil {
          DatePicker(selection: day($draft.openedOn), displayedComponents: .date) {
            Text(verbatim: t("account.interest.openedOn"))
          }
        }
        Toggle(isOn: said($draft.endsOn, starting: Self.aYearAfter(environment.today))) {
          Text(verbatim: t("account.interest.ends"))
        }
        .accessibilityIdentifier("account.interest.ends")
        if draft.endsOn != nil {
          DatePicker(selection: day($draft.endsOn), displayedComponents: .date) {
            Text(verbatim: t("account.interest.endsOn"))
          }
        }
        Label {
          Text(
            verbatim: t(
              draft.isDeposit ? "account.interest.isDeposit" : "account.interest.isSavings"))
        } icon: {
          Image(systemName: draft.isDeposit ? "lock.square" : "banknote")
        }
        .foregroundStyle(.secondary)
      }
    } header: {
      Text(verbatim: t("account.interest.title"))
    } footer: {
      Text(verbatim: t(draft.isOn ? "account.interest.hint" : "account.interest.offHint"))
        .foregroundStyle(.secondary)
    }
  }

  static func periodKey(_ period: InterestPeriod) -> String {
    switch period {
    case .monthly: "account.interest.monthly"
    case .quarterly: "account.interest.quarterly"
    case .atEnd: "account.interest.atEnd"
    }
  }

  /// The same day a year later — the 28th at most, so every month has it.
  static func aYearAfter(_ day: DateOnly) -> DateOnly {
    DateOnly(year: day.year + 1, month: day.month, day: min(day.day, 28))
  }

  /// A switch over a day that may be not said: on, it starts at `starting`.
  private func said(_ value: Binding<DateOnly?>, starting: DateOnly) -> Binding<Bool> {
    Binding(
      get: { value.wrappedValue != nil },
      set: { value.wrappedValue = $0 ? (value.wrappedValue ?? starting) : nil })
  }

  private func day(_ value: Binding<DateOnly?>) -> Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(value.wrappedValue ?? environment.today) },
      set: { value.wrappedValue = environment.calendar.day(of: $0) })
  }
}

// MARK: - The category of interest

/// Where the income of interest goes.
enum InterestCategoryChoice: Hashable, Sendable {
  /// A live income category: the one remembered, or one called «Проценты».
  case existing(UUID)
  /// The category is in the archive — itself, its parent, or both: written live again, the
  /// parent first, in the same change, and the same ⌘Z puts them back.
  case revive(UUID, [CoreKit.Category])
  /// No such category: a new one at the top level of income.
  case create(CoreKit.Category)

  var categoryId: UUID {
    switch self {
    case .existing(let id): id
    case .revive(let id, _): id
    case .create(let category): category.id
    }
  }
}

extension AccountActions {
  /// The names an income category of interest may already have, folded as names are compared.
  nonisolated static let interestCategoryNames: Set<String> = [
    NameKey.fold("Проценты"), NameKey.fold("Interest"),
  ]

  /// The category the interest of deposits goes to, the first that applies:
  ///
  /// 1. the one remembered (`accounts.interestCategory`), while it is an income category and it
  ///    and its parent are live;
  /// 2. a live income category at the top level called «Проценты» or "Interest" (or `name`);
  /// 3. the one remembered, when it or its parent is in the archive: both come back;
  /// 4. a category of that name in the archive, at the top level of income: it comes back;
  /// 5. a new one at the top level of income, called `name`, after the others.
  nonisolated static func interestCategory(
    categories: [CoreKit.Category], remembered: UUID?, name: String
  ) -> InterestCategoryChoice {
    let byId = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func parent(of category: CoreKit.Category) -> CoreKit.Category? {
      category.parentId.flatMap { byId[$0] }
    }
    func isLive(_ category: CoreKit.Category) -> Bool {
      !category.archived && parent(of: category).map { !$0.archived } ?? true
    }
    var names = interestCategoryNames
    names.insert(NameKey.fold(name))
    let remembered = remembered.flatMap { byId[$0] }.flatMap { $0.kind == .income ? $0 : nil }
    if let remembered, isLive(remembered) { return .existing(remembered.id) }
    let named = categories.filter {
      $0.kind == .income && $0.parentId == nil && names.contains(NameKey.fold($0.name))
    }
    if let live = named.first(where: { !$0.archived }) { return .existing(live.id) }
    if let remembered {
      let back = [parent(of: remembered), remembered].compactMap { $0 }.filter(\.archived)
        .map { category -> CoreKit.Category in
          var category = category
          category.archived = false
          return category
        }
      return .revive(remembered.id, back)
    }
    if var archived = named.first {
      archived.archived = false
      return .revive(archived.id, [archived])
    }
    let siblings = categories.filter { $0.parentId == nil && $0.kind == .income }
    return .create(
      CoreKit.Category(
        kind: .income, name: name, sort: (siblings.map(\.sort).max() ?? 0) + 1))
  }

  /// The rows and the setting a write that needs the category of interest adds to its change:
  /// the category brought back or made, and `accounts.interestCategory` when it is not the one
  /// remembered. Returns the category's id.
  @discardableResult
  func addInterestCategory(to change: inout PlanningChange, books: AccountBooks) -> UUID {
    let remembered = books.dataset.accountSettings.interestCategoryId
    let choice = Self.interestCategory(
      categories: books.dataset.categories, remembered: remembered,
      name: environment.language("account.interest.category", table: AccountText.table))
    switch choice {
    case .existing: break
    case .revive(_, let categories): change.upsert.categories += categories
    case .create(let category): change.upsert.categories.append(category)
    }
    let id = choice.categoryId
    if remembered != id {
      change.settings.updateValue(id.uuidString, forKey: AccountSettings.interestCategoryKey)
    }
    return id
  }
}
