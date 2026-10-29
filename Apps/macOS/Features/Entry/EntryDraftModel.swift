import AppCore
import AppDatabase
import Foundation
import Observation

/// Everything the ↓ panel edits: one draft operation plus the dictionaries it offers.
///
/// The model owns no views and no database writes — it prepares a `TransactionDraft` and
/// hands it back to the store, so the same rules can be exercised from tests.
@MainActor
@Observable
public final class EntryDraftModel {
  public var draft = TransactionDraft() {
    didSet {
      // The editor opened another saved operation: what it is is read once, and the cashback
      // kept with it is written into the field, so a save of any other change keeps it. A part
      // the draft already had becoming its first — the first part removed — opens nothing.
      if editsSavedOperation, let first = draft.parts.first?.id,
        !oldValue.parts.contains(where: { $0.id == first })
      {
        cashbackField = CashbackFieldState(kept: draft.cashback, on: draft)
        noteWhatWasOpened()
      }
      followTheCashbackField()
      followTheIncomeMonth()
      guard draft.creditDebtId != oldValue.creditDebtId else { return }
      kindWithTheCredit = draft.creditDebtId == nil ? nil : draft.kind
    }
  }
  /// What the owner's rules and the tags typed have done to the entry (`EntryDraftModel+Rules`).
  var ruleState = EntryRuleState()
  /// Categories that can be chosen: the archived ones are left out.
  public var categories: [CoreKit.Category] = []
  /// Categories retired since. They are never offered, but an operation saved under one of
  /// them still reads back as filed there instead of showing an empty picker.
  public private(set) var archivedCategories: [CoreKit.Category] = []
  public var people: [Person] = []
  /// For income: the expected income it is tied to («привязка к ожидаемому
  /// поступлению»). Saved with the operation in one write.
  public var expectedIncomeId: UUID?
  public var places: [Place] = []
  /// The places archived since, read with the live ones: a saved operation at one of them shows
  /// it in the menu (`placeChoices`); nothing new is ever offered one.
  private var archivedPlaces: [Place] = []
  /// The live accounts, the ones the account picker offers.
  public var paymentMethods: [PaymentMethod] = []
  /// Every account, archived ones too: a saved operation may sit on one retired since, and
  /// what it was charged is still worked out from its currencies.
  private var allAccounts: [PaymentMethod] = []
  public var events: [Event] = []
  public var goals: [Goal] = []
  public var debts: [Debt] = []
  /// Every debt, the closed and the deleted ones too: a saved payment of one of them keeps it in
  /// the menu (`debtChoices`).
  private var allDebts: [Debt] = []
  /// Every debt by its id, the closed and the deleted ones too.
  var allDebtsById: [UUID: Debt] {
    Dictionary(allDebts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
  /// Every card, archived ones too: the account picker offers the live cards of the live
  /// accounts, and a saved operation keeps the card it names whatever became of it.
  public private(set) var cards: [PaymentCard] = []
  /// The banks the accounts are filed under, archived ones included: they name the accounts in the
  /// account picker (`AccountLabels`).
  public private(set) var banks: [Bank] = []
  /// Every cashback rule, for what the ↓ panel expects an operation to earn.
  public private(set) var cashbackRules: [CashbackRule] = []

  /// Buying on credit or in instalments: which debt the purchase joins, or a new one, and
  /// how it will be repaid. The expense itself is recorded once, now, in its own category;
  /// the payments only reduce the debt.
  public struct CreditPlan: Hashable, Sendable {
    /// `nil` means a debt is created for this purchase.
    public var debtId: UUID?
    public var payments: Int
    public var monthlyAmount: AmountE4
    /// «Рассрочка частями»: the new debt is an instalment plan of `payments` equal parts — the
    /// price and the markup together —, the first on the day of the purchase (`InstalmentPlan`).
    public var instalments: Bool
    /// The days between two parts; `nil` — a part on the day of the purchase of every month.
    public var everyDays: Int?
    /// What the plan costs above the price, all of it; spent part by part with the payments.
    public var markup: AmountE4

    public init(
      debtId: UUID? = nil, payments: Int = 12, monthlyAmount: AmountE4 = .zero,
      instalments: Bool = false, everyDays: Int? = InstalmentPlan.defaultEveryDays,
      markup: AmountE4 = .zero
    ) {
      self.debtId = debtId
      self.payments = payments
      self.monthlyAmount = monthlyAmount
      self.instalments = instalments
      self.everyDays = everyDays
      self.markup = markup
    }
  }

  public var creditPlan: CreditPlan? {
    // A purchase on credit earns no cashback: the lender paid.
    didSet { followTheCashbackField() }
  }

  /// Up to three categories offered next to the picker, taken from history.
  public private(set) var categorySuggestions: [CoreKit.Category] = []

  private let references: ReferenceRepository?
  private let transactions: TransactionRepository?
  let calendar: CalendarContext
  /// The draft is a saved operation in the editor — the sheet or the inspector — not the
  /// entry line's new one. Such a draft skips the questions of a new operation (a date ahead,
  /// a repeat) and asks about a card's limit and the kept balance only when the edit makes
  /// them worse than the operation was saved (`savedOperation`, `addedSpend`).
  let editsSavedOperation: Bool
  /// The kind the draft had when its debt «on credit» came with it. In the editor the debt
  /// only ever comes with the saved operation, so this is the kind it was saved with.
  private var kindWithTheCredit: TransactionKind?
  /// Off by default — a hint, not a decision: an event covering the day is only
  /// offered, and the panel shows it as a suggestion until it is picked.
  private let assignsEventAutomatically: Bool

  /// My own ratings by description, for rule 2 of the qualities: an operation described the
  /// way one I rated by hand was keeps my last rating.
  private var qualityHistory = ManualQualityHistory.empty

  /// The event covering the day of the operation, offered rather than applied.
  public private(set) var suggestedEvent: Event?
  /// Names the entry line read but could not match to a dictionary. They are offered as
  /// the starting text when a person or a place is created on the spot.
  public private(set) var suggestedPersonName: String?
  public private(set) var suggestedPlaceName: String?
  /// The words that named them, as typed («для Пети», «в Кофемании»). They stay in the note
  /// until «Add…» of a menu makes a person or a place of the name.
  private var unmatchedPersonPhrase: String?
  private var unmatchedPlacePhrase: String?

  /// What the line last wrote into the note and the date — before any line, what the draft
  /// started with. A value still equal to it is one the panel left alone, and the next Enter
  /// writes over it; a value the panel changed is the owner's and stays
  /// («комментарий, дата» are fields of the panel).
  private var noteFromTheLine: String?
  private var dateFromTheLine: Date?
  /// The amount and the formula the line last wrote, by the same rule: while the draft still
  /// holds them the next line writes its own, and an amount the panel changed stays until a line
  /// says another one. A line without an amount leaves the amount as it is.
  private var amountFromTheLine: LineAmount?
  private struct LineAmount: Equatable {
    var amount: AmountE4
    var expression: String?
  }
  /// The date nobody chose: the one the draft was made with, or «now» the line wrote for a
  /// line that names no day. While the draft still holds it, the operation is dated the moment
  /// it is saved — the draft is made when the line appears or right after the last save, and
  /// may wait hours for the next one.
  private var dateFollowsTheClock = true
  /// The payment method the defaults last chose — of the place, otherwise the default one.
  /// While the draft still holds it, a better default replaces it (another place was chosen);
  /// a method the line named or the owner picked is never replaced.
  private var paymentMethodFromDefaults: UUID?
  /// The account the defaults laid is the one whose screen is open: that one counts as chosen
  /// — its currency is the operation's — while the place's last account and the main account,
  /// which come by themselves, do not.
  private var accountFromTheScreen = false
  /// The currency the defaults last laid: the default currency, or the main currency of the
  /// account chosen. While the draft still holds it, the defaults lay another; a currency the
  /// line named or the panel picked stays.
  private var currencyFromDefaults: CurrencyCode?
  /// «Списано со счёта» was typed from the statement: it stays while the account is charged in
  /// the same currency, instead of being worked out again from the rates.
  private var chargeTyped = false
  /// What a typed «Списано со счёта» was typed for: the amount, currency, day and account of
  /// that moment. When any of them changes the figure stays, and the panel asks to check it.
  private var chargeTypedFor: ChargeBasis?
  /// The operation's rate is the one a typed figure in rubles implies, laid because the bank
  /// has no rate for its currency: it goes when the figure goes.
  private var rateFromTheCharge = false
  /// The saved operation as the editor opened it, kept from the first change of what the
  /// account is charged by — the account, the currency, the amount, the day, the rate or the
  /// figure itself: what the figure is worked out again against (`AccountRules.legAfterEdit`).
  private var openedDraft: TransactionDraft?
  /// The bank's rates «Списано со счёта» is prefilled from, read once and kept until the rates
  /// may have changed: a reload, the moment of saving, or a new computation of the data.
  private var cachedRates: (table: RateTable, days: DayRates)?
  /// The count the owner has answered «Это было до сверки?» about for this draft: the save
  /// that follows the answer does not ask again.
  private var answeredCount: Date?
  /// The amount is zero because a zero was typed — «кофе 0» in the line, «0» in the field —
  /// not because none was: the save says it must be above zero instead of asking for one.
  private var zeroWasTyped = false
  /// «For whom» of the first part as the defaults last laid it: «Me» for a new operation, then
  /// the last choice made for the operation most like it. While the part still holds it, the
  /// defaults lay another; a value the line named or the owner chose stays, and so does the one
  /// a saved operation was recorded with — nil in the editor.
  private var forWhomFromDefaults: ForWhomChoice?

  /// «Карта · Счёт» at «Счёт», or «со счёта» in the line: the purchase names no card, and no
  /// default lays one (`layTheCard`). Off — the default — a purchase is made with the card the
  /// line named, else the card that paid at the place last, else the main card of the account.
  public internal(set) var paysFromAccount = false
  /// `paysFromAccount` is what the line said: the next reading that no longer says it takes it
  /// back, as a half-typed word is taken back (`TypedFills`).
  var paysFromAccountByTheLine = false
  /// The card the defaults laid. While the draft still holds it, the defaults lay another; a card
  /// the line named or the owner picked stays.
  var cardFromDefaults: UUID?
  /// The line said «смз»: income of the self-employed (`InputLineReading.selfEmployed`). Kept
  /// until the draft starts over, so the bar can offer to count the tax once it is written.
  public internal(set) var lineSaysSelfEmployed = false
  /// What the line last wrote into «Гарантия до» and «Вернуть можно до»: while a field still
  /// holds it, the next line writes its own or empties the field; a day picked in the panel stays.
  var warrantyFromTheLine: DateOnly?
  var returnFromTheLine: DateOnly?
  /// What the line last wrote into «Скидка»: the same rule as for the terms above.
  var discountFromTheLine: AmountE4?

  /// A value of «for whom» and the person it names, as one choice.
  private struct ForWhomChoice: Equatable {
    var value: ForWhom
    var personId: UUID?

    static let me = ForWhomChoice(value: .me, personId: nil)

    init(value: ForWhom, personId: UUID?) {
      self.value = value
      self.personId = personId
    }

    init(of part: PartDraft) {
      self.init(value: part.forWhom, personId: part.forPersonId)
    }
  }

  public init(
    references: ReferenceRepository?,
    transactions: TransactionRepository?,
    calendar: CalendarContext,
    assignsEventAutomatically: Bool = false,
    editsSavedOperation: Bool = false,
    defaultCurrency: CurrencyCode = .rub
  ) {
    self.references = references
    self.transactions = transactions
    self.calendar = calendar
    self.assignsEventAutomatically = assignsEventAutomatically
    self.editsSavedOperation = editsSavedOperation
    self.fixedDefaultCurrency = defaultCurrency
    self.forWhomFromDefaults = editsSavedOperation ? nil : .me
    self.draft.normalizeSinglePart()
    self.dateFromTheLine = draft.occurredAt
    // A new operation starts in the default currency; a saved one keeps its own.
    if !editsSavedOperation {
      draft.currency = defaultCurrency
      currencyFromDefaults = defaultCurrency
    }
  }

  /// The default currency given when the model was made; the app reads the setting afresh
  /// instead (`readsDefaultCurrency`), since Settings may change it while the line lives.
  private let fixedDefaultCurrency: CurrencyCode
  /// Where the default currency is read from: the app's setting, handed over in
  /// `init(environment:)`.
  var readsDefaultCurrency: (() -> CurrencyCode)?
  /// The currency of everything new («Валюта по умолчанию»), or the currency of the trip while
  /// the trip mode is on.
  private var defaultCurrency: CurrencyCode {
    readsTripDefaults?()?.currency ?? readsDefaultCurrency?() ?? fixedDefaultCurrency
  }
  /// Where the defaults of the trip mode are read from (`AppEnvironment.tripEntryDefaults`);
  /// without it the entry knows no trip.
  var readsTripDefaults: (() -> TripMode.EntryDefaults?)?
  /// The event the trip mode laid on the first part, which is no choice of the owner: it does
  /// not make the draft carry a choice, and the next operation lays it again.
  private var eventFromDefaults: UUID?
  /// Lays the event of the trip on the first part of a new operation.
  private func layTheTripEvent() {
    guard !editsSavedOperation, draft.parts.count == 1, draft.parts[0].eventId == nil,
      let event = readsTripDefaults?()?.eventId
    else { return }
    draft.parts[0].eventId = event
    eventFromDefaults = event
  }
  /// Where the average rate cash was bought at is read from: the rate of an account in a
  /// currency (`CashRate`), or `nil` when the account has none. The app hands it over in
  /// `init(environment:)`; without it the rate of the day is used as for any account.
  var readsCashRate: ((PaymentMethod, CurrencyCode) -> Decimal?)?
  /// The rate the cash account laid on the draft: it is a default, so a rate the owner typed over
  /// it stays his, and the draft only follows the account's average while it still holds this.
  private var cashRateLaid: Decimal?
  /// The averages read, by account and currency, until the books change.
  private var cashRates: [String: Decimal?] = [:]

  /// Spending cash of a foreign currency is priced in rubles at the weighted average of what the
  /// currency was bought at (decision 0496), not at the rate of the day. A default: the rate field
  /// shows it and the owner's own rate replaces it; an account with no purchase on record, a card,
  /// rubles and an operation that is not spending leave the rate of the day alone.
  private func layTheCashRate() {
    guard !editsSavedOperation else { return }
    var average: Decimal?
    if draft.kind == .expense, !isOnCredit, !isGoalOnly, draft.currency != .rub,
      let account = selectedAccount, account.kind == .cash,
      AccountRules.legCurrency(for: draft.currency, account: account) == nil
    {
      let key = account.id.uuidString + "|" + draft.currency.code
      if let known = cashRates[key] {
        average = known
      } else {
        let read = readsCashRate?(account, draft.currency)
        cashRates[key] = .some(read)
        average = read
      }
    }
    if let average {
      let laid = DecimalMath.round(average, scale: 6)
      guard draft.rate == nil || draft.rate == cashRateLaid else { return }
      draft.rate = laid
      draft.rateDate = calendar.day(of: draft.occurredAt)
      draft.rateSource = .manual
      draft.rateProvisional = false
      cashRateLaid = laid
    } else if let laid = cashRateLaid {
      // The account or the currency changed: the average goes with them, the owner's rate stays.
      if draft.rate == laid {
        draft.rate = nil
        draft.rateDate = nil
        draft.rateSource = nil
      }
      cashRateLaid = nil
    }
  }

  /// The account whose screen is open, if any: a new operation goes to it unless the line or
  /// the panel names another. The app hands it over in `init(environment:)`.
  var openAccountScreen: (() -> UUID?)?
  /// The cache of the bank's rates, which «Списано со счёта» is prefilled from. The app hands
  /// it over in `init(environment:)`; without it nothing in another currency is prefilled.
  var rateTable: (() -> RateTable)?
  /// Where the cards and the cashback rules are read from: the database of the app, handed over
  /// in `init(environment:)`. Without it the panel knows no card and expects no cashback.
  var readsCards: (() -> (cards: [PaymentCard], rules: [CashbackRule]))?
  /// The accounts and cards the pickers leave out while the hidden accounts are covered. Handed
  /// over in `init(environment:)`; without it every account is offered.
  var readsCovered: (() -> (accounts: Set<UUID>, cards: Set<UUID>))?

  /// The panel as the application makes it — for the entry line and for the editor of a
  /// saved operation alike: the repositories, the calendar, the owner's setting for events,
  /// and the category model the pipeline trains («1. история;
  /// 2. модель; 3. ручной выбор»). Both go through here, so neither can leave one out.
  convenience init(environment: AppEnvironment, editsSavedOperation: Bool = false) {
    self.init(
      references: environment.references,
      transactions: environment.transactions,
      calendar: environment.calendar,
      assignsEventAutomatically: environment.assignsEventAutomatically,
      editsSavedOperation: editsSavedOperation,
      defaultCurrency: environment.defaultCurrency)
    readsDefaultCurrency = { [weak environment] in environment?.defaultCurrency ?? .rub }
    readsTripDefaults = { [weak environment] in environment?.tripEntryDefaults }
    if !editsSavedOperation {
      draft.currency = defaultCurrency
      currencyFromDefaults = defaultCurrency
      layTheTripEvent()
    }
    // Only a new operation follows the account screen: a saved one keeps its account.
    if !editsSavedOperation {
      openAccountScreen = { [weak environment] in environment?.focusedAccountId }
    }
    rateTable = { [weak environment] in (try? environment?.rates?.table()) ?? RateTable() }
    readsCashRate = { [weak environment] account, currency in
      guard let writer = environment?.stack?.writer else { return nil }
      let transfers =
        (try? TravelRepository(writer: writer).transfersInto(
          account: account.id, currency: currency))
        ?? []
      return CashRate.rate(spendingFrom: account, in: currency, transfers: transfers)
    }
    readsCovered = { [weak environment] in
      guard let shield = environment?.shield else { return ([], []) }
      return (shield.covering.ids, shield.coveredCardIds)
    }
    readsCards = { [weak environment] in
      guard let writer = environment?.stack?.writer else { return ([], []) }
      let repository = CardRepository(writer: writer)
      return (
        (try? repository.cards(includeArchived: true)) ?? [], (try? repository.rules()) ?? []
      )
    }
    readsCashbackCategory = { [weak environment] in
      (try? environment?.settings?.string(AnalyticsSettings.cashbackCategoryKey))
        .flatMap { $0 }.flatMap(UUID.init(uuidString:))
    }
    predictor = environment.categoryModel
    // The rate is read from the cache only: asking the bank is the save's business, not a
    // keystroke's.
    converting = { [weak environment] draft in
      var rated = draft
      guard let environment else {
        return Conversion(draft: rated, rubles: { _ in throw MoneyConversionError.rateMissing })
      }
      if rated.currency != .rub, rated.rateSource != .manual {
        AppEnvironment.applyRate(
          to: &rated, from: RateTable(rates: (try? environment.rates?.allRates()) ?? []),
          calendar: environment.calendar)
      }
      return Conversion(draft: rated, rubles: environment.rublesConverter(for: rated))
    }
  }

  public func reload() {
    reloadQualityRules()
    cachedRates = nil
    cashRates = [:]
    let covered: (accounts: Set<UUID>, cards: Set<UUID>) = readsCovered?() ?? ([], [])
    if let read = readsCards?() {
      cards = read.cards.filter { !covered.cards.contains($0.id) }
      cashbackRules = read.rules
    }
    guard let references else { return }
    people = (try? references.people()) ?? []
    let everyPlace = (try? references.places(includeArchived: true)) ?? []
    places = everyPlace.filter { !$0.archived }
    archivedPlaces = everyPlace.filter(\.archived)
    allAccounts = (try? references.paymentMethods(includeArchived: true)) ?? []
    banks = (try? references.banks(includeArchived: true)) ?? []
    // A saved operation on a hidden account still finds its account in `allAccounts`; the
    // pickers (`paymentMethods`) do not offer it while it is covered.
    paymentMethods = allAccounts.filter { !$0.archived && !covered.accounts.contains($0.id) }
    events = (try? references.events()) ?? []
    goals = (try? references.goals()) ?? []
    debts = (try? references.debts()) ?? []
    allDebts = (try? references.debts(includeClosed: true, includeDeleted: true)) ?? debts
    if let readsCashbackCategory { cashbackCategoryId = readsCashbackCategory() }
    // The accounts and the cashback category may have changed how the bank pays.
    followTheIncomeMonth()
  }

  // MARK: Places and debts of a saved operation

  /// A place of the menu: an archived one is shown only for an operation already at it, and says
  /// so.
  public struct PlaceChoice: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let archived: Bool
  }

  /// What the place menu offers: the live places, and the one the operation is at when it has
  /// gone to the archive since — the operation keeps it, and the menu shows it instead of
  /// nothing.
  public var placeChoices: [PlaceChoice] {
    var choices = places.map { PlaceChoice(id: $0.id, name: $0.name, archived: false) }
    if let current = draft.placeId, !places.contains(where: { $0.id == current }),
      let archived = archivedPlaces.first(where: { $0.id == current })
    {
      choices.append(PlaceChoice(id: archived.id, name: archived.name, archived: true))
    }
    return choices
  }

  /// What became of a debt the menu shows for an operation that pays it.
  public enum DebtState: Hashable, Sendable {
    case open
    case closed
    case deleted
  }

  /// A debt of the menu.
  public struct DebtChoice: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let state: DebtState
  }

  /// What the debt menu offers: the open debts, and the debt the operation pays when it has been
  /// closed or deleted since — the payment keeps it unless another one is picked.
  public var debtChoices: [DebtChoice] {
    var choices = debts.map { DebtChoice(id: $0.id, name: $0.name, state: .open) }
    if let current = draft.debtId, !debts.contains(where: { $0.id == current }),
      let gone = allDebts.first(where: { $0.id == current })
    {
      choices.append(
        DebtChoice(id: gone.id, name: gone.name, state: gone.isDeleted ? .deleted : .closed))
    }
    return choices
  }

  // MARK: Cards and cashback

  /// The live cards, the only ones anything new may name.
  var liveCards: [PaymentCard] { cards.filter { !$0.archived } }

  /// A choice of the account picker: an account, or a card under it.
  public struct AccountChoice: Hashable, Sendable {
    public let id: UUID
    /// «Т-Банк», «Т-Банк › Black».
    public let name: String
    public let isCard: Bool
    /// A card gone to the archive, shown only for the operation that names it.
    public let archived: Bool
  }

  /// What the account picker offers: each account as `accountChoices` gives it, followed by its
  /// live cards as «Т-Банк › Black». The card the operation names when it has gone to the
  /// archive since stays under its account, and says so. A kind that names no card — money
  /// back — is offered the accounts alone.
  public func accountCardChoices(locale: Locale) -> [AccountChoice] {
    let accounts = accountChoices(locale: locale)
    let offered = has(.card) ? cards : []
    var items = AccountCardChoices.items(
      accounts: accounts, cards: offered, banks: banks, among: allAccounts, locale: locale
    ).map {
      AccountChoice(id: $0.id, name: $0.name, isCard: $0.isCard, archived: false)
    }
    if has(.card), let cardId = draft.cardId,
      !items.contains(where: { $0.id == cardId && $0.isCard }),
      let card = cards.first(where: { $0.id == cardId }), card.archived,
      let index = items.firstIndex(where: { $0.id == card.accountId && !$0.isCard })
    {
      let name = items[index].name + AccountLabels.separator + card.name
      items.insert(
        AccountChoice(id: card.id, name: name, isCard: true, archived: true), at: index + 1)
    }
    return items
  }

  /// What the account picker shows: the card the operation names, else its account — the
  /// account alone for a kind that names no card, whatever card the draft kept from before.
  public var accountOrCardSelection: UUID? {
    let account = selectedAccount?.id
    guard has(.card), let cardId = draft.cardId,
      cards.contains(where: { $0.id == cardId && $0.accountId == account })
    else { return account }
    // A card the list does not offer as a choice of its own — the only card of its account, one
    // called like its account or its bank — is shown as the account (`AccountLabels`).
    return accountCardChoices(locale: .current).contains { $0.id == cardId } ? cardId : account
  }

  /// A choice of the account picker: a card brings its account, an account names no card. Either
  /// is the owner's, as an account picked is. A kind that names no card takes the account alone.
  public func setAccountOrCard(_ id: UUID?) {
    let resolved = CardRules.resolve(selection: id, cards: cards)
    setPaymentMethod(resolved.accountId)
    draft.cardId = has(.card) ? resolved.cardId : nil
    cardFromDefaults = nil
    if resolved.cardId != nil {
      // A card picked: «Карта».
      paysFromAccount = false
      paysFromAccountByTheLine = false
    } else {
      // An account picked: its main card, unless «Счёт» was chosen.
      layTheCard(placeCard: nil, force: true)
    }
  }

  /// What the owner typed in «Кэшбэк»: an amount, a percent, or nothing. The operation keeps
  /// what it says (`draft.cashback`) as the draft changes — a percent follows the amount.
  var cashbackField = CashbackFieldState() {
    didSet { followTheCashbackField() }
  }

  /// The figure of the field written into the draft: the save — of the line and of the editor
  /// alike — writes what the field says. An empty or unreadable field keeps no figure: the rules
  /// then say what to expect, and the operation is saved all the same.
  private func followTheCashbackField() {
    let value = isOnCredit ? nil : cashbackField.value(on: draft, rounding: cashbackRounding)
    if draft.cashback != value { draft.cashback = value }
  }

  /// Whether the panel shows «Кэшбэк»: a purchase that moves money on its account. Not one on
  /// credit — the lender paid —, and not the difference of a count.
  public var showsCashback: Bool {
    has(.cashback) && !isOnCredit && !isReconcileDifference
  }

  private var mainAccountId: UUID? { paymentMethods.first(where: \.isDefault)?.id }

  /// Whose rules price the operation: the card it names, else its account.
  public var cashbackHolder: CashbackHolder? {
    CashbackHolders.holder(
      accountId: draft.paymentMethodId, cardId: draft.cardId, mainAccountId: mainAccountId)
  }

  /// How the bank of the operation's account rounds what it pays.
  private var cashbackRounding: CashbackRounding {
    let account = draft.paymentMethodId ?? mainAccountId
    return allAccounts.first { $0.id == account }?.cashbackRounding ?? .standard
  }

  /// The rules of every account and card, with how each account rounds.
  private func cashbackBook(tree: CategoryTree) -> CashbackRuleBook {
    CashbackRuleBook(rules: cashbackRules, tree: tree, cards: cards, accounts: allAccounts)
  }

  /// What the field needs to know of the operation to say where a figure comes from.
  var cashbackContext: CashbackFieldContext {
    let holder = cashbackHolder
    let accountId = holder.flatMap { CashbackHolders.account(of: $0, cards: cards) }
    let filed = Set(draft.parts.map(\.categoryId))
    let named = (filed.count == 1 ? filed.first : nil) ?? nil
    var names: [UUID: String] = [:]
    for category in categories + archivedCategories { names[category.id] = category.name }
    let book = cashbackBook(tree: categoryTree)
    return CashbackFieldContext(
      holder: holder,
      holderName: holder.map {
        CardText.holderName($0, cards: cards, accounts: allAccounts)
      },
      month: calendar.day(of: draft.occurredAt).monthKey,
      categoryId: named, accountId: accountId,
      movedCurrency: CashbackMath.movedMoney(of: draft).currency,
      mixedCategories: filed.count > 1,
      rules: holder.map { book.effectiveRules(of: $0) } ?? [],
      ownRules: holder.map { book.rules(of: $0) } ?? [],
      rounding: cashbackRounding, categoryNames: names)
  }

  /// What the operation is expected to earn: the figure typed for it, else what the rules of
  /// its holder give; `nil` when it earns nothing.
  public var cashbackExpectation: CashbackExpectation? {
    let tree = categoryTree
    return CashbackMath.expected(
      draftForSaving, holder: cashbackHolder, book: cashbackBook(tree: tree), tree: tree,
      calendar: calendar)
  }

  /// «Запомнить»: the typed percent becomes a rule — of the account, or of the card where the
  /// card differs from its account —, written by `write` as a step of ⌘Z of its own; once it
  /// is, the field is emptied — the rule says it now.
  @discardableResult
  func rememberCashback(
    _ rule: CashbackRule, writing write: (CashbackRule) -> CardActionOutcome
  ) -> CardActionOutcome {
    let outcome = write(rule)
    guard outcome == .done else { return outcome }
    if let read = readsCards?() {
      cards = read.cards
      cashbackRules = read.rules
    }
    cashbackField = CashbackFieldState()
    return outcome
  }

  // MARK: A difference of a count

  /// The saved operation is the difference a count of an account records («Сверка»): its money
  /// follows the books by itself, so the panel locks its amount, kind, account, currency, rate
  /// and date, and offers it no category under Goals or of the app.
  public private(set) var isReconcileDifference = false

  /// Reads what the saved operation just opened is: the one whose first part the draft holds,
  /// found among the operations of its day. Parts made in the panel — a split — are no saved
  /// operation, and leave what was read as it was.
  private func noteWhatWasOpened() {
    guard let transactions, let partId = draft.parts.first?.id else { return }
    let day = calendar.day(of: draft.occurredAt)
    let from = calendar.startOfDay(day)
    let to = calendar.startOfDay(day.adding(days: 1))
    let entries = (try? transactions.entries(from: from, to: to)) ?? []
    guard let opened = entries.first(where: { $0.parts.contains { $0.id == partId } }) else {
      return
    }
    isReconcileDifference = Self.isReconcileDifference(opened.transaction)
  }

  /// A difference of a count carries the key `reconcile:<reconciliation>:<count>`.
  static func isReconcileDifference(_ transaction: CoreKit.Transaction) -> Bool {
    transaction.externalId?.hasPrefix("reconcile:") == true
  }

  /// What a quality is decided by: my manual ratings and the categories. Both change behind
  /// the back of a model that lives as long as the entry line — a bulk rating from the list,
  /// a rating in the edit sheet, ⌘Z, a category re-rated or archived in Settings — so they
  /// are asked for again every time the defaults are worked out, not only when the model is
  /// made. The ratings come from the repository's cache, read again only after a write:
  /// this runs at every change of a picker in the panel.
  private func reloadQualityRules() {
    qualityHistory = (try? transactions?.manualQualityHistory()) ?? .empty
    guard let references else { return }
    let allCategories = (try? references.categories(includeArchived: true)) ?? []
    categories = allCategories.filter { !$0.archived }
    archivedCategories = allCategories.filter(\.archived)
  }

  // MARK: Parsed line

  /// Fills the draft from a parsed entry line, keeping whatever the panel already set: its
  /// kind, place, payment method, people, event, goal — and its amount, note and date, which the
  /// line takes over only while the panel has left them as the line wrote them. A date the line
  /// names always wins, and so does an amount other than the one the line said before. A line
  /// without an amount (`parsed.amount` nil) leaves the amount alone, whatever `amount` says.
  ///
  /// `text` is the line as typed: Enter's stop for a category is remembered by it
  /// (`gapToAsk`), since the same text parses anew once «Добавить…» made a name in it known.
  ///
  /// `whileTyping`: the open panel reads the line at a keystroke, not at Enter. What such a
  /// reading fills from a word the next reading takes back once the line no longer names it —
  /// the word was only half typed (`TypedFills`).
  public func apply(
    _ reading: InputLineReading, amount: AmountE4, today: DateOnly, text: String? = nil,
    whileTyping: Bool = false
  ) {
    timeOfTheLine = reading.timeOfDay
    defer { timeOfTheLine = nil }
    apply(reading.parsed, amount: amount, today: today, text: text, whileTyping: whileTyping)
    takeTheCashback(of: reading)
    takeTheSelfEmployment(of: reading)
    takeTheTerms(of: reading)
    takeTheDiscount(of: reading)
  }

  /// The time of day the line being applied names («в 18:09»): the moment is that time of the
  /// day the line names, or of today.
  private var timeOfTheLine: TimeOfDay?
  /// What the line last wrote into «Кэшбэк». While the field still says it, the next line writes
  /// its own — or empties the field when it names none —; a figure typed in the panel stays.
  private var cashbackFromTheLine: String?

  /// «кэшбек 9.76», «кэшбек 3%»: the figure goes into «Кэшбэк» as if typed there — a percent is
  /// turned into money by the account's rounding when the operation is written. An operation
  /// without a cashback gets the words back in its note.
  private func takeTheCashback(of reading: InputLineReading) {
    let typed: String? = reading.cashback.map { cashback in
      switch cashback {
      case .amount(let amount): NumberText.plain(amount)
      case .percent(let percent): NumberText.plain(percent) + "%"
      }
    }
    if typed != nil, !showsCashback {
      if let phrase = reading.cashbackPhrase, !phrase.isEmpty, draft.note == noteFromTheLine,
        !(draft.note ?? "").contains(phrase)
      {
        let note = [draft.note ?? "", phrase].filter { !$0.isEmpty }.joined(separator: " ")
        draft.note = note
        noteFromTheLine = note
      }
      return
    }
    guard cashbackField.text.isEmpty || cashbackField.text == cashbackFromTheLine else { return }
    if let typed {
      cashbackField.text = typed
      cashbackFromTheLine = typed
    } else if cashbackFromTheLine != nil {
      cashbackField.text = ""
      cashbackFromTheLine = nil
    }
  }

  public func apply(
    _ parsed: ParsedInput, amount: AmountE4, today: DateOnly, text: String? = nil,
    whileTyping: Bool = false
  ) {
    // A purchase picked for a refund — or «Без покупки» — belongs to the line it was picked
    // for: Enter on that line again keeps it, any other line starts without it, so a refund
    // of headphones is never saved against the sneakers picked for the line before.
    if refundTarget != nil || refundWithoutPurchase || pickBase != nil {
      if parsed == lineOfThePick { return }
      forgetTheRefundedPurchase()
      refundWithoutPurchase = false
    }
    defer {
      lastLine = parsed
      lastLineText = text
    }
    takeBackWhatTheTypedLineNoLongerSays(parsed)
    let before = TypedState(of: self)
    // A kind chosen in the panel is not overwritten by a line that says nothing about it:
    // the parser reports `.expense` both when it read nothing and when it read "расход".
    if parsed.kind != .expense || draft.kind == .expense {
      draft.kind = parsed.kind
    }
    if parsed.amount != nil { takeTheAmount(amount, of: parsed) }
    // A currency the line names is the owner's: it beats the account's and the default one.
    if let typed = parsed.currency {
      draft.currency = typed
      currencyFromDefaults = nil
    }
    // A name the dictionaries do not know leaves the note like every word the parser read,
    // but nothing else keeps it: it goes back into the note as typed, and Enter no longer
    // saves «кофе» for «кофе 300 в Кофемании».
    unmatchedPersonPhrase = parsed.unknownPersonName == nil ? nil : parsed.unknownPersonPhrase
    unmatchedPlacePhrase = parsed.unknownPlaceName == nil ? nil : parsed.unknownPlacePhrase
    draft.placeId = parsed.placeId ?? draft.placeId
    // «со счёта»: no card; a line that no longer says it gives the card back. A card the line
    // names is a card all the same.
    if parsed.withoutCard, parsed.cardId == nil {
      paysFromAccount = true
      paysFromAccountByTheLine = true
      draft.cardId = nil
      cardFromDefaults = nil
    } else if paysFromAccountByTheLine || parsed.cardId != nil {
      paysFromAccount = false
      paysFromAccountByTheLine = false
    }
    if let named = parsed.paymentMethodId {
      draft.paymentMethodId = named
      paymentMethodFromDefaults = nil
      accountFromTheScreen = false
      // A card named in the line brings its account; the account named alone keeps only a card
      // of its own the panel had chosen.
      draft.cardId =
        parsed.cardId ?? CardRules.cardAfterAccountChange(draft.cardId, to: named, cards: liveCards)
      if parsed.cardId != nil { cardFromDefaults = nil }
    }
    draft.debtId = parsed.debtId ?? draft.debtId
    if parsed.date != nil || timeOfTheLine != nil || draft.occurredAt == dateFromTheLine {
      draft.occurredAt = occurredAt(for: parsed.date, at: timeOfTheLine, today: today)
      dateFromTheLine = draft.occurredAt
      dateFollowsTheClock = timeOfTheLine == nil && (parsed.date == nil || parsed.date == today)
    }
    suggestedPersonName = parsed.unknownPersonName
    suggestedPlaceName = parsed.unknownPlaceName
    draft.normalizeSinglePart()
    draft.parts[0].forWhom = parsed.forWhom ?? draft.parts[0].forWhom
    draft.parts[0].forPersonId = parsed.personId ?? draft.parts[0].forPersonId
    if let person = parsed.personId,
      let words = parsed.tokens.first(where: { $0.role == .person })?.text
    {
      personPhraseFromTheLine = (person, words)
    }
    // «Для кого» the line names — «себе» too — is the owner's word, not history's.
    if parsed.forWhom != nil || parsed.personId != nil { forWhomFromDefaults = nil }
    draft.parts[0].eventId = parsed.eventId ?? draft.parts[0].eventId
    // A goal the line names files the part under it, as a contribution from Planning is.
    if let goalId = parsed.goalId { setGoal(goalId, forPartAt: 0) }
    // What the kind has no field for is left out, and the words that named it go to the note:
    // «+5000 для мамы» is income of 5 000 noted «для мамы».
    let leftOut = leaveOutWhatTheKindHasNot(saying: parsed)
    let lineNote = [parsed.note, unmatchedPersonPhrase ?? "", unmatchedPlacePhrase ?? ""]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let fullNote = ([lineNote] + leftOut).filter { !$0.isEmpty }.joined(separator: " ")
    if !fullNote.isEmpty, draft.note == noteFromTheLine {
      draft.note = fullNote
      noteFromTheLine = fullNote
    } else if !leftOut.isEmpty, let note = draft.note {
      // A note of the owner's keeps its words, and gets the left-out ones once.
      let missing = leftOut.filter { !note.contains($0) }
      if !missing.isEmpty { draft.note = ([note] + missing).joined(separator: " ") }
    }
    applyDefaults(today: today)
    // «за машу», «пополам с машей», «угостил машу»: the parts laid out for it. A name the
    // dictionary does not know waits for «Добавить человека…».
    if let paying = parsed.payingFor, let person = paying.personId, offersPayingFor {
      switch paying.way {
      case .forSomebody: choosePayingFor(.somebody(person, paysBack: true))
      case .gift: choosePayingFor(.somebody(person, paysBack: false))
      case .half: choosePayingFor(.half(person))
      }
    } else {
      relayPayingFor()
    }
    // After the defaults, so what the next reading compares is what the panel shows.
    typedFills = whileTyping ? recordingTypedFills(of: parsed, before: before) : TypedFills()
  }

  // MARK: За кого

  /// «За кого» as chosen — in the panel or by the line —, kept so the parts follow the amount:
  /// the parts are the truth, and this only says how to lay them out again (`PayingForRules`).
  public private(set) var payingFor: PayingFor = .me

  /// The way chosen in the panel before anybody was: «За другого», «Пополам» or «Поровну» with
  /// no person yet. The parts stay mine until a person is chosen.
  public var payingForWay: PayingForWay?

  public enum PayingForWay: String, CaseIterable, Sendable {
    case me, somebody, half, evenly
  }

  /// The way the panel shows: what the parts say, else what was chosen without a person.
  public var shownPayingForWay: PayingForWay {
    if let payingForWay { return payingForWay }
    switch payingFor {
    case .me: return .me
    case .somebody: return .somebody
    case .half: return .half
    case .evenly: return .evenly
    }
  }

  /// «За кого» is there for an expense that can be paid for somebody, while its parts are laid
  /// out one of the four ways — not over a split by categories.
  public var offersPayingFor: Bool {
    draft.kind == .expense && canMarkPaidForSomeone && !isGoalOnly
      && (PayingForRules.reading(of: draft) != nil || payingFor != .me)
  }

  /// The parts laid out for `choice`: one step, and the qualities of new parts resolved.
  public func choosePayingFor(_ choice: PayingFor) {
    payingFor = choice
    payingForWay = nil
    draft = PayingForRules.laying(choice, on: draft)
    for index in draft.parts.indices where draft.parts[index].quality == nil {
      resolveQuality(ofPartAt: index, in: categoryTree)
    }
  }

  /// The amount changed: the shares follow it.
  public func relayPayingFor() {
    guard payingFor != .me, draft.kind == .expense else { return }
    let laid = PayingForRules.laying(payingFor, on: draft)
    if laid != draft { draft = laid }
  }

  /// The people of the choice, in their order: one for «За другого» and «Пополам», each of
  /// «Поровну».
  public var payingForPeople: [UUID] {
    switch payingFor {
    case .me: []
    case .somebody(let person, _), .half(let person): [person]
    case .evenly(let people): people
    }
  }

  /// What was answered to «Вернёт ли человек деньги?» for each person before. Tests give it a
  /// defaults of their own.
  var paysBackMemory = PaysBackMemory()

  /// «Вернёт?» of «За другого»: yes — owed to me; no — a gift.
  public var payingForPaysBack: Bool {
    if case .somebody(_, let paysBack) = payingFor { return paysBack }
    return true
  }

  /// The way of «За кого» chosen in the panel: «Себе» lays the parts out at once, the others
  /// once a person is chosen — with the person already chosen, at once.
  public func choosePayingForWay(_ way: PayingForWay) {
    let people = payingForPeople
    switch way {
    case .me: choosePayingFor(.me)
    case .somebody:
      if let first = people.first {
        choosePayingFor(.somebody(first, paysBack: payingForPaysBack))
      } else {
        payingForWay = way
      }
    case .half:
      if let first = people.first { choosePayingFor(.half(first)) } else { payingForWay = way }
    case .evenly:
      if !people.isEmpty { choosePayingFor(.evenly(people)) } else { payingForWay = way }
    }
  }

  /// A person chosen in a menu of «За кого»: `slot` is the place in «Поровну», one past the end
  /// for one more; nil takes a person of «Поровну» away.
  public func setPayingForPerson(_ person: UUID?, slot: Int) {
    let way = shownPayingForWay
    var people = payingForPeople
    if let person {
      if slot < people.count { people[slot] = person } else { people.append(person) }
    } else if slot < people.count {
      people.remove(at: slot)
    }
    switch way {
    case .me: return
    case .somebody:
      guard let first = people.first else { return choosePayingFor(.me) }
      // The answer given for this person before is the one offered; the question stays asked.
      let paysBack =
        payingForPeople.first == first
        ? payingForPaysBack : (paysBackMemory.answer(for: first) ?? payingForPaysBack)
      choosePayingFor(.somebody(first, paysBack: paysBack))
    case .half:
      guard let first = people.first else { return choosePayingFor(.me) }
      choosePayingFor(.half(first))
    case .evenly:
      if people.isEmpty {
        choosePayingFor(.me)
        payingForWay = .evenly
      } else {
        choosePayingFor(.evenly(people))
      }
    }
  }

  public func setPaysBack(_ paysBack: Bool) {
    guard case .somebody(let person, _) = payingFor else { return }
    paysBackMemory.remember(paysBack, for: person)
    choosePayingFor(.somebody(person, paysBack: paysBack))
  }

  /// The choice the parts of a saved operation say, when the editor opens it.
  public func readPayingFor() {
    payingFor = PayingForRules.reading(of: draft) ?? .me
    payingForWay = nil
  }

  /// The amount of the line, kept with its formula — its numbers written the way the app writes
  /// them: «1500,5+2» is «1,500.5+2» — unless the panel changed the one the line wrote before
  /// and the line still says that one: then the panel's is the owner's, and stays.
  private func takeTheAmount(_ amount: AmountE4, of parsed: ParsedInput) {
    let said = LineAmount(
      amount: amount,
      expression: parsed.amountExpression.map { ExpressionEvaluator.canonical($0) ?? $0 })
    let changedInThePanel =
      amountFromTheLine.map {
        draft.amount != $0.amount || draft.amountExpression != $0.expression
      } ?? false
    guard said != amountFromTheLine || !changedInThePanel else { return }
    draft.amount = amount
    zeroWasTyped = amount.isZero
    followTheAmountInTheCreditPlan()
    draft.amountExpression = said.expression
    amountFromTheLine = said
  }

  // MARK: Fields of the kind

  /// The fields an operation of this kind has (`KindFields`): the panel shows these and no
  /// other, and the save leaves every other one out. Income has no place, event, «на кого»,
  /// «за другого» or credit; a contribution to a goal has nothing charged on its account.
  public var fields: Set<OperationField> {
    KindFields.fields(of: draft.kind, goalOnly: isGoalOnly)
  }

  public func has(_ field: OperationField) -> Bool { fields.contains(field) }

  /// Takes away what the kind of the draft has no field for, and returns the words of the line
  /// that had named it, for the note. A name the dictionaries did not know is in the note
  /// already, and is no longer offered for a field the kind does not have.
  private func leaveOutWhatTheKindHasNot(saying parsed: ParsedInput) -> [String] {
    var words: [OperationField: [String]] = [:]
    for token in parsed.tokens {
      guard let field = Self.field(of: token.role) else { continue }
      words[field, default: []].append(token.text)
    }
    let (stripped, toNote) = KindFields.stripped(draft, words: words, tree: categoryTree)
    draft = stripped
    if !has(.forPerson), !has(.fromPerson) { suggestedPersonName = nil }
    if !has(.place) { suggestedPlaceName = nil }
    return toNote
  }

  /// The field a word of the line set.
  private static func field(of role: ParsedRole) -> OperationField? {
    switch role {
    case .place: .place
    case .event: .event
    case .forWhom: .forWhom
    case .person: .forPerson
    case .goal: .goal
    case .debt: .debt
    case .paymentMethod: .account
    case .amount, .currency, .date, .kind, .note: nil
    }
  }

  /// The draft as it is written: without what its kind has no field for — a place chosen in
  /// the panel before the kind became income stays out of the income —, and an income that names
  /// a debt owed to me as money back (`incomeIsMoneyBack`). Stored rows keep what they have;
  /// this is for a new operation only.
  public var draftForSaving: TransactionDraft {
    var written = draft
    if incomeIsMoneyBack { written.kind = .reimbursement }
    return KindFields.stripped(written, tree: categoryTree).draft
  }

  /// An income that names an open debt owed to me is money given back on it: the debt takes what
  /// is left of it and closes, and what is over is income in «Доплаты» — one rule for every way
  /// of recording it (`DebtRules.repayment`), and the debt's payment is not income. A saved
  /// operation is changed in its editor and keeps its kind.
  public var incomeIsMoneyBack: Bool {
    guard !editsSavedOperation, draft.kind == .income, let id = draft.debtId else { return false }
    return debts.contains { $0.id == id && $0.direction == .owedToMe && !$0.closed }
  }

  /// Whether the model suggests and files from history and from the category model: the line
  /// does, and the form at the side of the window never does — its category, people and account
  /// are what the owner chooses (`EntryStyle`).
  public var assisted = true

  /// Defaults from history and from the dictionaries, in the order of the panel.
  public func applyDefaults(today: DateOnly) {
    guard !draft.parts.isEmpty else { return }
    reloadQualityRules()
    dropTheCreditTheKindCannotCarry()
    dropTheRefundTheKindCannotCarry()

    // A category of the other kind is dropped first: after switching an expense to income
    // it would match nothing the picker offers and file the money on the wrong side.
    dropCategoriesOfTheOtherKind()

    // The operation most like this one — the same place or the same words — brings its
    // category («1. история: то же место или то же описание → последняя категория»), only
    // while none is chosen, and only one that can still be chosen: of the right kind and not
    // retired since.
    let history = assisted ? otherOperations() : []
    if let alike = mostAlike(in: history), draft.parts[0].categoryId == nil,
      let categoryId = alike.parts.first?.categoryId, isOffered(categoryId)
    {
      draft.parts[0].categoryId = categoryId
      draft.parts[0].categorySource = .history
      nameTheGoal(ofPartAt: 0)
    }

    // «Для кого»: «по умолчанию «Я»; по истории (то же место или описание → последний мой
    // выбор); из строки ввода».
    layForWhom(from: history)

    // The account, unless the line named one or the owner chose one by hand: the one whose
    // screen is open, else the last one used at that place, else the main account.
    if draft.paymentMethodId == nil || draft.paymentMethodId == paymentMethodFromDefaults {
      // A place the kind has no field for — chosen before the kind became income — is hidden,
      // and chooses nothing.
      let place = has(.place) ? draft.placeId : nil
      let (chosen, screen) = accountByDefault(at: place, in: history)
      draft.paymentMethodId = chosen
      paymentMethodFromDefaults = chosen
      accountFromTheScreen = screen != nil && chosen == screen
      // The card that paid at the place last time, while it is of the account laid now. It is
      // what paid, not a choice of the owner's: the currency stays the one the defaults lay.
      let lastAtPlace = place.flatMap { place in
        history.first { $0.transaction.placeId == place }
      }.map { (accountId: $0.transaction.paymentMethodId, cardId: $0.transaction.cardId) }
      let placeCard =
        has(.card)
        ? CardRules.cardForNewOperation(
          chosenAccount: chosen, lastAtPlace: lastAtPlace, cards: cards)
        : nil
      draft.cardId = placeCard
      cardFromDefaults = placeCard
    }
    // A purchase is made with a card unless it says «со счёта»: the main card of its account,
    // the one account the line named or the owner picked too (`CardRules.operationCard`).
    layTheCard(placeCard: draft.cardId == cardFromDefaults ? draft.cardId : nil)
    layTheCurrency()

    // An event covering the date of the operation is offered; it is applied only when
    // the owner turned that on in the settings.
    let day = calendar.day(of: draft.occurredAt)
    suggestedEvent = events.first { $0.covers(day) }
    if draft.parts[0].eventId == nil, assignsEventAutomatically {
      draft.parts[0].eventId = suggestedEvent?.id
    }

    // A payment against a debt that records its payments as expenses belongs to the
    // system Loans category — that is how the owner used to keep loans before the app.
    if let debtId = draft.debtId,
      let debt = debts.first(where: { $0.id == debtId }),
      DebtRules.paymentIsExpense(on: debt),
      draft.kind.categoryKind == .expense,
      draft.parts[0].categoryId == nil
    {
      draft.parts[0].categoryId =
        debt.loansSubcategoryId
        ?? categories.first { $0.systemRole == .loans && $0.kind == .expense }?.id
      draft.parts[0].categorySource = .system
    }

    // The model may file the first part now, when it is sure and nothing else did.
    refreshSuggestions()

    // Every part has a quality of its own: the second part of a split in Fees is bad
    // even when the first is ordinary groceries. Worked out after the model filed the part:
    // before, a part the model filed kept the quality of no category.
    let tree = categoryTree
    for index in draft.parts.indices {
      resolveQuality(ofPartAt: index, in: tree)
    }

    // Last: whether the operation moves money at all depends on the categories just laid.
    refreshCharge()
  }

  /// Income and a reimbursement have no quality; a goal contribution is always good and
  /// cannot be changed; a rating set by hand stays; a description I rated by hand before
  /// keeps my last rating; everything else takes the quality of its category.
  private func resolveQuality(ofPartAt index: Int, in tree: CategoryTree) {
    guard draft.parts.indices.contains(index) else { return }
    guard hasQuality else {
      draft.parts[index].quality = nil
      draft.parts[index].qualitySource = nil
      return
    }
    let decision = QualityResolver.resolve(
      draft: draft.parts[index], description: draft.note, categories: tree,
      history: qualityHistory)
    draft.parts[index].quality = decision.quality
    draft.parts[index].qualitySource = decision.source
  }

  /// A category whose kind does not match the operation — an expense category on an income
  /// or the other way round — is dropped from every part. A category the dictionary does
  /// not know is left alone: there is nothing to judge it by.
  private func dropCategoriesOfTheOtherKind() {
    for index in draft.parts.indices {
      guard let categoryId = draft.parts[index].categoryId, !fitsTheKind(categoryId) else {
        continue
      }
      draft.parts[index].categoryId = nil
      draft.parts[index].categorySource = .manual
    }
  }

  private func fitsTheKind(_ categoryId: UUID) -> Bool {
    guard let category = category(withId: categoryId) else { return true }
    return category.kind == draft.kind.categoryKind
  }

  /// Could the picker offer this category right now? Only a live category of the kind of
  /// the operation: history never brings back a retired one or one of the other side.
  private func isOffered(_ categoryId: UUID) -> Bool {
    categories.contains { $0.id == categoryId && $0.kind == draft.kind.categoryKind }
  }

  /// Whether the operation is rated at all: spending is, income and a reimbursement are not.
  public var hasQuality: Bool { draft.kind.hasQuality }

  /// A contribution to a goal — by its goal or by sitting under Goals — is always good, so
  /// its quality is not offered for a choice.
  public func canRateByHand(_ part: PartDraft) -> Bool {
    QualityResolver.canRateByHand(
      goalId: part.goalId, categoryId: part.categoryId, categories: categoryTree)
  }

  /// Quality of the subcategory, or of its parent when the subcategory has none.
  public func inheritedQuality(for categoryId: UUID?) -> Quality? {
    categoryTree.effectiveQuality(of: categoryId)
  }

  /// The whole dictionary, archived categories included, for the rules of `CoreAccounting`.
  var categoryTree: CategoryTree { CategoryTree(categories + archivedCategories) }

  /// Any category the operation may point at, archived ones included.
  private func category(withId id: UUID) -> CoreKit.Category? {
    categories.first { $0.id == id } ?? archivedCategories.first { $0.id == id }
  }

  // MARK: Category and subcategory

  // A part keeps a single `categoryId`: the most specific choice made — the subcategory
  // when one is chosen, the top-level category otherwise. The panel shows that as two
  // pickers, and the methods below are the whole translation between the two shapes.

  /// The part a picker is editing, or an empty one when the index is stale.
  public func part(at index: Int) -> PartDraft {
    draft.parts.indices.contains(index) ? draft.parts[index] : PartDraft()
  }

  /// The top-level category of a part: the stored id itself, or the parent of the
  /// subcategory it names.
  public func categoryOfPart(_ part: PartDraft) -> UUID? {
    guard let categoryId = part.categoryId else { return nil }
    // A category the dictionary does not know at all is taken as it is.
    guard let category = category(withId: categoryId) else { return categoryId }
    return category.parentId ?? category.id
  }

  /// The subcategory of a part: the stored id when it names a child, nothing otherwise.
  public func subcategoryOfPart(_ part: PartDraft) -> UUID? {
    guard let categoryId = part.categoryId,
      let category = category(withId: categoryId),
      category.parentId != nil
    else { return nil }
    return category.id
  }

  /// What the category picker of a part offers: the top-level categories of the kind of
  /// the operation, plus the one the part is already filed under when that has been
  /// archived since — the saved operation shows its category, not an empty picker.
  public func categoryOptions(forPartAt index: Int) -> [CoreKit.Category] {
    var options = topLevelCategories(for: draft.kind)
    // A difference of a count stays a difference: never a contribution to a goal, never a
    // category of the app.
    if isReconcileDifference {
      options.removeAll { categoryTree.systemRole(of: $0.id) != nil }
    }
    if let current = categoryOfPart(part(at: index)),
      !options.contains(where: { $0.id == current }),
      let retired = archivedCategories.first(where: { $0.id == current })
    {
      options.append(retired)
    }
    return options
  }

  /// What the subcategory picker of a part offers: the children of its category, plus an
  /// archived child the part is already filed under.
  public func subcategoryOptions(forPartAt index: Int) -> [CoreKit.Category] {
    var options = subcategories(of: categoryOfPart(part(at: index)))
    if let current = subcategoryOfPart(part(at: index)),
      !options.contains(where: { $0.id == current }),
      let retired = archivedCategories.first(where: { $0.id == current })
    {
      options.append(retired)
    }
    return options
  }

  /// Top-level categories an operation of this kind can go into.
  public func topLevelCategories(for kind: TransactionKind) -> [CoreKit.Category] {
    categories.filter { $0.parentId == nil && $0.kind == kind.categoryKind }
  }

  /// Children of a category, in the order the dictionary keeps them.
  public func subcategories(of categoryId: UUID?) -> [CoreKit.Category] {
    guard let categoryId else { return [] }
    return categories.filter { $0.parentId == categoryId }
  }

  /// Choosing a category stores it and drops the subcategory, which belonged to the
  /// category that was there before. Choosing the same category again changes nothing.
  public func setCategory(
    _ id: UUID?, forPartAt index: Int, source: CategorySource = .manual
  ) {
    guard draft.parts.indices.contains(index) else { return }
    guard categoryOfPart(draft.parts[index]) != id else { return }
    draft.parts[index].categoryId = id
    draft.parts[index].categorySource = source
    nameTheGoal(ofPartAt: index)
    shareTheCategoryOfTheFirstPart(index)
  }

  /// «Пополам» and «Поровну»: the shares are one purchase, so the category chosen for the first
  /// part is every share's — chosen in the form, with no line to read again, too.
  private func shareTheCategoryOfTheFirstPart(_ index: Int) {
    guard index == 0, draft.parts.count > 1 else { return }
    switch payingFor {
    case .half, .evenly:
      for other in draft.parts.indices.dropFirst() {
        draft.parts[other].categoryId = draft.parts[0].categoryId
        draft.parts[other].categorySource = draft.parts[0].categorySource
      }
    case .me, .somebody:
      return
    }
  }

  /// Choosing a subcategory stores the child. The dash means the operation hangs on the
  /// category itself, so the stored id goes back to the parent.
  public func setSubcategory(
    _ id: UUID?, forPartAt index: Int, source: CategorySource = .manual
  ) {
    guard draft.parts.indices.contains(index) else { return }
    guard let id else {
      draft.parts[index].categoryId = categoryOfPart(draft.parts[index])
      draft.parts[index].categorySource = source
      shareTheCategoryOfTheFirstPart(index)
      return
    }
    // Only a real child may be stored here: a top-level id would lose the pair silently.
    // An archived child is accepted only when it is the one already there.
    guard let child = category(withId: id), child.parentId != nil,
      !child.archived || draft.parts[index].categoryId == id
    else {
      return
    }
    draft.parts[index].categoryId = child.id
    draft.parts[index].categorySource = source
    nameTheGoal(ofPartAt: index)
    shareTheCategoryOfTheFirstPart(index)
  }

  /// A suggestion taken from history fills both pickers at once: it is stored as the most
  /// specific category, and the pair is read back from it.
  ///
  /// A chip history offered stays history's. A chip the model offered, pressed, is the
  /// owner's choice — `.manual`, evidence for the next training like any choice of theirs —
  /// and not `.history`, which would say history had filed it; that it was the model's
  /// suggestion is for `category_feedback` to keep.
  public func applySuggestion(_ category: CoreKit.Category, forPartAt index: Int = 0) {
    guard draft.parts.indices.contains(index) else { return }
    draft.parts[index].categoryId = category.id
    draft.parts[index].categorySource =
      suggestionSources[category.id] == .model ? .manual : .history
    nameTheGoal(ofPartAt: index)
  }

  /// Where the trained category model waits (step 4 of the pipeline); the app hands it over in
  /// `init(environment:)`. Asking it is a lookup in counters, so typing never waits on anything.
  var predictor: CategoryModelBox?
  /// What the model last said, for the chip's wording and for the quality figures later.
  public private(set) var lastPrediction: CategoryPrediction?
  /// What it was asked then.
  private var lastQuestion: CategoryQuery?

  /// The owner's choice for the first part, the one the model answers for, as
  /// `category_feedback` keeps it («мой выбор пишется в `category_feedback`»): what the model
  /// offered first and how sure it was, what was chosen. Nothing when the model offered
  /// nothing, or the category was not the owner's to choose: left as the model filled it, put
  /// there by the app, or none at all.
  public func categoryChoice(at now: Date = Date()) -> CategoryFeedback? {
    guard let offered = lastPrediction?.suggestions.first, let question = lastQuestion,
      let part = draft.parts.first, let chosen = part.categoryId,
      part.categorySource != .model, part.categorySource != .system
    else { return nil }
    return CategoryFeedback(
      text: question.text, predictedCategoryId: offered.categoryId, chosenCategoryId: chosen,
      partId: part.id, confidenceBp: offered.confidenceBp, at: now)
  }
  /// Where each suggestion came from, so the chip can say — and so a suggestion the model
  /// filled in is marked `.model` and never taught back to it.
  public private(set) var suggestionSources: [UUID: CategorySource] = [:]

  private func refreshSuggestions() {
    guard assisted, let transactions else {
      categorySuggestions = []
      suggestionSources = [:]
      lastQuestion = nil
      lastPrediction = nil
      return
    }
    let words = wordsOfTheDraft
    let recent = (try? transactions.recentEntries(limit: 200)) ?? []
    var counts: [UUID: Int] = [:]
    for entry in recent {
      let sameNote = words != nil && Self.words(of: entry) == words
      let samePlace = draft.placeId != nil && entry.transaction.placeId == draft.placeId
      guard sameNote || samePlace else { continue }
      for part in entry.parts {
        guard let categoryId = part.categoryId else { continue }
        counts[categoryId, default: 0] += 1
      }
    }
    // Only what the picker could hold: a category of another kind or a retired one would be
    // a chip that files the money somewhere it cannot go.
    let fromHistory =
      counts
      .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString }
      .compactMap { pair in categories.first { $0.id == pair.key } }
      .filter { isOffered($0.id) }

    // Level one is history — the same place or the same words, filed the same way before —
    // and it wins over the history and the model. The model fills what is left.
    var sources: [UUID: CategorySource] = [:]
    for category in fromHistory { sources[category.id] = .history }
    var offered = fromHistory
    for category in modelSuggestions() where !offered.contains(where: { $0.id == category.id }) {
      offered.append(category)
      sources[category.id] = .model
    }

    categorySuggestions = Array(offered.prefix(3))
    suggestionSources = sources
    applyTheModelIfItIsSure()
  }

  /// What the model would offer for the draft as it stands.
  private func modelSuggestions() -> [CoreKit.Category] {
    guard let predictor, let query = modelQuery() else {
      // Not asked this time: what it said about the draft before no longer stands.
      lastQuestion = nil
      lastPrediction = nil
      return []
    }
    let candidates = categories.filter { isOffered($0.id) }
    lastQuestion = query
    lastPrediction = predictor.predict(query, among: candidates.map(\.id))
    return lastPrediction?.suggestions.compactMap { suggestion in
      candidates.first { $0.id == suggestion.categoryId }
    } ?? []
  }

  /// «Уверенность не ниже порога → категория подставляется» — but only when nothing is
  /// there yet and history had nothing to say. A suggestion the model made is marked as its
  /// own, so it is never taught back to the model as though the owner had chosen it.
  private func applyTheModelIfItIsSure() {
    guard let prediction = lastPrediction, prediction.appliesTop,
      let best = prediction.suggestions.first,
      suggestionSources[best.categoryId] == .model,
      draft.parts.indices.contains(0), draft.parts[0].categoryId == nil
    else { return }
    draft.parts[0].categoryId = best.categoryId
    draft.parts[0].categorySource = .model
    nameTheGoal(ofPartAt: 0)
  }

  /// The question the model is asked about the first part, built by `LedgerTraining` — the
  /// same code that builds it when the model is taught, so the two cannot drift apart (a test
  /// compares them) — about the draft as the save writes it: the one part the whole amount,
  /// its rate laid on from the cache as the save lays it (`converting`). The amount is in
  /// rubles and the words are the part's own note before the operation's. A foreign amount
  /// with no rate to put it in rubles is not asked about: its bucket would be one the model
  /// was never taught.
  func modelQuery() -> CategoryQuery? {
    guard !draft.parts.isEmpty else { return nil }
    var asked = draft
    // The one part is the whole amount, as it is when it is saved.
    asked.normalizeSinglePart()
    guard let converted = conversion(of: asked), (try? converted.rubles(asked.amount)) != nil
    else { return nil }
    return LedgerTraining.query(draft: converted.draft, calendar: calendar)
  }

  /// How the save turns the draft's money into rubles: its rate laid on as the save lays it,
  /// and the converter of its currency (`AppEnvironment.applyRate`, `rublesConverter`). The
  /// app hands it over in `init(environment:)`.
  var converting: ((TransactionDraft) -> Conversion)?

  /// The draft with its rate, and what turns its amounts into rubles.
  struct Conversion {
    var draft: TransactionDraft
    var rubles: (AmountE4) throws -> AmountE4
  }

  func conversion(of draft: TransactionDraft) -> Conversion? {
    if let converting { return converting(draft) }
    // Made without the app: rubles are rubles, and nothing else can be converted.
    return draft.currency == .rub ? Conversion(draft: draft, rubles: { $0 }) : nil
  }

  /// What history is read from: the last 200 operations, newest first, without the one the
  /// editor has open — a saved operation is not history of itself.
  /// The kind of the latest operations used most: the tile that stretches across the form when
  /// the tiles are odd. Read once per model — the order of the tiles must not jump while typing.
  var mostUsedKindTile: EntryKindTile {
    if let mostUsedKindRead { return mostUsedKindRead }
    let kinds = ((try? transactions?.recentEntries(limit: 200)) ?? []).map(\.transaction.kind)
    let tile = EntryKindTiles.mostUsed(among: kinds)
    mostUsedKindRead = tile
    return tile
  }
  @ObservationIgnored private var mostUsedKindRead: EntryKindTile?

  private func otherOperations() -> [TransactionEntry] {
    guard let transactions else { return [] }
    let own = Set(draft.parts.map(\.id))
    return ((try? transactions.recentEntries(limit: 200)) ?? []).filter { entry in
      !entry.parts.contains { own.contains($0.id) }
    }
  }

  /// The operation the draft is most like, for what history brings: the last one at the same
  /// place with the same words, else the last with the same words, else the last at the same
  /// place. The words come before the place, as in the model's exact match:
  /// «coffee» at the canteen is the coffee of before, not the canteen's last lunch.
  private func mostAlike(in history: [TransactionEntry]) -> TransactionEntry? {
    let words = wordsOfTheDraft
    var best: (entry: TransactionEntry, likeness: Int)?
    for entry in history {
      let sameWords = words != nil && Self.words(of: entry) == words
      let samePlace = draft.placeId != nil && entry.transaction.placeId == draft.placeId
      let likeness = (sameWords ? 2 : 0) + (samePlace ? 1 : 0)
      if likeness > (best?.likeness ?? 0) { best = (entry, likeness) }
      if likeness == 3 { break }
    }
    return best?.entry
  }

  /// «For whom» of the first part from history, while the part still holds what the defaults
  /// laid there: the choice made for the operation of the same kind most like this one, or «Me»
  /// when there is none. Money given back names who paid, not whom it was for,
  /// so a reimbursement neither brings a choice nor takes one: its draft stays at «Me». A person
  /// the picker can no longer offer is left out; the value of the choice stays.
  private func layForWhom(from history: [TransactionEntry]) {
    guard let laid = forWhomFromDefaults, ForWhomChoice(of: draft.parts[0]) == laid else {
      return
    }
    let alike =
      draft.kind == .reimbursement
      ? nil : mostAlike(in: history.filter { $0.transaction.kind == draft.kind })
    let choice = alike?.parts.first.map { part in
      ForWhomChoice(
        value: part.forWhom, personId: part.forPersonId.flatMap { isOfferedPerson($0) ? $0 : nil })
    }
    let chosen = choice ?? .me
    draft.parts[0].forWhom = chosen.value
    draft.parts[0].forPersonId = chosen.personId
    forWhomFromDefaults = chosen
  }

  /// Could the person picker offer this person? Only a live one. The list is read again when
  /// it does not know the person: it was read when the model was made, and people are added in
  /// Settings behind its back.
  private func isOfferedPerson(_ id: UUID) -> Bool {
    if people.contains(where: { $0.id == id }) { return true }
    guard let references, let live = try? references.people() else { return false }
    people = live
    return people.contains { $0.id == id }
  }

  /// «The same description», compared the way rule 2 of the qualities compares it
  /// (`ManualQualityHistory`): the note of the first part, otherwise of the operation, with
  /// case and runs of spaces not counting.
  private var wordsOfTheDraft: String? {
    ManualQualityHistory.normalized(draft.parts.first?.note ?? draft.note)
  }

  private static func words(of entry: TransactionEntry) -> String? {
    ManualQualityHistory.normalized(
      entry.parts.first.flatMap { ManualQualityHistory.description(of: $0, in: entry.transaction) }
        ?? entry.transaction.note)
  }

  private func occurredAt(for day: DateOnly?, at time: TimeOfDay? = nil, today: DateOnly) -> Date {
    if let time { return calendar.moment(day ?? today, hour: time.hour, minute: time.minute) }
    guard let day, day != today else { return Date() }
    return calendar.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  // MARK: Goal

  /// Whether a part contributes to a goal — it names one, or it is filed under Goals — and so
  /// whether the panel shows the goal row («цель — если выбрана категория
  /// Goals»). A named goal counts wherever the part is filed: the goal the line matched is seen,
  /// and a goal left on a part filed elsewhere can be cleared.
  public func isGoalContribution(_ part: PartDraft) -> Bool {
    QualityResolver.isGoalContribution(
      goalId: part.goalId, categoryId: part.categoryId, categories: categoryTree)
  }

  /// A goal chosen — named in the line or picked in the panel — files the part where Planning
  /// files a contribution (`GoalRules.contributionDraft`): under the goal's own subcategory of
  /// Goals, or under Goals itself for a goal that has none. No goal leaves the category alone;
  /// a part still under Goals then asks for one (`saveRefusalKey`).
  public func setGoal(_ goalId: UUID?, forPartAt index: Int) {
    guard draft.parts.indices.contains(index) else { return }
    draft.parts[index].goalId = goalId
    guard let goalId, let categoryId = category(ofGoal: goalId) else { return }
    draft.parts[index].categoryId = categoryId
    draft.parts[index].categorySource = .system
  }

  /// Where a contribution to the goal is filed. The goal and its subcategory may have been
  /// made in Planning since the dictionaries were read, so they are read again then.
  private func category(ofGoal goalId: UUID) -> UUID? {
    var goal = goals.first { $0.id == goalId }
    if goal == nil || goal?.subcategoryId.map(isLive) == false {
      reload()
      goal = goals.first { $0.id == goalId }
    }
    if let subcategoryId = goal?.subcategoryId, isLive(subcategoryId) { return subcategoryId }
    return categories.first { $0.parentId == nil && $0.systemRole == .goals }?.id
  }

  private func isLive(_ categoryId: UUID) -> Bool {
    categories.contains { $0.id == categoryId }
  }

  /// A part filed under the subcategory of a goal — by hand, by a chip, by history or by the
  /// model — names that goal: the subcategory belongs to it alone, and Planning counts the part
  /// toward it either way. A goal already named, or cleared by hand, is left as it is.
  private func nameTheGoal(ofPartAt index: Int) {
    guard draft.parts.indices.contains(index), draft.parts[index].goalId == nil,
      let categoryId = draft.parts[index].categoryId,
      let goal = goals.first(where: { $0.subcategoryId == categoryId })
    else { return }
    draft.parts[index].goalId = goal.id
  }

  // MARK: Fields of the panel that bring defaults

  /// The ↓ panel is opening. An operation entered in the panel alone — an empty line and
  /// Enter — never passes through the line, so the defaults are laid now, where they can be
  /// seen: the default payment method, the event of the day. A date nobody chose is the
  /// moment the panel opens, so the panel shows the time the operation will be saved with
  /// rather than the time the draft was made.
  public func prepareForPanel(today: DateOnly, now: Date = Date()) {
    reload()
    takeTheMomentOfSaving(now: now)
    applyDefaults(today: today)
  }

  /// Dates the new operation by the moment it is saved, unless somebody chose the date: the
  /// panel (`setDate`) or a day the line named. An operation entered in the panel alone never
  /// passes through the line, which is what writes «now» — without this it was saved at the
  /// moment its draft was made, the morning the window opened, and after midnight on the day
  /// before. A saved operation in the editor keeps its own date.
  public func takeTheMomentOfSaving(now: Date = Date()) {
    // The save lays the rate of the day from the cache as it is now: «Списано со счёта» is
    // worked out from the same.
    cachedRates = nil
    guard !editsSavedOperation, dateFollowsTheClock, draft.occurredAt == dateFromTheLine else {
      return
    }
    draft.occurredAt = now
    dateFromTheLine = now
  }

  /// A place chosen in the panel brings what a place named in the line brings: its category
  /// while none is chosen, and its last payment method unless one was chosen by hand.
  public func setPlace(_ id: UUID?, today: DateOnly) {
    guard draft.placeId != id else { return }
    draft.placeId = id
    if !assisted { fileByThePlace() }
    applyDefaults(today: today)
  }

  /// The form at the side takes nothing from history but this: a place chosen there brings the
  /// category and subcategory of the last operation at it, unless the owner chose a category by
  /// hand in this draft — that one stays. Another place chosen after it brings its own.
  private func fileByThePlace() {
    guard has(.category), let place = draft.placeId, !draft.parts.isEmpty else { return }
    let first = draft.parts[0]
    guard first.categoryId == nil || first.categorySource != .manual else { return }
    let last = otherOperations().first { entry in
      entry.transaction.placeId == place
        && entry.transaction.kind.categoryKind
          == draft.kind
          .categoryKind
    }
    guard let categoryId = last?.parts.first?.categoryId, isOffered(categoryId) else { return }
    setCategory(categoryId, forPartAt: 0, source: .history)
    // Stored as the most specific category: the subcategory too, when the last one had it.
    draft.parts[0].categoryId = categoryId
    draft.parts[0].categorySource = .history
  }

  /// An account chosen by hand stays whatever place is chosen after it, and its main currency
  /// becomes the operation's unless a currency was named.
  public func setPaymentMethod(_ id: UUID?) {
    noteTheOpenedDraft()
    draft.paymentMethodId = id
    // A card stays only with its own account.
    draft.cardId = CardRules.cardAfterAccountChange(draft.cardId, to: id, cards: cards)
    paymentMethodFromDefaults = nil
    accountFromTheScreen = false
    layTheCurrency()
    refreshCharge()
  }

  /// A currency picked in the panel is the owner's, as one named in the line is.
  public func setCurrency(_ currency: CurrencyCode) {
    guard draft.currency != currency || currencyFromDefaults != nil else { return }
    noteTheOpenedDraft()
    draft.currency = currency
    currencyFromDefaults = nil
    refreshCharge()
  }

  // MARK: Account, currency and «Списано со счёта»

  /// The words of the account field: «Со счёта» for spending, «На счёт» for money that comes
  /// in — income, a refund, money back — and just «Счёт» for a contribution to a goal, whose
  /// money stays on the account.
  public var accountFieldKey: String {
    if isGoalOnly { return "entry.paymentMethod" }
    return draft.kind == .expense ? "entry.account.from" : "entry.account.to"
  }

  /// The account the draft is on, live or archived. Every operation has one: a draft that names
  /// none is written on the main account, and that is the account it charges.
  public var selectedAccount: PaymentMethod? {
    guard let id = draft.paymentMethodId else { return mainAccount }
    return account(withId: id)
  }

  var mainAccount: PaymentMethod? { paymentMethods.first(where: \.isDefault) }

  /// What the account picker offers, the main account first and the rest in the owner's order.
  /// There is no «none»: every operation has an account. An operation saved on an account
  /// archived since is offered that account too, so the picker still shows where it is.
  public func accountChoices(locale: Locale) -> [PaymentMethod] {
    let live = AccountRules.ordered(paymentMethods, locale: locale)
    guard let current = selectedAccount, current.archived else { return live }
    return live + [current]
  }

  /// The account the owner chose — named in the line, picked in the panel, or the one whose
  /// screen is open — as opposed to one the defaults laid by themselves, or the main one a
  /// draft without an account falls back to: only a chosen account gives the operation its
  /// currency.
  public var chosenAccount: PaymentMethod? {
    guard draft.paymentMethodId != nil, paymentMethodFromDefaults == nil || accountFromTheScreen
    else { return nil }
    return selectedAccount
  }

  /// Whether the account has to be told what it was charged: it does not hold the currency of
  /// an operation that moves money on it. A purchase on credit moves the debt, not the account,
  /// and a contribution to a goal leaves its money where it is.
  public var needsCharge: Bool {
    guard let account = selectedAccount, !isOnCredit, !isGoalOnly else { return false }
    return AccountRules.legCurrency(for: draft.currency, account: account) != nil
  }

  /// The prefill of «Списано со счёта» rests on a rate the bank has not published for that day
  /// yet: it is refined later, and the statement is the one to believe.
  public private(set) var chargeIsProvisional = false

  /// Whether every part goes to a goal: such an operation moves no money.
  private var isGoalOnly: Bool { KindFields.isGoalOnly(draft, tree: categoryTree) }

  /// A typed «Списано со счёта» was typed for another amount, currency, day or account than the
  /// draft has now: it is kept — the statement is the one to believe — and the panel says it
  /// was not worked out again («Списано со счёта не пересчитано — проверьте»).
  public private(set) var chargeNeedsCheck = false

  /// What a typed figure was typed for.
  private struct ChargeBasis: Equatable {
    let amount: AmountE4
    let currency: CurrencyCode
    let day: DateOnly
    let account: UUID?
  }

  private var chargeBasis: ChargeBasis {
    ChargeBasis(
      amount: draft.amount, currency: draft.currency, day: calendar.day(of: draft.occurredAt),
      account: selectedAccount?.id)
  }

  /// «Списано со счёта» typed from the statement: the figure, in the currency the account is
  /// charged in. Zero hands the field back to the prefill. The field writing back the figure it
  /// shows is not typing.
  public func setCharge(_ amount: AmountE4) {
    guard amount != (draft.accountAmount ?? .zero) else { return }
    noteTheOpenedDraft()
    guard !amount.isZero else {
      dropTheTypedCharge()
      refreshCharge()
      return
    }
    guard let account = selectedAccount,
      let leg = AccountRules.legCurrency(for: draft.currency, account: account)
    else { return }
    draft.accountCurrency = leg
    draft.accountAmount = amount
    chargeTyped = true
    chargeTypedFor = chargeBasis
    chargeNeedsCheck = false
    chargeIsProvisional = false
    rateFromTheTypedRubles()
  }

  /// Works «Списано со счёта» out again from what the draft holds now: nothing when the
  /// account holds the currency; otherwise the account's main currency and — unless the owner
  /// typed it for that currency — the prefill from the bank's rates (`AccountRules.prefillLeg`).
  /// A figure in rubles uses the rate the save lays, so an untouched prefill changes no ruble
  /// figure; without a rate the figure stays empty and has to be typed. The save calls this
  /// again once it has laid the rate, so a rate refined meanwhile is the one the figure uses.
  public func refreshCharge() {
    layTheCashRate()
    if editsSavedOperation {
      refreshTheChargeOfTheSavedOperation()
      return
    }
    guard needsCharge, let account = selectedAccount,
      let leg = AccountRules.legCurrency(for: draft.currency, account: account)
    else {
      clearTheCharge()
      return
    }
    if keepsTheTypedCharge(in: leg) { return }
    dropTheTypedCharge()
    let rates = ratesNow()
    let rated = ratedDraft(rates.table)
    draft.accountCurrency = leg
    // A refund taken back from a purchase carries the purchase's rate for its rubles, while the
    // bank converts what comes onto the card at the rates of the day it arrives.
    draft.accountAmount =
      RefundRules.takesBack(draft)
      ? RefundRules.prefillLeg(
        amount: draft.amount, currency: draft.currency, day: calendar.day(of: draft.occurredAt),
        account: account, rates: rates.days)
      : AccountRules.prefillLeg(
        amount: draft.amount, currency: draft.currency, rate: rated.rate,
        day: calendar.day(of: draft.occurredAt), account: account, rates: rates.days)
    chargeIsProvisional =
      draft.accountAmount != nil && isProvisional(leg: leg, rated: rated, table: rates.table)
  }

  /// A saved operation keeps what it was charged until the account, the currency, the amount,
  /// the day, the rate or the figure is changed in the editor; then the figure follows
  /// `AccountRules.legAfterEdit` against the operation as it was opened: cleared when the
  /// account holds the currency, worked out again when it was the prefill, kept and flagged
  /// when it was typed from the statement.
  private func refreshTheChargeOfTheSavedOperation() {
    guard let opened = openedDraft else { return }
    guard needsCharge, let account = selectedAccount,
      let leg = AccountRules.legCurrency(for: draft.currency, account: account)
    else {
      clearTheCharge()
      return
    }
    if keepsTheTypedCharge(in: leg) { return }
    dropTheTypedCharge()
    guard let before = try? opened.materialize(now: opened.occurredAt) else { return }
    let rates = ratesNow()
    let rated = ratedDraft(rates.table)
    let edit = AccountRules.legAfterEdit(
      before: before, after: rated, account: account, rates: rates.days, calendar: calendar)
    draft.accountCurrency = edit.currency
    draft.accountAmount = edit.amount
    chargeNeedsCheck = edit.outcome == .keptTyped
    chargeIsProvisional =
      edit.outcome == .prefilled && edit.amount != nil
      && isProvisional(leg: leg, rated: rated, table: rates.table)
  }

  /// A figure the owner typed for the currency the account is still charged in stays; it is
  /// flagged once what it was typed for has changed.
  private func keepsTheTypedCharge(in leg: CurrencyCode) -> Bool {
    guard chargeTyped, draft.accountCurrency == leg, draft.accountAmount != nil else {
      return false
    }
    chargeNeedsCheck = chargeTypedFor != chargeBasis
    rateFromTheTypedRubles()
    return true
  }

  /// Nothing is charged apart: the account holds the currency, or no money moves on it.
  private func clearTheCharge() {
    dropTheTypedCharge()
    draft.accountCurrency = nil
    draft.accountAmount = nil
    chargeIsProvisional = false
  }

  /// Forgets a typed figure, and the rate it implied when the bank had none.
  private func dropTheTypedCharge() {
    chargeTyped = false
    chargeTypedFor = nil
    chargeNeedsCheck = false
    guard rateFromTheCharge else { return }
    rateFromTheCharge = false
    draft.rate = nil
    draft.rateDate = nil
    draft.rateSource = nil
    draft.rateProvisional = false
  }

  /// A typed figure in rubles is the operation's rubles (`TransactionDraft.materialize`). When
  /// the bank has no rate at all for the operation's currency, the rate is the one the figure
  /// implies — six places, set by hand — or the save could not convert the amount and would
  /// refuse the very figure the panel asked for. A rate the owner typed is never replaced.
  private func rateFromTheTypedRubles() {
    guard chargeTyped, draft.accountCurrency == .rub, let rubles = draft.accountAmount,
      draft.currency != .rub, !draft.amount.isZero
    else { return }
    if !rateFromTheCharge {
      guard draft.rate == nil,
        ratesNow().table.resolve(draft.currency, on: calendar.day(of: draft.occurredAt)) == nil
      else { return }
    }
    draft.rate = DecimalMath.round(rubles.decimal / draft.amount.decimal, scale: 6)
    draft.rateDate = calendar.day(of: draft.occurredAt)
    draft.rateSource = .manual
    draft.rateProvisional = false
    rateFromTheCharge = true
  }

  /// The draft with the rate the save would lay on it.
  private func ratedDraft(_ table: RateTable) -> TransactionDraft {
    var rated = draft
    AppEnvironment.applyRate(to: &rated, from: table, calendar: calendar)
    return rated
  }

  /// Whether the figure rests on a rate the bank has not published for the day yet: the
  /// operation's own, or that of the currency the account is charged in.
  private func isProvisional(
    leg: CurrencyCode, rated: TransactionDraft, table: RateTable
  ) -> Bool {
    let day = calendar.day(of: draft.occurredAt)
    // A refund of a purchase carries the purchase's rate, but what came onto the account is
    // prefilled at the rates of the refund's own day: those are the ones that may be early.
    let ownIsProvisional =
      draft.currency != .rub
      && (takesBackFromAPurchase
        ? (table.resolve(draft.currency, on: day)?.isProvisional ?? true)
        : rated.rateProvisional)
    let legIsProvisional = leg != .rub && (table.resolve(leg, on: day)?.isProvisional ?? true)
    return ownIsProvisional || legIsProvisional
  }

  /// The rates, read from the cache once until they may have changed.
  private func ratesNow() -> (table: RateTable, days: DayRates) {
    if let cachedRates { return cachedRates }
    let table = rateTable?() ?? RateTable()
    let rates = (table: table, days: Self.dayRates(table))
    cachedRates = rates
    return rates
  }

  /// The rates may have changed — the data was computed again: the next figure reads them
  /// afresh.
  public func ratesMayHaveChanged() {
    cachedRates = nil
  }

  /// The editor keeps the operation as it was opened, from the first change that moves what the
  /// account is charged: what `AccountRules.legAfterEdit` compares the edit with.
  private func noteTheOpenedDraft() {
    guard editsSavedOperation, openedDraft == nil else { return }
    openedDraft = draft
  }

  /// A saved operation on the account, in the currency, of the amount and on the day it was
  /// opened with: it moves money as it did.
  private var movesLikeTheOpenedOperation: Bool {
    guard editsSavedOperation else { return false }
    guard let opened = openedDraft else { return true }
    return opened.paymentMethodId == draft.paymentMethodId && opened.currency == draft.currency
      && opened.amount == draft.amount
      && calendar.day(of: opened.occurredAt) == calendar.day(of: draft.occurredAt)
  }

  /// The bank's rates by day, for one unit.
  private static func dayRates(_ table: RateTable) -> DayRates {
    var series: [CurrencyCode: [DayRate]] = [:]
    for rate in table.rates {
      series[rate.currency, default: []].append(DayRate(day: rate.date, perUnit: rate.perUnit))
    }
    return DayRates(series: series)
  }

  /// A currency laid by the defaults follows the account: the main currency of an account the
  /// owner chose, otherwise the default currency. A saved operation keeps its own.
  private func layTheCurrency() {
    guard !editsSavedOperation, let laid = currencyFromDefaults, draft.currency == laid else {
      return
    }
    let currency = AccountRules.currencyForNewOperation(
      typed: nil, chosenAccount: chosenAccount, default: defaultCurrency)
    draft.currency = currency
    currencyFromDefaults = currency
  }

  /// The currency Enter on `parsed` gives the operation, worked out without touching the draft:
  /// the preview above the line and the chips under it say this one, so what they show is what
  /// is saved. It follows `apply` and `applyDefaults` step by step: the purchase picked for
  /// this very line keeps its currency; the one typed; the one the draft holds when the owner
  /// set it — picked in the panel, or typed in a line applied before —; otherwise the main
  /// currency of the account the owner chose — named in the line, picked in the panel, or the
  /// one whose screen is open now, whatever screen laid the draft's account before —; otherwise
  /// the default currency.
  public func currencyOnSaving(_ parsed: ParsedInput) -> CurrencyCode {
    if editsSavedOperation { return parsed.currency ?? draft.currency }
    let picked = refundTarget != nil || refundWithoutPurchase || pickBase != nil
    if picked, parsed == lineOfThePick { return draft.currency }
    if let typed = parsed.currency { return typed }
    // Another line forgets the purchase: the draft is again what it was before the pick.
    let base = picked ? pickBase : nil
    let held = base?.draft ?? draft
    let laid = base.map(\.currencyFromDefaults) ?? currencyFromDefaults
    let fromDefaults = base.map(\.paymentMethodFromDefaults) ?? paymentMethodFromDefaults
    let fromTheScreen = base?.accountFromTheScreen ?? accountFromTheScreen
    guard let laid, held.currency == laid else { return held.currency }
    let chosen: PaymentMethod?
    if let named = parsed.paymentMethodId {
      chosen = account(withId: named)
    } else if held.paymentMethodId == nil || held.paymentMethodId == fromDefaults {
      // The defaults lay the account again: the screen's counts as chosen, nothing else does.
      chosen = openAccountScreen?().flatMap { isLiveAccount($0) ? account(withId: $0) : nil }
    } else if let id = held.paymentMethodId, fromDefaults == nil || fromTheScreen {
      chosen = account(withId: id)
    } else {
      chosen = nil
    }
    return AccountRules.currencyForNewOperation(
      typed: nil, chosenAccount: chosen, default: defaultCurrency)
  }

  private func account(withId id: UUID) -> PaymentMethod? {
    paymentMethods.first { $0.id == id } ?? allAccounts.first { $0.id == id }
  }

  private func isLiveAccount(_ id: UUID) -> Bool {
    paymentMethods.contains { $0.id == id }
  }

  // MARK: Before the count

  /// The count the save has to ask «Это было до сверки в 14:05?» about: the operation is dated
  /// on the day of the latest count of a balance it moves, and is saved after that count
  /// (`AccountReconciliation.beforeTheCount`). `nil` when nothing asks, or the owner has
  /// answered about that count already. Money back is asked too, before its confirmation opens:
  /// the confirmation writes it at the moment the answer gave.
  public func countToAskAbout(savedAt: Date, balances: AccountBalances) -> Date? {
    guard let entry = try? draftForSaving.materialize(now: savedAt) else { return nil }
    let keys = AccountReconciliation.movedKeys(
      of: entry, mainId: paymentMethods.first(where: \.isDefault)?.id, tree: categoryTree)
    guard
      let count = AccountReconciliation.beforeTheCount(
        occurredAt: draft.occurredAt, savedAt: savedAt, keys: keys, balances: balances,
        calendar: calendar),
      count != answeredCount
    else { return nil }
    return count
  }

  /// The questions about the counts of the day the save has to ask, oldest first: every count of
  /// a balance the operation moves made on its day before it was saved
  /// (`AccountReconciliation.countToAsk`). The answers `remembered` for their reconciliations —
  /// «Больше не спрашивать для этой сверки» — answer without a question; when they settle every
  /// count, the moment itself. Nothing once the answers were given for the moment the draft
  /// holds (`stampCount`).
  public func countAsk(
    savedAt: Date, balances: AccountBalances, remembered: [UUID: Bool]
  ) -> CountAsk {
    guard draft.occurredAt != stampedAt, let entry = try? draftForSaving.materialize(now: savedAt)
    else { return .none }
    let keys = AccountReconciliation.movedKeys(
      of: entry, mainId: paymentMethods.first(where: \.isDefault)?.id, tree: categoryTree)
    return AccountReconciliation.countToAsk(
      occurredAt: draft.occurredAt, savedAt: savedAt, keys: keys, balances: balances,
      calendar: calendar, remembered: remembered)
  }

  /// The moment the answers about the counts gave: the operation is saved at it, and the save
  /// that goes on does not ask again. A date changed after it asks anew.
  public func stampCount(_ moment: Date) {
    draft.occurredAt = moment
    dateFollowsTheClock = false
    stampedAt = moment
  }

  /// The moment `stampCount` gave the draft.
  private var stampedAt: Date?

  /// The answer: «Да» dates the operation a second before the count, so its money is inside
  /// what was counted — unless it is dated before the count already, a time set in the panel,
  /// which is kept; «Нет» dates it after the count. Either way the date is the owner's now, and
  /// it stays on the day of the count: a count at 00:00:00 answered «Да», or at 23:59:59
  /// answered «Нет», would otherwise put the operation into another day and month.
  public func answerCount(_ count: Date, wasBefore: Bool) {
    let stamped = AccountReconciliation.stamped(
      occurredAt: draft.occurredAt, count: count, wasBefore: wasBefore, calendar: calendar)
    draft.occurredAt = wasBefore ? min(draft.occurredAt, stamped) : stamped
    dateFollowsTheClock = false
    answeredCount = count
  }

  /// A new date is a new day: the event covering it is offered instead of the old one's.
  public func setDate(_ date: Date, today: DateOnly) {
    guard draft.occurredAt != date else { return }
    noteTheOpenedDraft()
    draft.occurredAt = date
    applyDefaults(today: today)
  }

  // MARK: The month an income is for

  /// The month an income is for as the panel shows it: the one chosen, otherwise the month
  /// of its date («за какой месяц» — «по умолчанию месяц даты»).
  public var shownPeriodMonth: MonthKey {
    draft.periodMonth ?? calendar.day(of: draft.occurredAt).monthKey
  }

  /// The cashback category of the settings (`analytics.cashbackCategoryId`), read with the
  /// dictionaries: an income in it may be for the month before (`CashbackIncomeMonth`).
  public var cashbackCategoryId: UUID?
  /// Where it is read from: the app's settings, handed over in `init(environment:)`.
  var readsCashbackCategory: (() -> UUID?)?

  /// The month the defaults last laid for the income: the month before, for cashback its bank
  /// pays by a day of the next month; `nil` for the month of the date. While the draft still
  /// holds it, the defaults lay it again as the category, the account or the date change.
  private var periodMonthFromDefaults: MonthKey?
  /// The owner picked the month in the panel: it stays whatever changes after.
  private var periodMonthChosen = false
  /// The month is being laid by the defaults: the change it makes is not followed again.
  private var layingThePeriodMonth = false

  /// The month an income is for by default: the month of its date, or for cashback that its
  /// bank pays by a day of the next month, the month before (`CashbackIncomeMonth`). `nil` for
  /// anything but an income.
  public var defaultPeriodMonth: MonthKey? {
    guard draft.kind == .income else { return nil }
    let account = draft.paymentMethodId ?? mainAccountId
    return CashbackIncomeMonth.month(
      forIncomeOn: calendar.day(of: draft.occurredAt), categoryIds: draft.parts.map(\.categoryId),
      accountId: account, cashbackCategoryId: cashbackCategoryId, tree: categoryTree,
      accounts: allAccounts, calendar: calendar)
  }

  /// Whether the month shown is the one before, laid because the bank pays cashback later: the
  /// panel says so under the picker.
  public var periodMonthIsCashbackOfTheMonthBefore: Bool {
    guard !periodMonthChosen, let laid = periodMonthFromDefaults else { return false }
    return draft.periodMonth == laid
  }

  /// A month picked in the panel: the owner's, kept whatever changes after it.
  public func choosePeriodMonth(_ month: MonthKey?) {
    periodMonthChosen = true
    draft.periodMonth = month
  }

  /// Lays the default month of a new income while nobody chose one: a saved operation keeps the
  /// month it was saved with, and a month picked in the panel stays.
  private func followTheIncomeMonth() {
    guard !editsSavedOperation, !periodMonthChosen, !layingThePeriodMonth else { return }
    // A month the draft got from elsewhere — not laid here — is left alone.
    guard draft.periodMonth == nil || draft.periodMonth == periodMonthFromDefaults else { return }
    let own = calendar.day(of: draft.occurredAt).monthKey
    let laid = defaultPeriodMonth.flatMap { $0 == own ? nil : $0 }
    periodMonthFromDefaults = laid
    guard draft.periodMonth != laid else { return }
    layingThePeriodMonth = true
    defer { layingThePeriodMonth = false }
    draft.periodMonth = laid
  }

  /// What the «for month» picker offers: the month of the date, the two before it and the
  /// one after — and, in its place in time, the month the income is already for when it is
  /// none of these: chosen before the date moved, or saved that way (an import, a transfer
  /// archive). Without it the picker showed a blank while that month was what would be saved.
  public var periodMonthOptions: [MonthKey] {
    let current = calendar.day(of: draft.occurredAt).monthKey
    let around = [current.previous.previous, current.previous, current, current.next]
    guard let chosen = draft.periodMonth, !around.contains(chosen) else { return around }
    return (around + [chosen]).sorted()
  }

  // MARK: Rate typed by hand

  /// What the rate field of the ↓ panel does with whatever is in it.
  ///
  /// Only a number that can actually convert money is accepted. Half-typed and mistyped
  /// text leaves the rate exactly as it was, because a draft with no rate and the source
  /// set to `manual` is the one combination that converts a foreign amount one to one.
  /// An empty field means "use the rate of the bank again", not "there is no rate".
  ///
  /// «Списано со счёта» follows the rate: a figure in rubles is the operation's rubles, so a
  /// rate typed after a figure typed in rubles is the owner's later word, and the figure is
  /// worked out from it again.
  public func setManualRate(_ text: String) {
    // A refund of a purchase is at the purchase's rate: its rubles are the purchase's.
    guard canTypeRate else { return }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      noteTheOpenedDraft()
      rateFromTheCharge = false
      draft.rate = nil
      draft.rateDate = nil
      draft.rateSource = nil
      refreshCharge()
      return
    }
    // A plain number reads as rates always read; a formula is worked out (`RateText`).
    guard let value = RateText.value(trimmed), value > 0 else { return }
    guard value != draft.rate || draft.rateSource != .manual || rateFromTheCharge else { return }
    noteTheOpenedDraft()
    rateFromTheCharge = false
    draft.rate = value
    draft.rateDate = calendar.day(of: draft.occurredAt)
    draft.rateSource = .manual
    draft.rateProvisional = false
    if draft.accountCurrency == .rub { dropTheTypedCharge() }
    refreshCharge()
  }

  // MARK: Creating on the spot

  /// Why the last record asked for from a picker was not written, as the key of the words that
  /// say so (table «Entry»); nil once one was added or the draft started over. The sheet that
  /// asked shows it, and so does the panel.
  public private(set) var creationFailureKey: String?

  /// Adds a place and returns its id, so the picker can select it immediately. The words of
  /// the line that named it leave the note: the place carries them now.
  ///
  /// A write the database refused returns nil — an id of a row that is not there would reach
  /// Enter and fail on the foreign key with no reason — and leaves the name offered and in
  /// the note, for the next «Add…».
  public func createPlace(named name: String) -> UUID? {
    guard let references else { return nil }
    return createPlace(named: name, saving: references.save)
  }

  public func createPerson(named name: String) -> UUID? {
    guard let references else { return nil }
    return createPerson(named: name, saving: references.save)
  }

  /// Adds the person who gives a part paid for someone back and names them its debtor: «Paid
  /// for someone» takes a person from `people`, and one can be added on the spot.
  /// False when nothing was written, and the part names nobody new.
  public func createDebtor(named name: String, forPartAt index: Int) -> Bool {
    guard draft.parts.indices.contains(index), let person = createPerson(named: name) else {
      return false
    }
    draft.parts[index].debtorPersonId = person
    return true
  }

  // MARK: Adding from a picker

  /// The sheet «Add…» of a picker asked for, while it is open: which kind of record it makes and
  /// which field of the draft the new record goes into. The panel presents the sheet from this
  /// and the sheet clears it when it closes.
  var adding: AddFromPicker.Kind?

  /// Whether the subcategory menu of a part offers «Add…»: the part has a live top-level category
  /// of the owner's, of the kind of the operation. Not with no category, and not under a system
  /// one: everything under Goals or Loans belongs to the app, and a row added there could never
  /// be renamed or deleted in Settings.
  public func canAddSubcategory(forPartAt index: Int) -> Bool {
    guard draft.parts.indices.contains(index),
      let parent = categoryOfPart(draft.parts[index]),
      categoryTree.systemRole(of: parent) == nil
    else { return false }
    return NewReference.acceptsParent(parent, for: draft.kind.categoryKind, in: categories)
  }

  /// Adds a category of the operation's kind — a subcategory under `parent` — and returns its
  /// id, so the picker can choose it at once. Nil when nothing was written: `parent` cannot take
  /// it, or the database refused (`creationFailureKey` says so).
  public func createCategory(named name: String, under parent: UUID?) -> UUID? {
    guard let references else { return nil }
    return createCategory(named: name, under: parent, saving: references.save)
  }

  func createCategory(
    named name: String, under parent: UUID?, saving save: (CoreKit.Category) throws -> Void
  ) -> UUID? {
    let all =
      (try? references?.categories(includeArchived: true)) ?? categories + archivedCategories
    guard
      let category = NewReference.category(
        named: name, kind: draft.kind.categoryKind, parent: parent, among: all),
      written({ try save(category) }, what: "category")
    else {
      creationFailureKey = "entry.error.categoryNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    return category.id
  }

  /// Adds an event of the days given and returns its id.
  public func createEvent(named name: String, from start: DateOnly, to end: DateOnly) -> UUID? {
    guard let references else { return nil }
    return createEvent(named: name, from: start, to: end, saving: references.save)
  }

  func createEvent(
    named name: String, from start: DateOnly, to end: DateOnly,
    saving save: (Event) throws -> Void
  ) -> UUID? {
    let event = NewReference.event(named: name, from: start, to: end)
    guard written({ try save(event) }, what: "event") else {
      creationFailureKey = "entry.error.eventNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    return event.id
  }

  /// Adds a payment method of `kind` and returns its id. The first one in the book becomes the
  /// default, as it does in Settings. A card or a bank account comes with a card named like it,
  /// in the same write (`CardRules.startingCard`), and every account stands under a bank: the live
  /// bank of its name, else a new one written with it (`BankRules.bank(forNewAccountNamed:)`).
  public func createPaymentMethod(named name: String, kind: PaymentMethodKind) -> UUID? {
    guard let references else { return nil }
    return createPaymentMethod(named: name, kind: kind) { method, bank in
      try references.save(
        method, startingCard: CardRules.startingCard(for: method), bank: bank)
    }
  }

  func createPaymentMethod(
    named name: String, kind: PaymentMethodKind,
    saving save: (PaymentMethod, Bank?) throws -> Void
  ) -> UUID? {
    let live = (try? references?.paymentMethods()) ?? paymentMethods
    var method = NewReference.paymentMethod(named: name, kind: kind, among: live)
    let choice = BankRules.bank(
      forNewAccountNamed: name, among: (try? references?.banks(includeArchived: true)) ?? banks)
    method.bankId = choice.bank.id
    guard written({ try save(method, choice.isNew ? choice.bank : nil) }, what: "paymentMethod")
    else {
      creationFailureKey = "entry.error.paymentMethodNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    return method.id
  }

  /// `save` writes the place: the repository's, or a refusal in a test. A name an archived
  /// place answers to brings that place back instead of a second one of the same name.
  func createPlace(named name: String, saving save: (Place) throws -> Void) -> UUID? {
    var place = archivedPlace(answeringTo: name) ?? Place(name: name)
    place.archived = false
    guard written({ try save(place) }, what: "place") else {
      creationFailureKey = "entry.error.placeNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    suggestedPlaceName = nil
    dropFromTheNote(unmatchedPlacePhrase)
    unmatchedPlacePhrase = nil
    return place.id
  }

  func createPerson(named name: String, saving save: (Person) throws -> Void) -> UUID? {
    var person = archivedPerson(answeringTo: name) ?? Person(name: name)
    person.archived = false
    guard written({ try save(person) }, what: "person") else {
      creationFailureKey = "entry.error.personNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    suggestedPersonName = nil
    dropFromTheNote(unmatchedPersonPhrase)
    unmatchedPersonPhrase = nil
    return person.id
  }

  /// The archived place the line would read `name` as, were it not archived: its name or an
  /// alias, a declined form included («Пятёрочке» is «Пятёрочка»). The line leaves archived
  /// names out — archiving is how a name stops matching — so the only way such a place is
  /// named again is «Add…» of the panel, and nothing else in the app takes a row out of the
  /// archive.
  private func archivedPlace(answeringTo name: String) -> Place? {
    let archived = ((try? references?.places(includeArchived: true)) ?? []).filter(\.archived)
    guard !archived.isEmpty else { return nil }
    let vocabulary = ParserVocabulary(
      places: archived.map { .init(id: $0.id, name: $0.name, aliases: $0.aliases) })
    let id = readsAs(vocabulary, "в \(name)").placeId
    return archived.first { $0.id == id }
  }

  /// The archived person the line would read `name` as; see `archivedPlace(answeringTo:)`.
  private func archivedPerson(answeringTo name: String) -> Person? {
    let archived = ((try? references?.people(includeArchived: true)) ?? []).filter(\.archived)
    guard !archived.isEmpty else { return nil }
    let vocabulary = ParserVocabulary(
      people: archived.map { .init(id: $0.id, name: $0.name, aliases: $0.aliases) })
    let id = readsAs(vocabulary, "для \(name)").personId
    return archived.first { $0.id == id }
  }

  /// A name behind its marker, read by the line's own rules against `vocabulary` alone.
  private func readsAs(_ vocabulary: ParserVocabulary, _ phrase: String) -> ParsedInput {
    InputLineParser(vocabulary: vocabulary, calendar: calendar)
      .parse(phrase, today: calendar.day(of: Date()))
  }

  /// Runs a write of a new name; a refusal goes to the journal with its type, never the name.
  private func written(_ write: () throws -> Void, what: String) -> Bool {
    do {
      try write()
      return true
    } catch {
      AppLog.error(
        "references.saveFailed", .db, "a new name was not saved",
        [
          LogPair("reference", .token(what)),
          LogPair("error", .error(error)),
        ])
      return false
    }
  }

  /// Takes the words of an unknown name back out of the note, where `apply` put them — the
  /// last time they occur, which is where they were added. Only a note the line wrote is
  /// touched, and it stays the line's: the next line still writes over it.
  private func dropFromTheNote(_ phrase: String?) {
    guard let phrase, let note = draft.note, note == noteFromTheLine,
      let range = note.range(of: phrase, options: .backwards)
    else { return }
    var rest = note
    rest.removeSubrange(range)
    let words = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    draft.note = words.isEmpty ? nil : words
    noteFromTheLine = draft.note
  }

  // MARK: Split

  public var isSplit: Bool { draft.parts.count > 1 }

  /// A new part takes what is left of the total and starts with a quality, like every
  /// other part of an operation.
  public func addPart() {
    // A refund of a purchase takes back one amount of one part.
    guard !takesBackFromAPurchase else { return }
    let remainder = draft.unallocated
    draft.parts.append(PartDraft(amount: remainder.isNegative ? .zero : remainder))
    resolveQuality(ofPartAt: draft.parts.count - 1, in: categoryTree)
  }

  /// «Paid for someone» of the panel. An operation of one part gets a second one — empty, the
  /// total is all mine until an amount is typed into it — and the last part is paid for someone.
  /// An empty part is never saved (`saveRefusalKey`: every part above zero), so the button
  /// cannot leave an owed part of nothing in «Owed to me».
  public func markLastPartPaidForSomeone() {
    guard !takesBackFromAPurchase else { return }
    if !isSplit { addPart() }
    guard let last = draft.parts.indices.last else { return }
    draft.parts[last].reimbursable = true
  }

  public func removePart(id: UUID) {
    guard canRemovePart(id: id) else { return }
    draft.parts.removeAll { $0.id == id }
    if draft.parts.count == 1 {
      draft.parts[0].amount = draft.amount
    }
  }

  /// A part can go while another stays — unless someone gave the money back for it: a
  /// reimbursement closes it through a link, and taking it away would leave that
  /// reimbursement closing nothing. The status is the one the editor was
  /// opened with; the store asks the row as it is when saving.
  public func canRemovePart(id: UUID) -> Bool {
    draft.parts.count > 1 && !isClosedPart(id: id)
  }

  /// A part someone gave the money back for, as the editor was opened: its amount and
  /// «paid for someone» stay as they are, and so do the currency and the type of the
  /// operation. The store asks the row as it is when saving.
  public func isClosedPart(id: UUID) -> Bool {
    draft.parts.first { $0.id == id }?.reimbursementStatus == .returned
  }

  /// Whether any part is closed that way.
  public var hasClosedPart: Bool {
    draft.parts.contains { $0.reimbursementStatus == .returned }
  }

  public func splitEqually(into count: Int) {
    guard count > 1, !takesBackFromAPurchase else { return }
    let shares = draft.amount.split(into: count)
    let template = draft.parts.first ?? PartDraft()
    draft.parts = shares.map { share in
      var part = template
      part.id = UUID()
      part.amount = share
      return part
    }
  }

  // MARK: What the line did not say

  /// The gap Enter stopped for, and the line it stopped for — its parse and, from the entry
  /// bar, its text (nil: the panel alone).
  private struct GapStop: Equatable {
    let gap: EntryGap
    let line: ParsedInput?
    var text: String? = nil
    /// The owner confirmed a form instead (the money back recorded as income): nothing is asked
    /// of this line, and the panel marks nothing.
    var waived = false
  }
  private var gapStop: GapStop?

  /// What the panel is asked to put the keyboard focus on: the control a stop asks for.
  var focusRequest: PanelFocusRequest?

  /// The transfer the panel writes instead of an operation while the kind «Перевод» is chosen;
  /// `nil` while it holds an operation. The draft of the operation stays as it was beside it.
  var transfer: TransferEntry?

  /// «Перевод» chosen in the panel: the transfer starts with what the panel holds — the amount,
  /// its currency, the account, the day and the note (`TransferForm(fromThePanel:)`).
  func chooseTransfer(calendar: CalendarContext) {
    guard transfer == nil else { return }
    transfer = TransferEntry(
      form: TransferForm(
        fromThePanel: draft, account: selectedAccount, accounts: paymentMethods,
        calendar: calendar))
  }

  /// The field Enter asks for before a new operation is saved (`EntryCompleteness`): the
  /// category the line did not say, or the subcategory the model left open. A category is asked
  /// until one is chosen — the same line again, or Return in the panel, saves nothing without
  /// it, and «Не помню» is the way out for what the owner does not remember. A subcategory is
  /// asked once per line: the same line again saves the draft in its category. Nil for a saved
  /// operation, which may stay as it is.
  public func gapToAsk() -> EntryGap? {
    guard !editsSavedOperation,
      let gap = EntryCompleteness.gap(of: draftForSaving, tree: categoryTree)
    else { return nil }
    if let gapStop, isTheLine(of: gapStop), gapStop.waived || gap == .subcategory { return nil }
    gapStop = GapStop(gap: gap, line: lastLine, text: lastLineText)
    return gap
  }

  /// Whether the line applied last is the one `stop` was made for: the same text — though
  /// «Добавить…» of a name in it has made the same text parse anew — or the same parse.
  private func isTheLine(of stop: GapStop) -> Bool {
    if let text = stop.text, text == lastLineText { return true }
    return stop.line == lastLine
  }

  /// ↓ and ↑ in the line while Enter's stop for that line stands: the next or the previous choice
  /// of the menu the stop asked for, as a choice made in the menu. For a category the walk is «—»,
  /// then the chips under the line (up to three), then the other categories in the menu's order,
  /// and last the categories of the app — Goals, Loans, «Не помню» (`EntryCompleteness.stopChoices`);
  /// for a subcategory «—», then the menu's own items. Where macOS keeps the focus off menus
  /// («Навигация с клавиатуры» off), this is how the keyboard chooses. False when no stop stands:
  /// the arrows keep their meaning.
  public func stepTheAskedMenu(by step: Int, today: DateOnly) -> Bool {
    guard let gapStop, isTheLine(of: gapStop), !isSplit else { return false }
    let current: UUID?
    let choices: [UUID?]
    switch gapStop.gap {
    case .category:
      current = part(at: 0).categoryId
      choices = EntryCompleteness.stopChoices(
        suggested: categorySuggestions.map(\.id), menu: categoryOptions(forPartAt: 0),
        tree: categoryTree)
    case .subcategory:
      current = subcategoryOfPart(part(at: 0))
      choices = [nil] + subcategoryOptions(forPartAt: 0).map(\.id)
    }
    let at = choices.firstIndex(of: current) ?? 0
    let next = min(max(at + step, 0), choices.count - 1)
    guard next != at else { return true }
    switch gapStop.gap {
    case .category:
      if let chip = categorySuggestions.first(where: { $0.id == choices[next] }) {
        applySuggestion(chip, forPartAt: 0)
      } else {
        setCategory(choices[next], forPartAt: 0)
      }
    case .subcategory: setSubcategory(choices[next], forPartAt: 0)
    }
    applyDefaults(today: today)
    return true
  }

  /// The gap the panel marks: the one asked, while it is still missing.
  public var markedGap: EntryGap? {
    guard let gapStop, !gapStop.waived,
      EntryCompleteness.gap(of: draftForSaving, tree: categoryTree) == gapStop.gap
    else { return nil }
    return gapStop.gap
  }

  // MARK: Before it is written

  /// «Добавить» of the question about a repeat, kept until the operation is saved: the counts of
  /// its day may be asked about after that question, and it is not asked twice. Cleared with the
  /// draft (`reset`).
  var repeatConfirmed = false

  /// «Записать как есть» of the question about a date ahead, kept the same way.
  var aheadAnswered = false

  /// «Записать всё равно» of the warning about a credit card's limit, kept the same way.
  var overLimitAnswered = false

  /// «Записать всё равно» of the warning about the balance a bank asks to keep, kept the same
  /// way.
  var minBalanceAnswered = false

  /// «Записать» of the question «Подождать?» and the answer to «Сколько проехали с прошлой
  /// заправки?» (even «Не помню»), kept the same way.
  var pauseAnswered = false
  var mileageAnswered = false

  /// «В этом месяце больше платежей не будет»: set from the panel on a payment of a debt that
  /// leaves part of its due unpaid, so the due closes all the same (`DebtEntry.closesTerm`).
  /// Kept until the operation is saved, and cleared with the draft (`reset`).
  var closesDebtTerm = false

  /// The answer to «Сверх платежа X — уменьшить срок или платёж?» of a payment of a loan above
  /// its due (`DebtPrepayment.question`); `nil` until it is given. Cleared with the draft.
  public var prepayChoice: PrepayChoice?

  /// The debt the operation as it stands pays: an expense that names a debt I owe, still open.
  var debtBeingPaid: Debt? {
    guard draft.kind == .expense, let id = draft.debtId else { return nil }
    return debts.first { $0.id == id && $0.direction == .iOwe && !$0.closed }
  }

  /// Whether the panel offers «В этом месяце больше платежей не будет»: a new payment of a debt
  /// whose due the payment does not cover (`DebtTerms.offersClosing`, given the state of the
  /// debt's dues). A saved payment is changed in Debts.
  func offersClosingTerm(dues: DebtDueState?) -> Bool {
    guard !editsSavedOperation, let debt = debtBeingPaid else { return false }
    return DebtTerms.offersClosing(debt, paying: draft.amount, dues: dues)
  }

  /// The operation written in the last five minutes that this one repeats — the same kind, amount
  /// and currency (`RecentDuplicate`) —, read from the database as it is now. Nil for a saved
  /// operation being edited, and once «Добавить» was said.
  public func repeatedOperation(now: Date = Date()) -> TransactionEntry? {
    guard !editsSavedOperation, !repeatConfirmed, let transactions else { return nil }
    let since = now.addingTimeInterval(-RecentDuplicate.window)
    let recent = (try? transactions.entries(recordedSince: since)) ?? []
    return RecentDuplicate.match(of: draftForSaving, among: recent, now: now)
  }

  /// The operation a saved-operation editor opened, as it was saved: what an edit is compared
  /// with, so that only a change that makes things worse is asked about (`creditLimitWarning`,
  /// `minBalanceWarning`). Nil for the line and the form of a new operation, and for an editor
  /// that was not told — which then asks nothing.
  private(set) var savedOperation: TransactionDraft?
  private var savedWasDifference = false

  /// Tells the editor which saved operation it edits.
  func rememberSaved(_ entry: TransactionEntry) {
    savedOperation = TransactionDraft(entry: entry)
    savedWasDifference = Self.isReconcileDifference(entry.transaction)
  }

  /// What `operation` takes from `account` as its balance stands today: its amount for spending
  /// in the account's own currency dated no later than now, else nothing — a purchase on credit,
  /// a goal and the difference of a count move no money, and a day ahead is not in the balance
  /// yet.
  private func charged(
    _ operation: TransactionDraft, to account: PaymentMethod, difference: Bool
  ) -> AmountE4 {
    guard operation.kind == .expense, operation.creditDebtId == nil, !difference,
      !KindFields.isGoalOnly(operation, tree: categoryTree),
      operation.currency == account.mainCurrency,
      (operation.paymentMethodId ?? mainAccount?.id) == account.id,
      operation.occurredAt <= Date()
    else { return .zero }
    return operation.amount
  }

  /// How much more the spending takes from `account` than it did: a new operation takes all of
  /// its amount; a saved one being edited, the amount it takes now less what it took as it was
  /// saved — on this account only, so moving it to another card adds its whole amount there and
  /// lowering it adds nothing. `nil` when an editor does not know the saved operation.
  private func addedSpend(on account: PaymentMethod) -> AmountE4? {
    guard editsSavedOperation else { return draft.amount }
    guard let saved = savedOperation else { return nil }
    return charged(draft, to: account, difference: isReconcileDifference)
      - charged(saved, to: account, difference: savedWasDifference)
  }

  /// How far past its limit the credit card the spending is charged to would be once it is
  /// written, with the card's name and currency; `nil` when it stays within the limit, the
  /// account is no credit card, the money is in another currency than the card's, or nothing
  /// moves (a purchase on credit, a goal, the difference of a count) — or once «Записать всё
  /// равно» was said. A saved operation being edited is asked about only when the edit makes
  /// things worse: the card was within its limit and the edit takes it past, or it was past
  /// and the edit takes it further (`addedSpend`). `cards` are the cards today
  /// (`CreditStatements.now`).
  public func creditLimitWarning(
    cards: [UUID: CreditCardNow]
  ) -> (account: String, over: AmountE4, currency: CurrencyCode)? {
    guard !overLimitAnswered, draft.kind == .expense, !isOnCredit,
      !isReconcileDifference, !isGoalOnly,
      let account = selectedAccount, account.credit != nil, !account.archived,
      account.mainCurrency == draft.currency, let now = cards[account.id],
      let spend = addedSpend(on: account)
    else { return nil }
    let over = CreditCardStates.overshoot(now: now, spendE4: spend)
    let alreadyOver: AmountE4 = editsSavedOperation ? CreditCardStates.overLimit(now) : .zero
    return over > alreadyOver ? (account.name, over, account.mainCurrency) : nil
  }

  /// The balance the account the spending is charged to would fall below, with what the bank
  /// asks to keep; `nil` when it stays above, the account states no minimum, the money is in
  /// another currency than the conditions, nothing moves (a purchase on credit, a goal, the
  /// difference of a count), or once «Записать всё равно» was said. An account already below its
  /// minimum is not asked about again at every record, nor at every edit: a saved operation
  /// being edited is asked about only when the edit takes the account below it (`addedSpend`).
  public func minBalanceWarning(
    accounts: AccountsSnapshot, bank: BankData
  ) -> MinBalanceWarning? {
    guard !minBalanceAnswered, draft.kind == .expense, !isOnCredit,
      !isReconcileDifference, !isGoalOnly,
      let account = selectedAccount, !account.archived,
      let conditions = bank.conditions(account: account.id),
      let minimum = conditions.minBalanceE4, conditions.currency == draft.currency,
      account.mainCurrency == draft.currency,
      let balance = accounts.line(of: account.id)?.keys
        .first(where: { $0.key.currency == draft.currency })?.balance,
      let spend = addedSpend(on: account)
    else { return nil }
    return BankMinBalance.warning(
      balanceE4: balance, spendE4: spend, minimumE4: minimum, currency: draft.currency)
  }

  /// The plan a new operation dated after today may become — a payment from an expense, an
  /// expected income from an income (`OperationAhead`) —, asked once: nil for a saved operation,
  /// a purchase on credit, the difference of a count, and once «Записать как есть» was said.
  public func planAhead(today: DateOnly) -> OperationAhead.Plan? {
    guard !editsSavedOperation, !aheadAnswered, !isOnCredit, !isReconcileDifference else {
      return nil
    }
    return OperationAhead.plan(for: draftForSaving, today: today, calendar: calendar)
  }

  /// What a plan made of this operation is called: its note, else its category; nil when it has
  /// neither, and the caller says «Платёж» or «Поступление».
  public var planName: String? {
    if let note = draft.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
      return note
    }
    guard let categoryId = part(at: 0).categoryId else { return nil }
    return category(withId: categoryId)?.name
  }

  /// The payment this expense becomes as a plan.
  public func plannedPayment(named name: String) -> ScheduledPayment {
    OperationAhead.scheduledPayment(
      from: draftForSaving, named: name, calendar: calendar, tree: categoryTree)
  }

  /// The expected income this income becomes as a plan.
  public func plannedIncome(named name: String) -> ExpectedIncome {
    OperationAhead.expectedIncome(from: draftForSaving, named: name, calendar: calendar)
  }

  /// Saving is only allowed when nothing stops it.
  public var canSave: Bool { saveRefusalKey == nil }

  /// Why the draft cannot be saved yet, as the key of the words that say so (table «Entry»);
  /// `nil` once it can. The sign is the kind, never the amount: the total and every part are
  /// above zero — the line refuses «кофе 100-250» the same way — the parts add up to the
  /// total, a part paid for someone names who gives it back, a part under
  /// Goals names its goal and a part naming a goal stays under Goals. The rules are
  /// `SplitValidator`'s. A missing category is not one of them: an operation may stay
  /// uncategorised.
  public var saveRefusalKey: String? {
    guard !draft.amount.isZero else {
      return zeroWasTyped ? "entry.error.amountNotPositive" : "entry.error.amountMissing"
    }
    guard !draft.amount.isNegative else { return "entry.error.amountNotPositive" }
    guard !isOnCredit || draft.kind.canBeBoughtOnCredit || keepsTheSavedCredit else {
      return "entry.error.creditNotPurchase"
    }
    // The account does not hold the currency and no rate gave what it was charged: the figure
    // from the statement is typed, or nothing is saved. A saved operation whose account,
    // currency, amount and day stay as they were is not asked: a row of the time before
    // accounts has no figure, and the write lets it be.
    let charged = draft.accountAmount.map { !$0.isZero } ?? false
    guard movesLikeTheOpenedOperation || !needsCharge || charged else {
      return "entry.error.chargeMissing"
    }
    // A refund of a purchase takes back one amount of one part at its rubles: a part beside
    // it would be refunded with no purchase to check it against.
    guard !(takesBackFromAPurchase && draft.parts.count > 1) else {
      return "entry.error.refundOneAmount"
    }
    // What is checked is what is written: a part «за другого» left without its debtor stops a
    // purchase, not the income it became, which has no such field.
    let written = draftForSaving
    for problem in SplitValidator.validate(written, categories: categoryTree).problems {
      switch problem {
      case .noParts, .unbalanced: return "entry.error.notBalanced"
      case .emptyPart: return "entry.error.amountNotPositive"
      case .debtorMissing: return "entry.error.debtorMissing"
      case .goalMissing: return "entry.error.goalMissing"
      case .goalCategoryMismatch: return "entry.error.goalCategoryMismatch"
      case .categoryMissing: continue
      }
    }
    return nil
  }

  /// A reason the panel shows by itself, next to its fields: «Save» is inactive for it and
  /// nothing else on screen says why. An empty amount and parts that do not add up say so
  /// already — the field is empty, «Unallocated» turns red.
  public var shownRefusalKey: String? {
    switch saveRefusalKey {
    case "entry.error.amountNotPositive", "entry.error.debtorMissing", "entry.error.goalMissing",
      "entry.error.goalCategoryMismatch", "entry.error.creditNotPurchase",
      "entry.error.chargeMissing", "entry.error.refundOneAmount":
      saveRefusalKey
    default: nil
    }
  }

  /// Whether the next line would carry something it does not say itself. Esc closes the
  /// panel and keeps its draft, and `apply` keeps what the panel chose — a kind, a place, a
  /// split, a note or a date — as well as a place or a debt a refused line left behind. The ↓
  /// button of the capsule shows it, so none of that goes into the next operation unseen.
  /// What the line writes over — an amount, a note and a date it wrote itself — and a
  /// payment method or a «for whom» the defaults laid, which the next line's defaults lay
  /// again, are not counted; an amount the panel changed after the line wrote it is.
  public var carriesChoices: Bool {
    let first = draft.parts.first ?? PartDraft()
    let byTheDraft =
      draft.kind != .expense || isSplit || draft.placeId != nil || draft.debtId != nil
      || draft.currency != (currencyFromDefaults ?? defaultCurrency) || chargeTyped
      || (draft.periodMonth != nil && draft.periodMonth != periodMonthFromDefaults)
      || (draft.paymentMethodId != nil && draft.paymentMethodId != paymentMethodFromDefaults)
      || (draft.note != nil && draft.note != noteFromTheLine)
      || draft.occurredAt != dateFromTheLine
      || (amountFromTheLine.map { draft.amount != $0.amount } ?? false)
    let forWhom = ForWhomChoice(of: first)
    let byThePart =
      first.categoryId != nil || first.qualitySource == .manual
      || (forWhom != .me && forWhom != forWhomFromDefaults)
      || (first.eventId != nil && first.eventId != eventFromDefaults)
      || first.goalId != nil || first.reimbursable
    return byTheDraft || byThePart || creditPlan != nil || expectedIncomeId != nil
      || !cashbackField.text.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Money back from a person is not written by Enter: it closes the parts the person owed
  /// through links and is not income, and the person and the parts are chosen in the
  /// reimbursement sheet («Кнопка … или тип в панели ↓»). The line hands the draft over to
  /// it, prefilled (`ReimbursementPrefill`); on its own it would write a reimbursement that
  /// closes nothing. Money given back on a debt owed to me is that debt's payment and stays
  /// with the line.
  public var recordsThroughReimbursementSheet: Bool {
    draft.kind == .reimbursement && draft.debtId == nil
  }

  /// What money back the confirmation turned away becomes instead: income — the person owes
  /// nothing — or the repayment of a «Мне должны» debt the person owes on.
  public enum MoneyBackInstead: Hashable, Sendable {
    case income
    case debtRepayment(UUID)
  }

  /// Money back the confirmation turned away, recorded the other way it offered: the person,
  /// amount, currency, account and what the account received are the ones the sheet held.
  /// Income names no person, so whom it came from goes to its note — `fromNote` words it.
  public func recordMoneyBackInstead(
    _ route: MoneyBackInstead, from sheet: TransactionDraft,
    fromNote: (String) -> String, today: DateOnly
  ) {
    let person = sheet.parts.first?.forPersonId
    draft.amount = sheet.amount
    draft.amountExpression = nil
    draft.currency = sheet.currency
    draft.rate = sheet.rate
    draft.rateDate = sheet.rateDate
    draft.rateSource = sheet.rateSource
    draft.rateProvisional = sheet.rateProvisional
    draft.paymentMethodId = sheet.paymentMethodId
    // A card the draft kept stays only with its own account: income on another account the
    // sheet chose would name a card of the first one, and its save would be refused.
    draft.cardId = CardRules.cardAfterAccountChange(
      draft.cardId, to: sheet.paymentMethodId, cards: liveCards)
    draft.parts = [PartDraft(amount: sheet.amount, forPersonId: person)]
    // What the sheet held is the owner's: no default laid later replaces it.
    currencyFromDefaults = nil
    paymentMethodFromDefaults = nil
    accountFromTheScreen = false
    switch route {
    case .income:
      if let person {
        let words =
          personPhraseFromTheLine.flatMap { $0.id == person ? $0.text : nil }
          ?? people.first { $0.id == person }.map { fromNote($0.name) }
        if let words, !(draft.note ?? "").contains(words) {
          draft.note = [draft.note, words].compactMap { $0 }.joined(separator: " ")
        }
      }
      draft.kind = .income
      applyDefaults(today: today)
    case .debtRepayment(let debt):
      draft.debtId = debt
      refreshCharge()
    }
    // What the account received, typed or prefilled in the sheet, stays as it was there.
    if let received = sheet.accountAmount, !received.isZero { setCharge(received) }
    // The owner has just confirmed a form: Enter does not stop to ask for a category of it.
    if let gap = EntryCompleteness.gap(of: draftForSaving, tree: categoryTree) {
      gapStop = GapStop(gap: gap, line: lastLine, text: lastLineText, waived: true)
    }
  }

  /// The debt the written operation pays or grows, if any: the one the operation as written
  /// names — a refund names none, whatever the panel held before the kind changed — read
  /// afresh, so a debt made in Debts since the line last read its dictionaries gets its line.
  public func debtPaid(by entry: TransactionEntry) -> Debt? {
    guard let id = entry.transaction.debtId else { return nil }
    if let current = try? references?.debts() { debts = current }
    return debts.first { $0.id == id }
  }

  /// Whether the purchase is on credit: a plan being made in the line, or a debt the saved
  /// purchase joined. The box of the panel reads this, in the line and in the editor alike.
  public var isOnCredit: Bool { creditPlan != nil || draft.creditDebtId != nil }

  /// A purchase is put on credit when it is recorded: the line opens the debt, or joins one,
  /// in the same write. The editor writes the operation and its journal line only — a plan
  /// made there was never written, and taking a purchase off its debt from there made it
  /// deletable, though a purchase that moved a debt is never deleted from the list — so a
  /// saved purchase is changed in Debts.
  public var canChangeCredit: Bool { !editsSavedOperation }

  /// Only a purchase is bought on credit: an income or a refund on credit opened an instalment
  /// debt that nothing bought. The switch is offered for a purchase in the entry line.
  public var offersCredit: Bool { canChangeCredit && draft.kind.canBeBoughtOnCredit }

  /// An income or a refund saved on credit before only a purchase could be — such rows exist —
  /// is edited as it is: its note or category changes, and the debt stays as it was saved.
  /// What is refused is turning an operation on credit into another kind that is never bought
  /// on credit.
  private var keepsTheSavedCredit: Bool {
    editsSavedOperation && creditPlan == nil && draft.kind == kindWithTheCredit
  }

  /// A kind that cannot be bought on credit drops the plan made for the purchase it was — in
  /// the panel and by a line that says «+» alike. A saved operation keeps its debt: the editor
  /// refuses the change instead (`saveRefusalKey`).
  private func dropTheCreditTheKindCannotCarry() {
    guard canChangeCredit, !draft.kind.canBeBoughtOnCredit else { return }
    creditPlan = nil
    draft.creditDebtId = nil
  }

  /// The link of income to an expected one is written by the line with the income. An income
  /// already saved is tied to what was expected in Planning.
  public var linksExpectedIncome: Bool { !editsSavedOperation }

  // MARK: Credit plan

  /// A debt keeps no term: it is paid off in ⌈balance ÷ monthly payment⌉ months (`DebtPayoff`,
  /// the payoff scenario of the Debts card). The count of payments the panel shows is therefore kept in
  /// the instalment it gives, and the two move together: the count chosen makes
  /// the instalment, an instalment typed makes the count, and the amount corrected keeps the
  /// count and moves the instalment.
  public static let creditPaymentsRange = 1...120

  /// The count chosen with the stepper: the instalment is the amount split into that many.
  public func setCreditPayments(_ payments: Int) {
    guard var plan = creditPlan else { return }
    plan.payments =
      plan.instalments ? Self.withinParts(payments) : Self.withinRange(payments)
    plan.monthlyAmount = instalment(of: plan)
    creditPlan = plan
  }

  /// An instalment typed by hand: the count is how many of them pay the amount off, the last
  /// one smaller. An empty field leaves the count as it was.
  public func setCreditMonthly(_ monthly: AmountE4) {
    guard var plan = creditPlan, plan.monthlyAmount != monthly else { return }
    plan.monthlyAmount = monthly
    if monthly.raw > 0, draft.amount.raw > 0 {
      let count = (draft.amount.raw + monthly.raw - 1) / monthly.raw
      plan.payments = Self.withinRange(Int(clamping: count))
    }
    creditPlan = plan
  }

  /// The total of the operation, as the amount field of the panel sets it. A draft with a
  /// single part keeps that part in step; a split keeps its parts and shows what is left.
  ///
  /// `typed` is the text of the field. `amount_expr` is the formula the amount was worked out
  /// from: a formula typed in the field becomes it, and one that no longer
  /// comes to the total goes, instead of standing in the table over another amount. The field
  /// writing back the amount it shows is not a correction and keeps it.
  public func setTotal(_ amount: AmountE4, typed text: String? = nil) {
    if amount != draft.amount { noteTheOpenedDraft() }
    draft.amount = amount
    // An emptied field reads as zero too; only a number typed there is a zero typed.
    zeroWasTyped = amount.isZero && !(text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    if draft.parts.count == 1 { draft.parts[0].amount = amount }
    draft.amountExpression = Self.formula(
      typed: text, keeping: draft.amountExpression, for: amount)
    followTheAmountInTheCreditPlan()
    refreshCharge()
  }

  /// The formula behind `amount`: the one typed, when the text is one, its numbers written the
  /// way the app writes them; otherwise the one kept, while it still comes to the amount. The
  /// one kept stays exactly as it is: the field writes back the amount it shows as soon as an
  /// operation is opened, and that is not an edit to save (the editor rewrites it on save).
  private static func formula(
    typed text: String?, keeping kept: String?, for amount: AmountE4
  )
    -> String?
  {
    if let typed = text?.trimmingCharacters(in: .whitespaces),
      ExpressionEvaluator.isFormula(typed), comes(typed, to: amount)
    {
      return ExpressionEvaluator.canonical(typed) ?? typed
    }
    guard let kept, comes(kept, to: amount) else { return nil }
    return kept
  }

  private static func comes(_ formula: String, to amount: AmountE4) -> Bool {
    guard let value = try? ExpressionEvaluator.evaluate(formula) else { return false }
    return (try? AmountE4(decimal: value)) == amount
  }

  /// The count stands and the instalment follows a new amount.
  private func followTheAmountInTheCreditPlan() {
    guard var plan = creditPlan else { return }
    let monthly = instalment(of: plan)
    guard plan.monthlyAmount != monthly else { return }
    plan.monthlyAmount = monthly
    creditPlan = plan
  }

  private static func withinRange(_ payments: Int) -> Int {
    min(max(payments, creditPaymentsRange.lowerBound), creditPaymentsRange.upperBound)
  }

  /// The largest share of `amount` split into `payments`: that many of it pay the amount off.
  static func instalment(of amount: AmountE4, over payments: Int) -> AmountE4 {
    guard amount.raw > 0 else { return .zero }
    return amount.split(into: payments).first ?? .zero
  }

  /// Turns the plan on with a sensible instalment: the whole amount split evenly.
  public func startCreditPlan() {
    guard offersCredit, creditPlan == nil else { return }
    let payments = 12
    creditPlan = CreditPlan(
      debtId: nil, payments: payments,
      monthlyAmount: Self.instalment(of: draft.amount, over: payments))
    // A purchase on credit moves the debt, not the account.
    refreshCharge()
  }

  public func stopCreditPlan() {
    guard canChangeCredit else { return }
    creditPlan = nil
    draft.creditDebtId = nil
    refreshCharge()
  }

  public func reset() {
    // A transfer written or thrown away: the next entry is an operation again.
    transfer = nil
    ruleState = EntryRuleState()
    // The figure typed for the operation just saved is not the next one's.
    cashbackField = CashbackFieldState()
    // Nor is the month chosen or laid for it.
    periodMonthChosen = false
    periodMonthFromDefaults = nil
    draft = TransactionDraft(currency: defaultCurrency)
    draft.normalizeSinglePart()
    currencyFromDefaults = defaultCurrency
    eventFromDefaults = nil
    layTheTripEvent()
    accountFromTheScreen = false
    chargeTyped = false
    chargeTypedFor = nil
    chargeNeedsCheck = false
    rateFromTheCharge = false
    cashRateLaid = nil
    cashRates = [:]
    chargeIsProvisional = false
    answeredCount = nil
    zeroWasTyped = false
    // The names belonged to the line just saved: the next operation is not offered them.
    suggestedPersonName = nil
    suggestedPlaceName = nil
    unmatchedPersonPhrase = nil
    unmatchedPlacePhrase = nil
    noteFromTheLine = nil
    cashbackFromTheLine = nil
    dateFromTheLine = draft.occurredAt
    amountFromTheLine = nil
    dateFollowsTheClock = true
    paymentMethodFromDefaults = nil
    forWhomFromDefaults = .me
    // So were the suggestions: the event, the chips, where each came from, what the model said.
    suggestedEvent = nil
    categorySuggestions = []
    suggestionSources = [:]
    lastPrediction = nil
    lastQuestion = nil
    creditPlan = nil
    expectedIncomeId = nil
    creationFailureKey = nil
    refundTarget = nil
    refundWithoutPurchase = false
    refundPicking = nil
    pickBase = nil
    lineOfThePick = nil
    lastLine = nil
    lastLineText = nil
    typedFills = TypedFills()
    personPhraseFromTheLine = nil
    // «За кого» belonged to the operation just saved.
    payingFor = .me
    payingForWay = nil
    gapStop = nil
    focusRequest = nil
    stampedAt = nil
    repeatConfirmed = false
    aheadAnswered = false
    overLimitAnswered = false
    minBalanceAnswered = false
    pauseAnswered = false
    mileageAnswered = false
    closesDebtTerm = false
    paysFromAccount = false
    paysFromAccountByTheLine = false
    cardFromDefaults = nil
    lineSaysSelfEmployed = false
    warrantyFromTheLine = nil
    returnFromTheLine = nil
    discountFromTheLine = nil
    prepayChoice = nil
  }

  // MARK: Refund of a purchase

  /// The purchase part a refund takes money back from, as picked: the refund is made in the
  /// purchase's currency at the purchase's rate, so taking back the whole part takes it to zero
  /// exactly.
  public struct RefundTarget: Hashable, Sendable {
    public var purchase: TransactionEntry
    public var part: TransactionPart

    public init(purchase: TransactionEntry, part: TransactionPart) {
      self.purchase = purchase
      self.part = part
    }
  }

  /// The purchase the refund takes back from, once picked.
  public private(set) var refundTarget: RefundTarget?
  /// «Без покупки»: a refund of something bought before the ledger, or taken out of a goal —
  /// counted on its own, as refunds always were. Chosen after a purchase was picked, it takes
  /// nothing back from that purchase any more.
  public var refundWithoutPurchase = false {
    didSet {
      guard refundWithoutPurchase, !oldValue else { return }
      if refundTarget != nil || pickBase != nil {
        forgetTheRefundedPurchase()
        refreshCharge()
      }
      lineOfThePick = lastLine
    }
  }
  /// The draft as it was before a purchase was picked, and what its defaults were: another
  /// purchase is picked from it, and forgetting the purchase — another kind, «Без покупки»,
  /// another line — brings it back, so nothing the purchase brought (its currency, rate,
  /// account, category) stays behind.
  private var pickBase: PickBase?
  private struct PickBase {
    var draft: TransactionDraft
    var paymentMethodFromDefaults: UUID?
    var currencyFromDefaults: CurrencyCode?
    var forWhomFromDefaults: ForWhomChoice?
    var accountFromTheScreen: Bool
  }
  /// The line the purchase was picked for, and the line applied last.
  private var lineOfThePick: ParsedInput?
  private var lastLine: ParsedInput?
  /// The text of the line applied last, as the entry bar handed it over.
  private var lastLineText: String?

  /// A field the line filled from a word while it was being typed, with what the field held
  /// before the line touched it.
  private struct TypedFill<Value: Equatable>: Equatable {
    var filled: Value
    var before: Value
  }
  /// The account with what goes with it: whether the defaults laid it, whether it is the open
  /// screen's, and its card.
  private struct AccountState: Equatable {
    var accountId: UUID?
    var fromDefaults: UUID?
    var fromTheScreen: Bool
    var cardId: UUID?
  }
  /// What the open panel's reading of the line as it is typed filled from the words of the line
  /// (`apply(_:amount:today:text:whileTyping:)`). The panel reads the line at every keystroke,
  /// so it reads every half-typed word on the way too — «бат» on the way to «батон» is the baht,
  /// «Магнит» on the way to «магнитик» a shop, «аванс» on the way to «авансом» a salary. The
  /// next reading takes back each field the line no longer names, while the field still holds
  /// what the line put there: a choice the panel made since is the owner's and stays. Empty
  /// after a reading of the whole line at Enter, which keeps what it reads as it always did.
  private struct TypedFills: Equatable {
    var kind: TypedFill<TransactionKind>?
    var currency: TypedFill<CurrencyCode>?
    var currencyFromDefaults: CurrencyCode?
    var placeId: TypedFill<UUID?>?
    var account: TypedFill<AccountState>?
    var debtId: TypedFill<UUID?>?
    var eventId: TypedFill<UUID?>?
    var forWhom: TypedFill<ForWhomChoice>?
    var forWhomFromDefaults: ForWhomChoice?
    var amount: TypedFill<LineAmount>?
    var amountFromTheLine: LineAmount?
    var zeroWasTyped = false
  }
  private var typedFills = TypedFills()

  /// The amount and its formula as the draft holds them.
  private var heldAmount: LineAmount {
    LineAmount(amount: draft.amount, expression: draft.amountExpression)
  }

  /// The fields a line fills from its words, as they stand before a reading.
  private struct TypedState {
    var kind: TransactionKind
    var currency: CurrencyCode
    var currencyFromDefaults: CurrencyCode?
    var placeId: UUID?
    var account: AccountState
    var debtId: UUID?
    var eventId: UUID?
    var forWhom: ForWhomChoice
    var forWhomFromDefaults: ForWhomChoice?
    var amount: LineAmount
    var amountFromTheLine: LineAmount?
    var zeroWasTyped: Bool

    @MainActor init(of model: EntryDraftModel) {
      let draft = model.draft
      kind = draft.kind
      currency = draft.currency
      currencyFromDefaults = model.currencyFromDefaults
      placeId = draft.placeId
      account = model.accountState
      debtId = draft.debtId
      eventId = draft.parts.first?.eventId
      forWhom = draft.parts.first.map(ForWhomChoice.init(of:)) ?? .me
      forWhomFromDefaults = model.forWhomFromDefaults
      amount = model.heldAmount
      amountFromTheLine = model.amountFromTheLine
      zeroWasTyped = model.zeroWasTyped
    }
  }

  /// The fills of a reading made while typing: every field `parsed` names, as the draft holds
  /// it now, with what it held before the line first filled it — kept from an earlier reading
  /// that filled it already.
  private func recordingTypedFills(of parsed: ParsedInput, before: TypedState) -> TypedFills {
    var fills = typedFills
    func fill<Value: Equatable>(
      _ kept: TypedFill<Value>?, _ now: Value, _ was: Value
    ) -> TypedFill<Value> {
      TypedFill(filled: now, before: kept?.before ?? was)
    }
    if parsed.kind != .expense {
      fills.kind = fill(fills.kind, draft.kind, before.kind)
    }
    if parsed.currency != nil {
      if fills.currency == nil { fills.currencyFromDefaults = before.currencyFromDefaults }
      fills.currency = fill(fills.currency, draft.currency, before.currency)
    }
    if parsed.placeId != nil {
      fills.placeId = fill(fills.placeId, draft.placeId, before.placeId)
    }
    if parsed.paymentMethodId != nil {
      fills.account = fill(fills.account, accountState, before.account)
    }
    if parsed.debtId != nil {
      fills.debtId = fill(fills.debtId, draft.debtId, before.debtId)
    }
    if parsed.eventId != nil {
      fills.eventId = fill(fills.eventId, draft.parts.first?.eventId, before.eventId)
    }
    if parsed.forWhom != nil || parsed.personId != nil, let first = draft.parts.first {
      if fills.forWhom == nil { fills.forWhomFromDefaults = before.forWhomFromDefaults }
      fills.forWhom = fill(fills.forWhom, ForWhomChoice(of: first), before.forWhom)
    }
    // Only an amount the line wrote: one the panel changed stays the owner's.
    if parsed.amount != nil, amountFromTheLine == heldAmount {
      if fills.amount == nil {
        fills.amountFromTheLine = before.amountFromTheLine
        fills.zeroWasTyped = before.zeroWasTyped
      }
      fills.amount = fill(fills.amount, heldAmount, before.amount)
    }
    return fills
  }

  private var accountState: AccountState {
    AccountState(
      accountId: draft.paymentMethodId, fromDefaults: paymentMethodFromDefaults,
      fromTheScreen: accountFromTheScreen, cardId: draft.cardId)
  }

  /// Gives back what the line typed so far filled and `parsed` no longer names (`TypedFills`),
  /// and forgets every fill the panel has changed since.
  private func takeBackWhatTheTypedLineNoLongerSays(_ parsed: ParsedInput) {
    var fills = typedFills
    if let fill = fills.kind, parsed.kind == .expense || draft.kind != fill.filled {
      if draft.kind == fill.filled { draft.kind = fill.before }
      fills.kind = nil
    }
    if let fill = fills.currency, parsed.currency == nil || draft.currency != fill.filled {
      if draft.currency == fill.filled, currencyFromDefaults == nil {
        draft.currency = fill.before
        currencyFromDefaults = fills.currencyFromDefaults
      }
      fills.currency = nil
    }
    if let fill = fills.placeId, parsed.placeId == nil || draft.placeId != fill.filled {
      if draft.placeId == fill.filled { draft.placeId = fill.before }
      fills.placeId = nil
    }
    if let fill = fills.account,
      parsed.paymentMethodId == nil || accountState != fill.filled
    {
      if accountState == fill.filled {
        draft.paymentMethodId = fill.before.accountId
        paymentMethodFromDefaults = fill.before.fromDefaults
        accountFromTheScreen = fill.before.fromTheScreen
        draft.cardId = fill.before.cardId
      }
      fills.account = nil
    }
    if let fill = fills.debtId, parsed.debtId == nil || draft.debtId != fill.filled {
      if draft.debtId == fill.filled { draft.debtId = fill.before }
      fills.debtId = nil
    }
    if let fill = fills.eventId, parsed.eventId == nil || draft.parts.first?.eventId != fill.filled
    {
      if draft.parts.count == 1, draft.parts[0].eventId == fill.filled {
        draft.parts[0].eventId = fill.before
      }
      fills.eventId = nil
    }
    if let fill = fills.forWhom,
      (parsed.forWhom == nil && parsed.personId == nil)
        || draft.parts.first.map(ForWhomChoice.init(of:)) != fill.filled
    {
      if draft.parts.count == 1, ForWhomChoice(of: draft.parts[0]) == fill.filled {
        draft.parts[0].forWhom = fill.before.value
        draft.parts[0].forPersonId = fill.before.personId
        forWhomFromDefaults = fills.forWhomFromDefaults
      }
      fills.forWhom = nil
    }
    // A number rubbed out takes its amount back; a formula half typed («250+») reads as no
    // amount for a moment and keeps it.
    if let fill = fills.amount,
      (parsed.amount == nil && parsed.amountProblem == nil) || heldAmount != fill.filled
    {
      if heldAmount == fill.filled, parsed.amount == nil {
        draft.amount = fill.before.amount
        draft.amountExpression = fill.before.expression
        amountFromTheLine = fills.amountFromTheLine
        zeroWasTyped = fills.zeroWasTyped
        if draft.parts.count == 1 { draft.parts[0].amount = draft.amount }
        followTheAmountInTheCreditPlan()
      }
      fills.amount = nil
    }
    typedFills = fills
  }

  /// Whom the line named and in its own words — «от Ани» —, for the note of money back
  /// recorded as income instead.
  private var personPhraseFromTheLine: (id: UUID, text: String)?
  /// The picker of purchases is asked for; whoever holds the line presents it.
  public var refundPicking: RefundPickerRequest?

  /// The panel offers to pick the purchase a new refund takes money back from. A saved refund
  /// keeps the purchase it was recorded against.
  public var offersRefundPurchase: Bool { !editsSavedOperation && draft.kind == .refund }

  /// A new refund that has not been told its purchase yet: Enter opens the picker first.
  public var needsRefundPurchase: Bool {
    !editsSavedOperation && draft.kind == .refund && refundTarget == nil && !refundWithoutPurchase
  }

  /// What the picker narrows the purchases by: the words, the place and the amount of the line.
  /// The currency only when the owner said one — typed in the line or picked in the panel: one
  /// the defaults laid (the default currency, the currency of the account whose screen is open)
  /// says nothing about the purchase, and an amount without a code is in the purchase's own.
  public var refundQuery: RefundQuery {
    let base = pickBase?.draft ?? draft
    let laid = pickBase?.currencyFromDefaults ?? currencyFromDefaults
    return RefundQuery(
      words: noteFromTheLine ?? base.note, placeId: base.placeId,
      amount: base.amount.raw > 0 ? base.amount : nil,
      currency: (laid != nil && base.currency == laid) ? nil : base.currency,
      latestDay: calendar.day(of: draft.occurredAt))
  }

  /// The refund takes back `amount` of the part — all that is left of it when nil. The draft
  /// becomes that refund: the purchase's currency and rate, its category, quality, «на кого»,
  /// person, event and place; its account unless the owner chose one; the note and the date
  /// stay the line's.
  public func chooseRefund(of candidate: RefundCandidate, amount: AmountE4?) {
    // Another purchase is picked from the draft as it was before the first one: the account
    // the first purchase brought is not the owner's choice.
    let base =
      pickBase
      ?? PickBase(
        draft: draft, paymentMethodFromDefaults: paymentMethodFromDefaults,
        currencyFromDefaults: currencyFromDefaults, forWhomFromDefaults: forWhomFromDefaults,
        accountFromTheScreen: accountFromTheScreen)
    let accountChosen =
      base.draft.paymentMethodId != nil && base.paymentMethodFromDefaults == nil
    // A thing bought in instalments is refunded as any purchase is: the plan it was bought on
    // is asked about when the refund is written (`InstalmentReturnSheet`).
    var purchase = candidate.purchase
    if instalmentPlan(of: purchase) != nil { purchase.transaction.creditDebtId = nil }
    let refund = try? RefundRules.draft(
      refunding: candidate.part, of: purchase, amount: amount ?? candidate.remaining,
      occurredAt: draft.occurredAt,
      accountId: accountChosen ? base.draft.paymentMethodId : nil,
      index: RefundIndex.empty, tree: categoryTree)
    guard var refund else { return }
    // The words of the line describe the refund; with none, the purchase's do.
    refund.note = base.draft.note ?? refund.note
    refund.amountExpression = nil
    // The purchase's account is archived since: money on it would count nowhere, so it comes
    // onto the account a new operation would take.
    var accountByDefault: UUID?
    if !accountChosen, let id = refund.paymentMethodId, !isLiveAccount(id) {
      accountByDefault = self.accountByDefault(at: refund.placeId, in: otherOperations()).chosen
      refund.paymentMethodId = accountByDefault
    }
    // The card the owner named with the account takes the money back; else the card that paid
    // for the purchase, while it is live and of the account the refund comes onto.
    let namedCard =
      accountChosen
      ? CardRules.cardAfterAccountChange(
        base.draft.cardId, to: refund.paymentMethodId, cards: liveCards)
      : nil
    refund.cardId =
      namedCard
      ?? CardRules.cardAfterAccountChange(
        candidate.purchase.transaction.cardId, to: refund.paymentMethodId, cards: liveCards)
    draft = refund
    pickBase = base
    lineOfThePick = lastLine
    // The purchase's currency, account and «на кого» are the refund's own now: no default
    // laid later — another place, another day — replaces them.
    currencyFromDefaults = nil
    paymentMethodFromDefaults = accountByDefault
    forWhomFromDefaults = nil
    accountFromTheScreen = false
    refundWithoutPurchase = false
    refundTarget = RefundTarget(purchase: candidate.purchase, part: candidate.part)
    refreshCharge()
  }

  /// The refund stops taking back from the purchase: an ordinary refund again, as the draft was
  /// before the purchase was picked — in its kind and on its day of now.
  public func forgetTheRefundedPurchase() {
    refundTarget = nil
    lineOfThePick = nil
    if let base = pickBase {
      let kind = draft.kind
      let occurredAt = draft.occurredAt
      draft = base.draft
      draft.kind = kind
      draft.occurredAt = occurredAt
      paymentMethodFromDefaults = base.paymentMethodFromDefaults
      currencyFromDefaults = base.currencyFromDefaults
      forWhomFromDefaults = base.forWhomFromDefaults
      accountFromTheScreen = base.accountFromTheScreen
      pickBase = nil
    }
    for index in draft.parts.indices { draft.parts[index].refundOfPartId = nil }
  }

  /// A refund that takes money back from a purchase part — picked here, or saved so.
  public var takesBackFromAPurchase: Bool { RefundRules.takesBack(draft) }

  /// «Разделить»: a kind that is split, and not a refund of a purchase, which takes back one
  /// amount of one part — nor the difference of a count, whose money follows the books.
  public var canSplit: Bool {
    has(.split) && !takesBackFromAPurchase && !isReconcileDifference
  }

  /// «За другого»: a kind that has it, and not a refund of a purchase or a difference of a
  /// count.
  public var canMarkPaidForSomeone: Bool {
    has(.reimbursable) && !takesBackFromAPurchase && !isReconcileDifference
  }

  /// The rate can be typed — not on a refund of a purchase, which is at the purchase's rate.
  public var canTypeRate: Bool { !takesBackFromAPurchase }

  /// The account a new operation takes by itself: the one whose screen is open, else the last
  /// one used at `place`, else the main account. Only live accounts.
  private func accountByDefault(
    at place: UUID?, in history: [TransactionEntry]
  ) -> (chosen: UUID?, screen: UUID?) {
    let atThePlace = place.flatMap { place in
      history.first { $0.transaction.placeId == place }
    }?.transaction.paymentMethodId
    let screen = openAccountScreen?().flatMap { isLiveAccount($0) ? $0 : nil }
    let chosen = AccountRules.accountForNewOperation(
      typed: nil, openAccountScreen: screen,
      lastAtPlace: atThePlace.flatMap { isLiveAccount($0) ? $0 : nil },
      main: paymentMethods.first(where: \.isDefault)?.id)
    return (chosen, screen)
  }

  /// A kind other than a refund takes nothing back.
  private func dropTheRefundTheKindCannotCarry() {
    guard draft.kind != .refund, refundTarget != nil || refundWithoutPurchase else { return }
    forgetTheRefundedPurchase()
    refundWithoutPurchase = false
  }

  /// What refunds already took back from the purchase, read at this moment: the purchase and
  /// everything saved after it.
  public func refundIndexNow() -> RefundIndex {
    guard let target = refundTarget else { return .empty }
    // Every operation, not only those after the purchase: a refund may be dated earlier on
    // the purchase's day, or before it.
    let entries = (try? transactions?.entries(from: .distantPast, to: .distantFuture)) ?? nil
    return RefundIndex(entries: entries ?? [target.purchase], debts: [:])
  }

  /// The rubles the refund is written with: what is left of the part's rubles when it takes the
  /// rest of the part, otherwise its share at the purchase's rate — never the rubles of the day
  /// (`RefundRules.rubles`). `index` knows the refunds already made, read at the moment of
  /// saving. Refused when the amount is more than what is left.
  public func refundRubles(index: RefundIndex) throws -> (AmountE4) throws -> AmountE4 {
    guard let target = refundTarget else { throw RefundError.notRefundable }
    guard
      RefundRules.isRefundable(
        part: target.part, in: target.purchase, tree: categoryTree,
        creditDebt: instalmentPlan(of: target.purchase))
    else { throw RefundError.notRefundable }
    let left = RefundRules.remaining(part: target.part, index: index)
    guard draft.amount.raw > 0 else { throw RefundError.notPositive }
    guard draft.amount <= left else { throw RefundError.exceedsRemaining }
    let before = RefundRules.refundedBefore(part: target.part, index: index)
    let part = target.part
    return { amount in
      RefundRules.rubles(refundAmount: amount, part: part, refundedBefore: before)
    }
  }
}

/// The picker of purchases, asked for by Enter on a refund or by the ↓ panel.
public struct RefundPickerRequest: Identifiable, Hashable, Sendable {
  public let id = UUID()
  /// Enter asked: once a purchase is picked — or «Без покупки» — the refund is saved.
  public var savesAfterChoice: Bool

  public init(savesAfterChoice: Bool) {
    self.savesAfterChoice = savesAfterChoice
  }
}

extension TransactionKind {
  /// Only a purchase is bought on credit: an income, a refund or money back buys nothing, and a
  /// debt opened for one would be paid off by nothing.
  var canBeBoughtOnCredit: Bool { self == .expense }
}
