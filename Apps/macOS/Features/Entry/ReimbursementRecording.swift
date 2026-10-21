import AppCore
import AppDatabase
import Foundation

/// Everything one reimbursement writes, worked out before anything touches the database.
/// The sheet only collects the choices; this is where they become operations and links,
/// so the rules can be checked without a window.
///
/// This is the per-part mode («Вручную…»), worked out in rubles: every part is owed as the
/// rubles still left of it (`OwedPart.inRubles`), and the reimbursement, the surplus, the
/// shortfalls and `reimbursement_links.amount_e4` are all rubles. Matching a part paid in
/// dollars against the dollar figure used to turn most of the money into a surplus that never
/// existed. The money lands on the account it came onto («На счёт»), and so does a surplus; a
/// shortfall is spending from the account the purchase was paid from. Money back spread by the
/// rules in its own currency is `MoneyBackConfirmation`.
struct ReimbursementRecording {
  let outcome: ReimbursementOutcome
  let reimbursement: TransactionEntry
  /// The surplus income and the shortfall expenses, when the money did not match.
  let extra: [TransactionEntry]

  /// Why nothing was recorded, beyond the rules of the core (`ReimbursementError`).
  enum Failure: Error, Equatable {
    /// More came back than the parts cost, and the database has no Surcharges category for
    /// the surplus: it is income in that category and nowhere else, never income without
    /// a category.
    case noSurchargesCategory
    /// The parts are owed by different people, or by somebody other than the person chosen:
    /// money back is money from one person.
    case partsOfDifferentPeople
  }

  /// Whose money came back: one person, and only for what that person owes («выбираются
  /// человек и одна или несколько ожидающих частей»). A reimbursement that named nobody while
  /// closing somebody's parts would be missing from the person filter and from what that
  /// person gave back.
  enum Payer: Equatable {
    case person(UUID)
    /// Every part names nobody: it was entered before a part paid for someone had to name its
    /// debtor, and no person in the sheet lists it. The money back for it names
    /// nobody either — it does not invent a person.
    case nobody
    /// The parts are owed by different people, or by somebody other than the person chosen.
    case differentPeople

    var personId: UUID? {
      guard case .person(let id) = self else { return nil }
      return id
    }
  }

  /// The person chosen in the sheet; with «—», the one debtor every closed part names — the
  /// list then shows everybody's parts, and ticking Anya's names Anya.
  static func payer(chosen: UUID?, closing parts: [OwedPart]) -> Payer {
    let debtors = Set(parts.map(\.debtorPersonId))
    if let chosen {
      return debtors.allSatisfy { $0 == chosen } ? .person(chosen) : .differentPeople
    }
    guard debtors.count <= 1 else { return .differentPeople }
    return debtors.first.flatMap { $0 }.map(Payer.person) ?? .nobody
  }

  /// What the records need from the dictionaries and the interface language.
  struct Setting {
    var surchargesCategoryId: UUID?
    var categories: CategoryTree
    var history: ManualQualityHistory
    var surplusNote: String
    /// Only for a purchase that had no description of its own: a shortfall is otherwise
    /// described — and rated — by the purchase it is what is left of.
    var shortfallNote: String
  }

  /// `distribution` is what the sheet shows next to the chosen parts, in rubles. Only a
  /// distribution corrected by hand reaches the core; otherwise the core spreads `received`
  /// itself (`ReimbursementDistribution.allocation(over:)`). A part whose rate is still
  /// provisional is refused by the core.
  ///
  /// `personId` is the person chosen in the sheet, nil for «—»: the reimbursement names whose
  /// money it is (`payer`), and parts of different people are refused.
  ///
  /// `occurredAt` is the moment the money came — the day the entry line named — and the
  /// surplus and the shortfalls share it; `now` by default. `note` describes the reimbursement.
  ///
  /// `money` is what came when it was not rubles — 22 $ at `rate` (rubles a unit, from the
  /// statement or the bank, as `rateSource` says) —: `received` is then its rubles, which the
  /// parts share, the money back is written in its own currency with those rubles, and a
  /// surplus is income in that currency at that rate.
  ///
  /// Less than a kopeck either way is never written: neither a surplus nor a shortfall. Money
  /// in another currency that comes to what the parts cost but for the rounding of its four
  /// decimals — 1,000 ₽ at 95 are 10.5263 $, which are 999.9985 ₽ — closes them at what they
  /// cost; the money back keeps its own rubles, and the crumb between them is drift.
  static func make(
    id: UUID,
    received: AmountE4,
    closing parts: [OwedPart],
    distribution: ReimbursementDistribution,
    personId: UUID?,
    now: Date = Date(),
    occurredAt: Date? = nil,
    note: String? = nil,
    accountId: UUID? = nil,
    leg: MoneyLeg? = nil,
    money: Money? = nil,
    rate: Decimal? = nil,
    rateDate: DateOnly? = nil,
    rateSource: RateSource? = nil,
    setting: Setting
  ) throws -> ReimbursementRecording {
    let payer = payer(chosen: personId, closing: parts)
    guard payer != .differentPeople else { throw Failure.partsOfDifferentPeople }
    let owed = parts.map(\.inRubles)
    let foreign = money.flatMap { $0.currency == .rub ? nil : $0 }
    let allocation = distribution.allocation(over: owed)
    let owedRub = AmountE4.sum(owed.map(\.amountE4))
    let shared =
      foreign != nil && allocation == nil && (received - owedRub).magnitude < MoneyBack.crumb
      ? owedRub : received
    var outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id, amountE4: shared, closing: owed, allocation: allocation,
      accountId: accountId)
    if let surplus = outcome.surplus, surplus.amountE4 < MoneyBack.crumb { outcome.surplus = nil }
    outcome.shortfalls.removeAll { $0.amountE4 < MoneyBack.crumb }

    let day = occurredAt ?? now
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: day, currency: foreign?.currency ?? .rub,
      amount: foreign?.amount ?? received, rate: foreign == nil ? nil : rate,
      rateDate: foreign == nil ? nil : rateDate, rateSource: foreign == nil ? nil : rateSource,
      note: note, paymentMethodId: accountId, accountCurrency: leg?.currency,
      accountAmount: leg?.amount)
    draft.normalizeSinglePart()
    draft.parts[0].forPersonId = payer.personId
    let reimbursement = try draft.materialize(
      id: id, now: now, rublesConverter: { amount in foreign == nil ? amount : received })

    if let foreign, let surplus = outcome.surplus, received.raw > 0 {
      // The resolver works in rubles: the income is the same money in the currency it came in,
      // and none at all when that rounds to nothing.
      let rubles = surplus.amountE4
      let amount =
        (try? AmountE4(decimal: rubles.decimal * foreign.amount.decimal / received.decimal))
        ?? .zero
      outcome.surplus =
        amount.raw > 0
        ? SurchargeIncome(
          amountE4: amount, currency: foreign.currency, amountRubE4: rubles,
          accountId: surplus.accountId)
        : nil
    }
    var extra: [TransactionEntry] = []
    if let surplus = outcome.surplus {
      extra.append(
        try surplusEntry(
          surplus, of: id, on: day, now: now, rate: foreign == nil ? nil : rate,
          rateDate: rateDate, setting: setting))
    }
    let owedById = Dictionary(
      parts.map { ($0.partId, $0) }, uniquingKeysWith: { first, _ in first })
    for shortfall in outcome.shortfalls {
      extra.append(
        try shortfallEntry(
          shortfall, of: id, purchase: owedById[shortfall.partId], on: day, now: now,
          setting: setting))
    }
    return ReimbursementRecording(outcome: outcome, reimbursement: reimbursement, extra: extra)
  }

  // The surplus and the shortfalls point back at their reimbursement through `external_id`
  // (`ReimbursementCompanions`): deleting the reimbursement finds them by it and takes them
  // along.

  /// More money came back than I paid: the excess is income in the system Surcharges
  /// category, never in the category of the original spending — in the currency the money
  /// came in, at its rate, on the account it came onto.
  ///
  /// `rate` is the rate the money back itself came at, its rubles over its amount: the income
  /// shows that one — 95 for dollars that came at 95 —, while its rubles are exactly the rubles
  /// the parts left over, which may differ from the amount times the rate by the rounding of
  /// each part's share. Without it the rate is the surplus's rubles over its amount.
  static func surplusEntry(
    _ surplus: SurchargeIncome, of reimbursementId: UUID, on day: Date, now: Date,
    rate: Decimal? = nil, rateDate: DateOnly? = nil, setting: Setting
  ) throws -> TransactionEntry {
    guard let surcharges = setting.surchargesCategoryId else {
      throw Failure.noSurchargesCategory
    }
    return try MoneyBack.surplusEntry(
      surplus, of: reimbursementId, on: day, now: now, rate: rate, rateDate: rateDate,
      categoryId: surcharges, note: setting.surplusNote)
  }

  /// Less came back than I paid: the difference becomes my spending in the category the
  /// original part had, with a quality of its own like any other expense (every part
  /// has a quality).
  ///
  /// It is what is left of that purchase, so it takes the purchase's description — the note
  /// of the part, otherwise of its operation — and rule 2 of the qualities looks my rating
  /// up by it. The words of the interface would make the rating depend on the language the
  /// reimbursement happened to be recorded in.
  ///
  /// For the same reason it stays with the purchase's «for whom», person and event: the
  /// money I lost on a dinner for Anna during the trip is part of what Anna and the trip
  /// cost me. The person is whom the part was bought for, otherwise the one who
  /// owed it. It is my own spending now, so it owes nothing and names no debtor.
  private static func shortfallEntry(
    _ shortfall: ShortfallExpense, of reimbursementId: UUID, purchase: OwedPart?,
    on day: Date, now: Date, setting: Setting
  ) throws -> TransactionEntry {
    let purchaseDescription = purchase?.note
    var draft = TransactionDraft(
      kind: .expense, occurredAt: day, currency: .rub, amount: shortfall.amountE4,
      paymentMethodId: shortfall.accountId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = shortfall.categoryId
    draft.parts[0].categorySource = .system
    draft.parts[0].forWhom = shortfall.forWhom
    draft.parts[0].forPersonId = purchase?.forPersonId ?? purchase?.debtorPersonId
    draft.parts[0].eventId = purchase?.eventId
    draft.note = purchaseDescription ?? setting.shortfallNote
    let decision = QualityResolver.resolve(
      categoryId: shortfall.categoryId, description: purchaseDescription,
      categories: setting.categories, history: setting.history)
    draft.parts[0].quality = decision.quality
    draft.parts[0].qualitySource = decision.source
    var entry = try draft.materialize(now: now)
    entry.transaction.externalId = ReimbursementCompanions.shortfallKey(
      of: reimbursementId, partId: shortfall.partId)
    return entry
  }
}

/// What an account received, in a currency it holds, when it does not hold the operation's.
struct MoneyLeg: Hashable, Sendable {
  var currency: CurrencyCode
  var amount: AmountE4
}

/// The distribution the sheet shows next to every chosen part, in rubles.
///
/// It follows the money: a new amount in «Received», or a part ticked or unticked, spreads
/// it again, oldest first, the way the core does. A share corrected by hand stands until
/// the next spread.
///
/// Only a corrected distribution is handed to the core. An untouched one is the core's own
/// spread of the amount, so the core is left to make it from the amount actually recorded:
/// a spread made for an earlier amount — ticking a part fills «Received» with what the part
/// cost — never reaches it as a distribution larger than the money that came back.
struct ReimbursementDistribution: Equatable {
  private(set) var shares: [UUID: AmountE4] = [:]
  private(set) var isCorrectedByHand = false

  /// `received` is nil while «Received» holds no amount; every part then shows what it
  /// cost, the sum the field is filled with when a part is ticked.
  mutating func spread(_ received: AmountE4?, over parts: [OwedPart]) {
    let owed = parts.map(\.inRubles)
    let spread =
      received.map { ReimbursementResolver.allocate(amountE4: $0, over: owed) }
      ?? owed.map { ReimbursementAllocation(partId: $0.partId, amountE4: $0.amountE4) }
    shares = Dictionary(
      spread.map { ($0.partId, $0.amountE4) }, uniquingKeysWith: { first, _ in first })
    isCorrectedByHand = false
  }

  /// A share typed by hand. `AmountField` writes back every value it is shown, so writing
  /// the share that is already there is not a correction.
  mutating func correct(_ partId: UUID, to share: AmountE4) {
    guard shares[partId] != share else { return }
    shares[partId] = share
    isCorrectedByHand = true
  }

  func share(of partId: UUID) -> AmountE4 { shares[partId] ?? .zero }

  /// What the core is given for `parts`: the shares as the sheet shows them once one was
  /// corrected by hand, otherwise nil, and the core spreads the amount itself.
  func allocation(over parts: [OwedPart]) -> [ReimbursementAllocation]? {
    guard isCorrectedByHand else { return nil }
    return parts.map {
      ReimbursementAllocation(partId: $0.partId, amountE4: share(of: $0.partId))
    }
  }
}

/// Money back typed in the entry line — «вернули долг 1700 для Ани», or the type chosen in the
/// ↓ panel — as the reimbursement sheet opens with it: the rubles that came back, from whom,
/// on which day and with which words. The line does not write it itself: which parts the money
/// closes is chosen in the sheet.
struct ReimbursementPrefill: Identifiable, Equatable {
  let id = UUID()
  /// In rubles, like everything in the sheet: money typed in another currency is converted
  /// at the rate of the draft before the sheet opens.
  var received: AmountE4
  /// Whom the line or the panel named, if anyone.
  var personId: UUID?
  var occurredAt: Date
  var note: String?
  /// «На счёт»: the account the money came onto.
  var accountId: UUID?
  /// What the account received, when it does not hold rubles: in a currency it holds.
  var leg: MoneyLeg?

  init(draft: TransactionDraft, received: AmountE4, accounts: [PaymentMethod] = []) {
    self.received = received
    personId = draft.parts.first?.forPersonId
    occurredAt = draft.occurredAt
    note = draft.note
    accountId = draft.paymentMethodId
    leg = Self.leg(of: draft, accounts: accounts)
  }

  /// The sheet records rubles, and the account is told what it received in a currency it
  /// holds: the money itself when it holds the currency the money came in — rubles or not, an
  /// account holding rubles and dollars takes dollars on its dollar balance —, otherwise what
  /// the line's «Списано со счёта» said. Nil when that is the rubles themselves.
  static func leg(of draft: TransactionDraft, accounts: [PaymentMethod]) -> MoneyLeg? {
    guard let id = draft.paymentMethodId, let account = accounts.first(where: { $0.id == id })
    else { return nil }
    if account.holds(draft.currency) {
      return draft.currency == .rub ? nil : MoneyLeg(currency: draft.currency, amount: draft.amount)
    }
    guard let currency = draft.accountCurrency, currency != .rub,
      let amount = draft.accountAmount
    else { return nil }
    return MoneyLeg(currency: currency, amount: amount)
  }

  /// The parts ticked when the sheet opens: whatever the person owes that can be closed now,
  /// the way choosing the person in the sheet ticks them. Nothing when no person was named.
  func initialSelection(in owed: [OwedPart]) -> Set<UUID> {
    guard let personId else { return [] }
    return Set(
      owed.filter { $0.debtorPersonId == personId && !$0.rateProvisional }.map(\.partId))
  }
}

extension SettlementCounts {
  /// Writes to the journal how much the money that came back earlier was balanced again, when
  /// anything was — counts only; and says so when money over the parts stayed drift for want
  /// of the Surcharges category.
  func log() {
    guard !isEmpty else { return }
    AppLog.info(
      "settlement.rebalanced", .db, "money back was balanced again",
      [
        LogPair("parts", .count(parts)), LogPair("surpluses", .count(surpluses)),
        LogPair("companions", .count(companions)),
      ])
    if surplusesWithoutCategory > 0 {
      AppLog.warning(
        "settlement.noSurcharges", .db, "money over the parts stayed drift without Surcharges",
        [LogPair("surpluses", .count(surplusesWithoutCategory))])
    }
  }
}
