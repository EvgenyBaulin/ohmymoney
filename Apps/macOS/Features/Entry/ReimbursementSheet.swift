import AppCore
import AppDatabase
import SwiftUI

/// "Money back from a person": pick the person, pick the parts that are waiting and enter
/// what came back. The rules live in `CoreAccounting` — an excess becomes income in
/// Surcharges, a shortfall becomes my spending in the category of the original part, and
/// the reimbursement itself is never income.
///
/// The money may come in any currency, onto any account: «Валюта», «На счёт» and, for money not
/// in rubles, «Курс возврата». The distribution and what each part is owed are in rubles — the
/// money's rubles at its rate. An account that holds neither the money's currency nor rubles
/// asks what it was credited («Зачислено на счёт»); one whose main currency is rubles gets the
/// money's rubles. A bank rate that is only a guess — the day not published yet — is never
/// written as the bank's: the rate has to be typed. A part paid in another currency shows its own amount with the
/// rubles next to it; its purchase's rate can be corrected from the statement («Курс покупки»),
/// and the purchase is then written at it in the same write. One whose rate is still
/// provisional waits for the pipeline, unless its rate is typed.
///
/// Opened from the entry line, it starts from what was typed there (`prefill`): the money
/// that came back stays as typed while parts are ticked, and `recorded` tells the line the
/// reimbursement went in.
struct ReimbursementSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss

  private let prefill: ReimbursementPrefill?
  private let recorded: () -> Void

  @State private var owed: [OwedPart] = []
  @State private var selected: Set<UUID> = []
  /// The money that came back, in `currency`. Zero is nothing typed yet.
  @State private var received: AmountE4 = .zero
  @State private var currency: CurrencyCode = .rub
  @State private var accountId: UUID?
  @State private var accounts: [PaymentMethod] = []
  @State private var rates = RateTable()
  /// The rate of money not in rubles, typed; empty follows the bank's rate of the day.
  @State private var typedRate = ""
  /// What the account was credited, typed, when it holds neither the money's currency nor
  /// rubles; nil follows the line's figure or the bank's rates.
  @State private var typedLeg: AmountE4?
  /// The purchases in other currencies the parts belong to, and the rates typed for them.
  @State private var purchases: [UUID: TransactionEntry] = [:]
  @State private var purchaseRates: [UUID: String] = [:]
  /// Whether the text of «Received» reads: while it does not, `received` is the amount it read
  /// before, which the field no longer shows.
  @State private var receivedReads = true
  @State private var people: [Person] = []
  @State private var personId: UUID?
  @State private var errorText: String?
  /// What goes to each chosen part. Filled automatically and editable by hand, as the
  /// the rule is: the money that came back rarely matches the parts exactly.
  @State private var distribution = ReimbursementDistribution()
  /// Where «Received» came from: what the ticked parts cost, the rubles typed in the entry line
  /// — ticking a part spreads that money instead of replacing it —, or the owner's own typing.
  @State private var receivedSource: ReceivedSource
  /// The open «Мне должны» debts and what is left on each: the money over the parts may repay
  /// the debt of the person who gave it.
  @State private var debts: [Debt] = []
  @State private var debtBalances: [UUID: AmountE4] = [:]
  /// «Сверх частей … — в счёт долга»: on by default; off, the surplus is income in «Доплаты».
  @State private var surplusToDebt = true

  init(prefill: ReimbursementPrefill? = nil, recorded: @escaping () -> Void = {}) {
    self.prefill = prefill
    self.recorded = recorded
    // Set before the first draw, so the change of person does not fire and tick over it.
    _personId = State(initialValue: prefill?.personId)
    _received = State(initialValue: prefill?.received ?? .zero)
    _receivedSource = State(initialValue: prefill == nil ? .parts : .line)
    _accountId = State(initialValue: prefill?.accountId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: environment.language("reimbursement.title", table: "Entry"))
        .appFont(.headline)

      Picker(selection: $personId) {
        Text(verbatim: "—").tag(UUID?.none)
        ForEach(people, id: \.id) { person in
          Text(verbatim: person.name).tag(UUID?.some(person.id))
        }
      } label: {
        // Who gave the money back, not whom it was spent on.
        Text(verbatim: environment.language("entry.fromWhom", table: "Entry"))
      }
      .onChange(of: personId) { _, _ in selectAllOfPerson() }

      List {
        ForEach(filteredOwed, id: \.partId) { part in
          HStack {
            Toggle(isOn: binding(for: part.partId)) {
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(verbatim: part.note ?? "—")
                  Spacer()
                  Text(verbatim: amountText(for: part))
                    .appFont(.body.monospacedDigit())
                }
                if part.rateProvisional {
                  // The rubles a link fixes now would drift from the refined ones.
                  Text(verbatim: t("reimbursement.provisionalRate"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                }
                if part.returnedRubE4.raw > 0 {
                  // Some of it came back already: what is owed is the rest.
                  Text(
                    verbatim: environment.language.format(
                      "reimbursement.returnedSoFar", table: "Entry",
                      environment.money.exact(part.returnedRubE4))
                  )
                  .appFont(.caption)
                  .foregroundStyle(.secondary)
                }
              }
            }
            .toggleStyle(.checkbox)
            .disabled(part.rateProvisional)
            if selected.contains(part.partId) {
              AmountField(amount: allocationBinding(for: part))
                .frame(width: 110)
            }
            // Giving up on the money: the part stops waiting and becomes my spending — all of
            // it, or only the rest when some of it came back already.
            Button(
              environment.language(
                part.returnedRubE4.raw > 0 ? "reimbursement.writeOffRest" : "owed.writeOff",
                table: "Entry")
            ) {
              writeOff(part)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
          }
        }
      }
      .sheetFrame(minWidth: 460, minHeight: 180)

      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
        GridRow {
          Text(verbatim: t("entry.currency")).appFont(.caption).foregroundStyle(.secondary)
          Picker(selection: $currency) {
            ForEach(currencyChoices, id: \.code) { Text(verbatim: $0.code).tag($0) }
          } label: {
            Text(verbatim: t("entry.currency"))
          }
          .labelsHidden()
          .fixedSize()
          // A rate or a figure typed for the other currency means nothing for this one.
          .onChange(of: currency) { _, _ in
            typedRate = ""
            typedLeg = nil
          }
        }
        GridRow {
          Text(verbatim: t("entry.account.to")).appFont(.caption).foregroundStyle(.secondary)
          AccountPicker(title: t("entry.account.to"), accounts: accounts, selection: $accountId)
            .labelsHidden()
            .onChange(of: accountId) { _, _ in typedLeg = nil }
        }
        if let leg = legFigure {
          GridRow {
            Text(verbatim: t("moneyBack.received")).appFont(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
              AmountField(
                amount: Binding(
                  get: { leg.amount }, set: { typedLeg = $0.isZero ? nil : $0 })
              )
              .frame(width: 120)
              .accessibilityLabel(Text(verbatim: t("moneyBack.received")))
              Text(verbatim: leg.currency.code).foregroundStyle(.secondary)
            }
          }
        }
        MoneyBackRateRows(
          currency: currency, moneyRate: moneyRate, moneyRateLocked: false,
          typedMoneyRate: $typedRate, purchases: purchaseRows, purchaseRates: $purchaseRates)
      }
      // Another currency, rate or price of the parts: «Received» follows what it came from.
      .onChange(of: MoneyTerms(currency: currency, rate: moneyRate)) { _, _ in followTheMoney() }
      .onChange(of: purchaseRates) { _, _ in followTheMoney() }

      HStack {
        Text(verbatim: environment.language("reimbursement.received", table: "Entry"))
        // Typed like every amount: «1,500» is 1 500, a formula comes to its result. Typed here,
        // it stays as typed: the parts and the currency no longer change it.
        AmountField(
          amount: Binding(
            get: { received },
            set: { typed in
              guard typed != received else { return }
              received = typed
              receivedSource = .owner
            }),
          reads: $receivedReads
        )
        .frame(width: 120)
        // Typing less than the parts cost is how a shortfall is recorded: the shares
        // follow the amount, or they would stay larger than the money that came back.
        .onChange(of: received) { _, _ in spreadAutomatically() }
        .onChange(of: receivedReads) { _, _ in spreadAutomatically() }
        if currency != .rub {
          Text(verbatim: currency.code).foregroundStyle(.secondary)
        }
        Spacer()
        Text(verbatim: environment.money.exact(selectedTotal))
          .foregroundStyle(.secondary)
        Button(environment.language("reimbursement.spread", table: "Entry")) {
          spreadAutomatically()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selected.isEmpty)
      }

      // The person owes on a debt too, and more came back than the parts cost.
      if let over = surplusEstimate, let target = surplusDebt {
        Toggle(isOn: $surplusToDebt) {
          Text(
            verbatim: environment.language.format(
              "moneyBack.surplusToDebt", table: "Entry", environment.money.exact(over),
              target.debt.name))
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("reimbursement.surplusToDebt")
      }

      if let errorText {
        Text(verbatim: errorText)
          .appFont(.caption)
          .foregroundStyle(.red)
      } else if ReimbursementRecording.payer(chosen: personId, closing: selectedParts)
        == .differentPeople
      {
        // Why «Save» is off: with «—» the list shows everybody's parts.
        Text(verbatim: t("reimbursement.differentPeople"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: record)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(
            !Self.canRecord(closing: selectedParts, chosen: personId, received: amountValue))
      }
    }
    .padding(20)
    .onAppear {
      reload()
      startFromTheLine()
    }
  }

  /// What the entry line handed over: the parts the person it named owes are ticked, and the
  /// money typed there is spread over them.
  private func startFromTheLine() {
    guard let prefill, selected.isEmpty else { return }
    selected = prefill.initialSelection(in: owed)
    spreadAutomatically()
  }

  private var filteredOwed: [OwedPart] {
    guard let personId else { return pricedOwed }
    return pricedOwed.filter { $0.debtorPersonId == personId }
  }

  private var selectedParts: [OwedPart] { pricedOwed.filter { selected.contains($0.partId) } }

  /// What is owed as the rates typed for the purchases make it.
  private var pricedOwed: [OwedPart] {
    MoneyBackRateRows.owed(
      owed, purchases: purchases, rates: repricing, calendar: environment.calendar)
  }

  private var repricing: [UUID: Decimal] {
    MoneyBackRateRows.repricing(purchaseRates, among: purchaseRows)
  }

  /// A row for every purchase in a third currency one of the ticked parts belongs to — and one
  /// still on a provisional rate in the list: typing its rate lets its part be ticked.
  private var purchaseRows: [PurchaseRateRow] {
    let listed = Set(
      (personId == nil ? owed : owed.filter { $0.debtorPersonId == personId })
        .filter(\.rateProvisional).map(\.partId))
    return MoneyBackRateRows.rows(
      reaching: owed.filter { selected.contains($0.partId) || listed.contains($0.partId) },
      money: currency, purchases: purchases, note: { $0.note ?? "—" })
  }

  /// Rubles a unit of the money: 1 for rubles; the typed rate, else the bank's of the day.
  private var moneyRate: Decimal? {
    guard currency != .rub else { return 1 }
    if let typed = MoneyBackRateRows.typedRate(typedRate) { return typed }
    return rates.resolve(currency, on: environment.calendar.day(of: moment))?.rate.perUnit
  }

  private var moment: Date { prefill?.occurredAt ?? Date() }

  private var account: PaymentMethod? { accounts.first { $0.id == accountId } }

  /// «Зачислено на счёт»: what an account that holds neither the money's currency nor rubles
  /// was credited, in its main currency — typed; else the line's figure, for the line's own
  /// account and money; else the money at the bank's rates through rubles (zero when a rate is
  /// missing: the figure has to be typed). Nil for any other account.
  private var legFigure: MoneyLeg? {
    guard let account, let legCurrency = AccountRules.legCurrency(for: currency, account: account),
      legCurrency != .rub
    else { return nil }
    if let typedLeg { return MoneyLeg(currency: legCurrency, amount: typedLeg) }
    if currency == .rub, account.id == prefill?.accountId, let leg = prefill?.leg,
      leg.currency == legCurrency
    {
      return leg
    }
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: moment, currency: currency, amount: received)
    if currency != .rub, let typed = MoneyBackRateRows.typedRate(typedRate) {
      draft.rate = typed
      draft.rateSource = .manual
    }
    return MoneyBackConfirmation.prefilledLeg(
      for: draft, account: account, rates: rates, calendar: environment.calendar)
      ?? MoneyLeg(currency: legCurrency, amount: .zero)
  }

  private var currencyChoices: [CurrencyCode] {
    var codes = environment.vocabulary.enabledCurrencies
    if !codes.contains(.rub) { codes.insert(.rub, at: 0) }
    if !codes.contains(currency) { codes.append(currency) }
    return codes
  }

  /// What is still owed on the chosen parts in rubles — the money the person is expected to
  /// return: a part some money came back for already owes only the rest.
  private var selectedTotal: AmountE4 { AmountE4.sum(selectedParts.map(\.remainingRubE4)) }

  /// The part in the money it was paid in; a foreign one also shows what that was in rubles.
  private func amountText(for part: OwedPart) -> String {
    let own = environment.money.exact(part.amountE4, currency: part.currency)
    guard part.currency != .rub else { return own }
    return "\(own) ≈ \(environment.money.exact(part.amountRubE4))"
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }

  /// The money over the parts the figures of the sheet leave, in rubles; only for money in
  /// rubles: the debt takes it in its own currency.
  private var surplusEstimate: AmountE4? {
    guard currency == .rub, let money = amountValue, !selectedParts.isEmpty else { return nil }
    let owed = selectedParts.map(\.inRubles)
    let allocated: AmountE4
    if let allocation = distribution.allocation(over: owed) {
      allocated = AmountE4.sum(allocation.map(\.amountE4))
    } else {
      allocated = min(money, AmountE4.sum(owed.map(\.amountE4)))
    }
    let over = money - allocated
    return over >= MoneyBack.crumb ? over : nil
  }

  /// The debt of the person who gave the money that its surplus may repay.
  private var surplusDebt: (debt: Debt, balance: AmountE4)? {
    guard
      let person = ReimbursementRecording.payer(chosen: personId, closing: selectedParts).personId
    else { return nil }
    return ReimbursementRecording.debtForSurplus(
      of: person, in: .rub, among: debts, balances: debtBalances)
  }

  /// The money that came back in rubles, which the parts share: at its rate when it is not in
  /// rubles.
  private var amountValue: AmountE4? {
    guard let money = Self.received(received, reads: receivedReads) else { return nil }
    guard currency != .rub else { return money }
    guard let rate = moneyRate else { return nil }
    return try? AmountE4(decimal: money.decimal * rate)
  }

  /// The money that came back, once there is some and the field reads: nothing is not an
  /// amount to record, and neither is the amount left over from text that no longer reads
  /// («1,700» turned into «1,700+»).
  static func received(_ amount: AmountE4, reads: Bool) -> AmountE4? {
    reads && amount.raw > 0 ? amount : nil
  }

  private func binding(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { selected.contains(id) },
      set: { isOn in
        if isOn { selected.insert(id) } else { selected.remove(id) }
        followTheMoney()
      })
  }

  private func allocationBinding(for part: OwedPart) -> Binding<AmountE4> {
    Binding(
      get: { distribution.share(of: part.partId) },
      set: { distribution.correct(part.partId, to: $0) })
  }

  /// Spreads what came back over the chosen parts, oldest first, as the core does; a
  /// correction made by hand before is dropped.
  private func spreadAutomatically() {
    distribution.spread(amountValue, over: selectedParts)
  }

  /// «Received» as what it came from makes it now, and the shares spread over it again.
  private func followTheMoney() {
    received = Self.received(
      received, source: receivedSource, rate: moneyRate, owedRubles: selectedTotal,
      lineRubles: prefill?.received)
    spreadAutomatically()
  }

  /// The currency of the money and its rate, which «Received» follows.
  private struct MoneyTerms: Equatable {
    var currency: CurrencyCode
    var rate: Decimal?
  }

  /// Where «Received» came from, which decides what it holds once the ticked parts, the money's
  /// currency or its rate change.
  enum ReceivedSource: Equatable {
    /// What the ticked parts cost: it follows them, in the money's currency.
    case parts
    /// The rubles typed in the entry line, in the money's currency.
    case line
    /// Typed in the sheet: it stays as typed.
    case owner
  }

  /// «Received» once the parts, the currency or the rate changed: what the parts cost or the
  /// line's rubles, at the money's rate `rate` (rubles a unit, 1 for rubles; zero while there is
  /// no rate) — 1,000 ₽ of parts are 10.5263 $ at 95, never 1,000 $ —, or, typed by the owner,
  /// as typed.
  static func received(
    _ current: AmountE4, source: ReceivedSource, rate: Decimal?, owedRubles: AmountE4,
    lineRubles: AmountE4?
  ) -> AmountE4 {
    switch source {
    case .owner: current
    case .parts: inMoney(owedRubles, rate: rate) ?? .zero
    case .line: inMoney(lineRubles ?? .zero, rate: rate) ?? .zero
    }
  }

  /// Rubles in money at `rate` rubles a unit; nil without a rate.
  static func inMoney(_ rubles: AmountE4, rate: Decimal?) -> AmountE4? {
    guard let rate, rate > 0 else { return nil }
    guard rate != 1 else { return rubles }
    return try? AmountE4(decimal: rubles.decimal / rate)
  }

  /// What the account is told it received, when it does not hold the money's currency: the
  /// money's `rubles` when its main currency is rubles; otherwise `figure`, «Зачислено на
  /// счёт», when it is in that currency and above zero — nil then, and the write asks for it.
  static func leg(
    for currency: CurrencyCode, rubles: AmountE4, account: PaymentMethod?, figure: MoneyLeg?
  ) -> MoneyLeg? {
    guard let account, let legCurrency = AccountRules.legCurrency(for: currency, account: account)
    else { return nil }
    if legCurrency == .rub { return MoneyLeg(currency: .rub, amount: rubles) }
    guard let figure, figure.currency == legCurrency, figure.amount.raw > 0 else { return nil }
    return figure
  }

  /// The rate money not in rubles is recorded at.
  struct RecordedRate: Equatable {
    var rate: Decimal
    var date: DateOnly
    var source: RateSource
  }

  /// The rate typed — manual, of the money's `day` —, else the bank's, with the date and the
  /// source it has. Nil while the bank's is only a guess (a day not published yet takes the
  /// nearest earlier one): written as the bank's, it would never be refined.
  static func recordedRate(
    of currency: CurrencyCode, typed: Decimal?, rates: RateTable, day: DateOnly
  ) -> RecordedRate? {
    if let typed { return RecordedRate(rate: typed, date: day, source: .manual) }
    guard let resolution = rates.resolve(currency, on: day), !resolution.isProvisional else {
      return nil
    }
    return RecordedRate(
      rate: resolution.rate.perUnit, date: resolution.rate.date, source: resolution.rate.source)
  }

  private func writeOff(_ part: OwedPart) {
    let outcome =
      part.returnedRubE4.raw > 0
      ? Self.writeOffRest(
        of: part, repository: environment.transactions, store: store,
        setting: try? environment.transactions.map(recordingSetting),
        scheduleBackup: environment.scheduleBackup)
      : Self.writeOff(
        part.partId, repository: environment.transactions, store: store,
        scheduleBackup: environment.scheduleBackup)
    switch outcome {
    case .writtenOff: errorText = nil
    case .gone: errorText = t("reimbursement.partGone")
    case .failed: errorText = t("owed.writeOffFailed")
    }
    selected.remove(part.partId)
    reload()
  }

  /// «Save» is on once something is ticked, the money that came back reads as an amount, and
  /// the ticked parts are owed by one person — the one chosen, or with «—» the one they all
  /// name (`ReimbursementRecording.payer`).
  static func canRecord(
    closing parts: [OwedPart], chosen personId: UUID?, received: AmountE4?
  )
    -> Bool
  {
    !parts.isEmpty && received != nil
      && ReimbursementRecording.payer(chosen: personId, closing: parts) != .differentPeople
  }

  /// What became of «Write off».
  enum WriteOffOutcome: Equatable {
    case writtenOff
    /// The part stopped waiting while the sheet was open — closed, written off, its purchase
    /// deleted: nothing was written.
    case gone
    /// The write did not land; the journal has why.
    case failed
  }

  /// Writes a part off. Only a write that landed forgets ⌘Z and asks for a backup: the undo
  /// stack holds whole operations and cannot describe a write-off, so ⌘Z must not look as if
  /// it could — it would silently undo whatever came before instead. A write that did not
  /// land changed nothing, so the history stays and the owner is told. The lists and the
  /// numbers follow through the observation of the database.
  static func writeOff(
    _ partId: UUID, repository: TransactionRepository?, store: TransactionsStore,
    scheduleBackup: () -> Void
  ) -> WriteOffOutcome {
    do {
      guard let repository else { throw WriteOffUnavailable() }
      try repository.writeOffPart(id: partId)
    } catch ReimbursementError.partNoLongerOwed {
      return .gone
    } catch {
      AppLog.error(
        "reimbursement.writeOff", .db, "a part was not written off",
        [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
      return .failed
    }
    store.forgetUndoHistory()
    scheduleBackup()
    return .writtenOff
  }

  /// «Списать остаток»: what is left of a part some money already came back for becomes my
  /// spending — an expense of the rest in rubles in the part's category, from the account the
  /// purchase was paid from — and the part is settled, in one write. Like writing a whole part
  /// off, it cannot be undone step by step, so a write that landed clears ⌘Z.
  static func writeOffRest(
    of part: OwedPart, repository: TransactionRepository?, store: TransactionsStore,
    setting: ReimbursementRecording.Setting?, now: Date = Date(), scheduleBackup: () -> Void
  ) -> WriteOffOutcome {
    do {
      guard let repository else { throw WriteOffUnavailable() }
      let companion = MoneyBack.remainderWriteOff(
        part: part, occurredAt: now, operationId: UUID(),
        tree: setting?.categories ?? CategoryTree(), history: setting?.history ?? .empty, now: now)
      try repository.writeOffRemainder(partId: part.partId, companion: companion, at: now)
    } catch ReimbursementError.partNoLongerOwed {
      return .gone
    } catch {
      AppLog.error(
        "reimb.writeOffRest", .db, "the rest of a part was not written off",
        [LogPair("error", .error(error))])
      return .failed
    }
    store.forgetUndoHistory()
    scheduleBackup()
    return .writtenOff
  }

  /// The database is not open: there is nothing to write the part off in.
  private struct WriteOffUnavailable: Error {}

  private func reload() {
    people = (try? environment.references?.people()) ?? []
    owed = (try? environment.transactions?.owedParts()) ?? []
    accounts = environment.shield.offered((try? environment.references?.paymentMethods()) ?? [])
    rates = (try? environment.rates?.table()) ?? RateTable()
    if accountId == nil { accountId = accounts.first(where: \.isDefault)?.id }
    debts = ((try? environment.references?.debts()) ?? []).filter {
      $0.direction == .owedToMe && !$0.closed
    }
    debtBalances = [:]
    for debt in debts {
      if let journal = try? environment.references?.debtEntries(debtId: debt.id) {
        debtBalances[debt.id] = DebtRules.balance(entries: journal)
      }
    }
    purchases = [:]
    for id in Set(owed.filter { $0.currency != .rub }.map(\.transactionId)) {
      if let entry = try? environment.transactions?.entry(id: id) { purchases[id] = entry }
    }
  }

  private func selectAllOfPerson() {
    selected = Set(filteredOwed.filter { !$0.rateProvisional }.map(\.partId))
    followTheMoney()
  }

  /// Writes the reimbursement, the links and whatever the rules add on top.
  private func record() {
    guard let repository = environment.transactions,
      let amount = amountValue
    else { return }
    let parts = selectedParts

    var terms: RecordedRate?
    if currency != .rub {
      terms = Self.recordedRate(
        of: currency, typed: MoneyBackRateRows.typedRate(typedRate), rates: rates,
        day: environment.calendar.day(of: moment))
      guard terms != nil else {
        errorText = t("reimbursement.moneyRateProvisional")
        return
      }
    }
    do {
      let recordingSetting = try recordingSetting(repository)
      var recording = try ReimbursementRecording.make(
        id: UUID(), received: amount, closing: parts, distribution: distribution,
        personId: personId, occurredAt: prefill?.occurredAt, note: prefill?.note,
        accountId: accountId,
        leg: Self.leg(for: currency, rubles: amount, account: account, figure: legFigure),
        money: currency == .rub ? nil : Money(amount: received, currency: currency),
        rate: terms?.rate, rateDate: terms?.date, rateSource: terms?.source,
        setting: recordingSetting)
      var settling = DebtSettling.none
      // The money over the parts repays the person's debt when the owner left the switch on.
      if surplusToDebt, currency == .rub, let target = surplusDebt,
        let split = try recording.repayingDebt(
          target.debt, balance: target.balance,
          on: environment.calendar.day(of: recording.reimbursement.transaction.occurredAt),
          now: Date(), setting: recordingSetting)
      {
        recording = split.recording
        settling = split.settling
      }
      let write = try repository.apply(
        recording.outcome, reimbursement: recording.reimbursement, extra: recording.extra,
        debt: settling, repricing: repricing,
        settlement: SettlementSetting(surplusNote: t("reimbursement.surplus")),
        calendar: environment.calendar)
      if !write.repricedBefore.isEmpty {
        AppLog.info(
          "moneyBack.repriced", .db, "purchases were written at a rate typed for money back",
          [LogPair("purchases", .count(write.repricedBefore.count))])
      }
      write.settlement.counts.log()
      environment.scheduleBackup()
      // Several operations and the links between them went in at once, in one write: one step
      // of ⌘Z takes all of it back.
      store.recordedMoneyBack(write)
      recorded()
      dismiss()
    } catch ReimbursementError.provisionalRate {
      errorText = t("reimbursement.provisionalRate")
    } catch ReimbursementError.allocationExceedsAmount {
      // Only shares corrected by hand get here: an untouched distribution is left to the core.
      errorText = t("reimbursement.sharesExceedReceived")
    } catch ReimbursementError.allocationExceedsPart {
      errorText = t("reimbursement.shareExceedsPart")
    } catch ReimbursementRecording.Failure.noSurchargesCategory {
      // A database without the system category: the surplus is never written as income
      // with no category. Money that matches the parts, or falls short, still goes in.
      AppLog.error("reimb.noSurcharges", .db, "no Surcharges category for a surplus")
      errorText = t("reimbursement.noSurcharges")
    } catch ReimbursementRecording.Failure.partsOfDifferentPeople {
      errorText = t("reimbursement.differentPeople")
    } catch AccountWriteError.chargeMissing {
      // The account holds neither the money's currency nor rubles, and «Зачислено на счёт»
      // says nothing yet.
      errorText = t("entry.error.chargeMissing")
    } catch ReimbursementError.partNoLongerOwed {
      // Deleted, taken back by ⌘Z, written off or closed while the sheet was open: nothing
      // was written. The list is read again, and what is still ticked is spread again.
      errorText = t("reimbursement.partGone")
      reload()
      selected.formIntersection(pricedOwed.map(\.partId))
      spreadAutomatically()
    } catch {
      AppLog.error(
        "reimbursement.failed", .db, "a reimbursement was not recorded",
        [LogPair("error", .error(error))])
      errorText = t("reimbursement.failed")
    }
  }

  /// The dictionaries and the history a shortfall needs for its category and its quality.
  /// Archived categories are included: the part being closed may sit in one retired since.
  private func recordingSetting(
    _ repository: TransactionRepository
  ) throws
    -> ReimbursementRecording.Setting
  {
    let categories = try environment.references?.categories(includeArchived: true) ?? []
    let history = try repository.manualQualityHistory()
    return ReimbursementRecording.Setting(
      surchargesCategoryId: try environment.references?
        .category(systemRole: .surcharges, kind: .income)?.id,
      categories: CategoryTree(categories),
      history: history,
      surplusNote: t("reimbursement.surplus"),
      shortfallNote: t("reimbursement.shortfall"))
  }
}
