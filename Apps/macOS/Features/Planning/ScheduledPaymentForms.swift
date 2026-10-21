import AppCore
import AppDatabase
import SwiftUI

// The forms of the Planning section, one sheet at a time on the root of the section. A form
// is content: system `Form`, no glass of its own. «Save» writes one `PlanningChange` — one
// step of ⌘Z — and closes the sheet only over a write that landed.

// MARK: - A scheduled payment

struct ScheduledPaymentForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  /// The payment edited — saved over it, with a price edit — or nil for a new one.
  let original: ScheduledPayment?
  /// What the form starts with: `original`, or a new payment filled in from a candidate or
  /// from an account's screen.
  let start: ScheduledPayment?
  /// The currency of `start` is the owner's; false when it only follows the start's account.
  var startCurrencyChosen = true
  /// The payment and the choices of its schedule: «How often» as a preset, «Once», or
  /// «Other…» with the unit and interval shown for editing; the last-day switch; the end and
  /// the trial.
  @State private var draft = ScheduledPaymentDraft(
    opening: ScheduledPayment(name: "", amountE4: .zero))
  @State private var loaded = false
  /// The owner picked the currency: an account chosen after it does not change it.
  @State private var currencyChosen = false

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "form.payment.new" : "form.payment.edit"))
        .appFont(.headline)
      Form {
        TextField(t("form.name"), text: $draft.payment.name)
        Picker(t("form.kind"), selection: $draft.payment.kind) {
          Text(verbatim: t("form.kind.bill")).tag(ScheduledKind.bill)
          Text(verbatim: t("form.kind.subscription")).tag(ScheduledKind.subscription)
        }
        .pickerStyle(.segmented)
        LabeledContent(t("form.amount")) {
          HStack {
            AmountField(amount: $draft.payment.amountE4, locale: environment.language.locale)
            Picker(selection: currencyBinding) {
              ForEach(choices.currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
            } label: {
              EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(
              Text(verbatim: environment.language("entry.currency", table: "Entry")))
          }
        }
        Picker(t("form.category"), selection: $draft.payment.categoryId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.options(.expense)) {
            Text(verbatim: choices.label($0)).tag(Optional($0.id))
          }
        }
        AccountPicker(
          title: t("form.method"), accounts: choices.methods, cards: cards,
          selection: accountBinding)
        if let archived = Self.archivedAccount(
          of: draft.payment, among: compute.snapshot?.dataset.paymentMethods ?? [])
        {
          Label {
            Text(
              verbatim: environment.format(
                "form.accountArchived", table: "Planning", archived.name))
          } icon: {
            Image(systemName: "archivebox")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        Picker(t("form.event"), selection: $draft.payment.eventId) {
          Text(verbatim: t("form.event.none")).tag(UUID?.none)
          ForEach(choices.events(keeping: draft.payment.eventId, today: environment.today)) {
            event in
            Text(verbatim: Self.eventName(event, today: environment.today, environment))
              .tag(Optional(event.id))
          }
        }
        if draft.payment.eventId != nil {
          Text(verbatim: t("form.event.hint"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Picker(t("form.freq"), selection: presetBinding) {
          ForEach(FrequencyPreset.allCases, id: \.self) { preset in
            if preset == .once || preset == .other { Divider() }
            Text(verbatim: t(preset.key)).tag(preset)
          }
        }
        if draft.preset == .other {
          Picker(t("form.unit"), selection: unitBinding) {
            ForEach(Frequency.allCases, id: \.self) {
              Text(verbatim: t("form.unit.\($0.rawValue)")).tag($0)
            }
          }
          .pickerStyle(.segmented)
          Stepper(value: $draft.payment.interval, in: FrequencyPreset.intervals) {
            Text(
              verbatim: FrequencyPreset.everyText(
                draft.payment.freq, interval: draft.payment.interval,
                language: environment.language))
          }
        }
        DatePicker(
          t(draft.preset == .once ? "form.date" : "form.nextDate"),
          selection: nextDateBinding, displayedComponents: .date
        )
        if draft.offersLastDay {
          Toggle(t("form.lastDay"), isOn: lastDayBinding)
        }
        if draft.offersEnd {
          Toggle(
            t("form.hasEnd"),
            isOn: Binding(
              get: { draft.hasEnd }, set: { draft.setHasEnd($0, today: environment.today) }))
          if draft.hasEnd {
            DatePicker(
              t("form.endDate"),
              selection: day($draft.payment.endDate, fallback: environment.today),
              displayedComponents: .date)
          }
        }
        Section {
          Picker(t("form.forWhom"), selection: $draft.payment.forWhom) {
            ForEach(ForWhom.allCases, id: \.self) {
              Text(verbatim: environment.label(for: $0)).tag($0)
            }
          }
          Toggle(t("form.reimbursable"), isOn: $draft.payment.reimbursable)
          if draft.payment.reimbursable {
            Picker(t("form.debtor"), selection: $draft.payment.debtorPersonId) {
              Text(verbatim: "—").tag(UUID?.none)
              ForEach(choices.people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
            }
            LabeledContent(t("form.returns")) {
              HStack {
                AmountField(amount: returnAmountBinding, locale: environment.language.locale)
                  .accessibilityLabel(Text(verbatim: t("form.returns")))
                Picker(selection: returnCurrencyBinding) {
                  ForEach(choices.currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
                } label: {
                  EmptyView()
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text(verbatim: t("form.returns.currency")))
              }
            }
            if Self.shownReturn(
              draft.payment, charge: draft.payment.amountE4, rubPerUnit: rubPerUnit
            )
            .currency != .rub,
              let rubles = Self.returnRubles(
                draft.payment, charge: draft.payment.amountE4, rubPerUnit: rubPerUnit)
            {
              Text(
                verbatim: environment.format(
                  "form.returns.rub", table: "Planning", environment.money.rounded(rubles))
              )
              .appFont(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }
        if draft.payment.kind == .subscription {
          Section {
            Toggle(
              t("form.hasTrial"),
              isOn: Binding(
                get: { draft.hasTrial }, set: { draft.setHasTrial($0, today: environment.today) }))
            if draft.hasTrial {
              DatePicker(
                t("form.trialEnd"),
                selection: day($draft.payment.trialEnd, fallback: environment.today),
                displayedComponents: .date)
            }
            TextField(
              t("form.cancelURL"),
              text: Binding(
                get: { draft.payment.cancelURL ?? "" },
                set: { draft.payment.cancelURL = $0.isEmpty ? nil : $0 }))
          }
        }
        Stepper(
          value: Binding(
            get: { draft.payment.remindDaysBefore ?? 3 },
            set: { draft.payment.remindDaysBefore = $0 }),
          in: 0...30
        ) {
          Text(
            verbatim: environment.language.format(
              "form.remind", table: "Planning", draft.payment.remindDaysBefore ?? 3))
        }
        if let issue = issue(choices) {
          Text(verbatim: t(issue.key)).appFont(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: issue(choices) == nil) {
        guard let dependencies else { return false }
        return PlanningActions(dependencies).save(
          draft.saved(original: original, today: environment.today), previous: original)
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 640)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      var opened =
        start
        ?? Self.newPayment(defaultCurrency: environment.defaultCurrency, today: environment.today)
      if opened.remindDaysBefore == nil { opened.remindDaysBefore = 3 }
      draft = ScheduledPaymentDraft(opening: opened)
      // A payment saved, or one a candidate filled in, has its currency already; one started
      // from an account's screen has the account's, which another account picked moves.
      currencyChosen = start != nil && startCurrencyChosen
    }
  }

  /// Today's rates of the pipeline, rubles for one unit.
  private var rubPerUnit: [CurrencyCode: Decimal] { compute.snapshot?.context.rubPerUnit ?? [:] }

  /// A new payment: in the default currency, on no account — the main one, until one is
  /// picked.
  static func newPayment(defaultCurrency: CurrencyCode, today: DateOnly) -> ScheduledPayment {
    ScheduledPayment(name: "", amountE4: .zero, currency: defaultCurrency, nextDate: today)
  }

  /// The payment once `account` is picked: a currency the owner has not picked follows the
  /// account — its main one — as a new operation's does.
  static func picking(
    _ account: PaymentMethod?, for payment: ScheduledPayment, currencyChosen: Bool,
    defaultCurrency: CurrencyCode
  ) -> ScheduledPayment {
    var payment = payment
    payment.paymentMethodId = account?.id
    if !currencyChosen {
      payment = inCurrency(
        payment,
        AccountRules.currencyForNewOperation(
          typed: nil, chosenAccount: account, default: defaultCurrency))
    }
    return payment
  }

  /// The payment in `currency`. A return typed while it followed the payment's currency stays
  /// in the currency it was typed in — 460 ₽ are not 460 $ once the payment is in dollars; a
  /// return not typed is the whole charge and follows.
  static func inCurrency(_ payment: ScheduledPayment, _ currency: CurrencyCode) -> ScheduledPayment
  {
    var payment = payment
    if payment.reimbursementCurrency == nil, payment.reimbursementAmountE4 != nil,
      currency != payment.currency
    {
      payment.reimbursementCurrency = payment.currency
    }
    payment.currency = currency
    return payment
  }

  /// The account the payment names when it is archived: the payment is paid from — and comes
  /// off — the main account until another is picked, and the form says so.
  static func archivedAccount(
    of payment: ScheduledPayment, among accounts: [PaymentMethod]
  ) -> PaymentMethod? {
    guard let id = payment.paymentMethodId,
      let account = accounts.first(where: { $0.id == id }), account.archived
    else { return nil }
    return account
  }

  /// An event as the picker names it: archived or over, it says it is in the archive.
  static func eventName(_ event: Event, today: DateOnly, _ environment: AppEnvironment) -> String {
    event.archived || event.endDate < today
      ? environment.format("common.archivedName", event.name) : event.name
  }

  /// The account the field shows for a payment on `id`: that account while it is live, else
  /// the main one — the account «Провести» pays from — never an empty field.
  static func shownAccount(_ id: UUID?, among accounts: [PaymentMethod]) -> UUID? {
    FormAccounts.account(id, among: accounts)?.id
  }

  /// What the account field shows for `payment`: its card while the card is live and of the
  /// account shown, else the account (`shownAccount`).
  static func shownChoice(
    _ payment: ScheduledPayment, among accounts: [PaymentMethod], cards: [PaymentCard]
  ) -> UUID? {
    let account = shownAccount(payment.paymentMethodId, among: accounts)
    guard let cardId = payment.cardId,
      cards.contains(where: { $0.id == cardId && !$0.archived && $0.accountId == account })
    else { return account }
    return cardId
  }

  /// The payment once «Возвращает» is put in `currency`: a figure typed is worked out in it at
  /// today's rate, to the cent, and stays editable; without a rate for either currency it stays
  /// as typed. Nothing typed is the whole charge: only the currency changes, and the field
  /// shows the charge in it (`shownReturn`) — no figure is pinned before the amount is known.
  static func returning(
    _ payment: ScheduledPayment, in currency: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> ScheduledPayment {
    var payment = payment
    let from = payment.reimbursementCurrency ?? payment.currency
    payment.reimbursementCurrency = currency
    guard let amount = payment.reimbursementAmountE4, from != currency else { return payment }
    payment.reimbursementAmountE4 =
      converted(amount, from: from, to: currency, rubPerUnit: rubPerUnit) ?? amount
    return payment
  }

  /// What «Возвращает» shows: the figure set on the payment, in its currency; none set — the
  /// whole `charge`, in the currency of the return at today's rate to the cent, or in the
  /// payment's own currency without a rate.
  static func shownReturn(
    _ payment: ScheduledPayment, charge: AmountE4, rubPerUnit: [CurrencyCode: Decimal]
  ) -> Money {
    let currency = payment.reimbursementCurrency ?? payment.currency
    if let amount = payment.reimbursementAmountE4 {
      return Money(amount: amount, currency: currency)
    }
    guard currency != payment.currency else { return Money(amount: charge, currency: currency) }
    guard
      let inReturn = converted(charge, from: payment.currency, to: currency, rubPerUnit: rubPerUnit)
    else { return Money(amount: charge, currency: payment.currency) }
    return Money(amount: inReturn, currency: currency)
  }

  /// What the person gives back in rubles at today's rate — «≈ 920 ₽» under «Возвращает 10 $»,
  /// on the card as in the form: the figure set, or the whole `charge` when none is set; not
  /// held to the charge, since this is what comes back. `nil` without a rate or for a payment
  /// nobody gives back.
  static func returnRubles(
    _ payment: ScheduledPayment, charge: AmountE4, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    guard payment.reimbursable else { return nil }
    let amount = payment.reimbursementAmountE4 ?? charge
    let currency =
      payment.reimbursementAmountE4 == nil
      ? payment.currency : (payment.reimbursementCurrency ?? payment.currency)
    guard currency != .rub else { return amount }
    guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
    return try? AmountE4(decimal: amount.decimal * rate)
  }

  /// `amount` of `from` in `to` through the rubles of today's rates, to the cent; `nil` without
  /// a rate for either.
  private static func converted(
    _ amount: AmountE4, from: CurrencyCode, to: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    func perUnit(_ code: CurrencyCode) -> Decimal? {
      code == .rub ? 1 : rubPerUnit[code].flatMap { $0 > 0 ? $0 : nil }
    }
    guard let fromRate = perUnit(from), let toRate = perUnit(to) else { return nil }
    return try? AmountE4(decimal: DecimalMath.round(amount.decimal * fromRate / toRate, scale: 2))
  }

  private var currencyBinding: Binding<CurrencyCode> {
    Binding(
      get: { draft.payment.currency },
      set: {
        draft.payment = Self.inCurrency(draft.payment, $0)
        currencyChosen = true
      })
  }

  /// «Возвращает»: what `shownReturn` gives; a figure typed is set in the currency shown, and
  /// the field writing back the figure it shows sets nothing.
  private var returnAmountBinding: Binding<AmountE4> {
    Binding(
      get: {
        Self.shownReturn(draft.payment, charge: draft.payment.amountE4, rubPerUnit: rubPerUnit)
          .amount
      },
      set: { typed in
        let shown = Self.shownReturn(
          draft.payment, charge: draft.payment.amountE4, rubPerUnit: rubPerUnit)
        guard typed != shown.amount else { return }
        draft.payment.reimbursementAmountE4 = typed
        draft.payment.reimbursementCurrency = shown.currency
      })
  }

  private var returnCurrencyBinding: Binding<CurrencyCode> {
    Binding(
      get: { draft.payment.reimbursementCurrency ?? draft.payment.currency },
      set: { draft.payment = Self.returning(draft.payment, in: $0, rubPerUnit: rubPerUnit) })
  }

  /// Every card: the picker offers the live ones under their accounts.
  private var cards: [PaymentCard] { compute.snapshot?.dataset.cards ?? [] }

  /// A payment on no account, or on an archived one, shows the main one, which is the account it
  /// is paid from; only a pick writes an account. A live card it names is shown; picking a card
  /// picks its account, picking an account drops the card.
  private var accountBinding: Binding<UUID?> {
    Binding(
      get: {
        Self.shownChoice(
          draft.payment, among: PlanningChoices(compute, environment).methods, cards: cards)
      },
      set: { id in
        draft.payment = Self.choosing(
          id, for: draft.payment, methods: PlanningChoices(compute, environment).methods,
          cards: cards, currencyChosen: currencyChosen,
          defaultCurrency: environment.defaultCurrency)
      })
  }

  /// The payment once the account row's `selection` is picked — the id of an account or of a
  /// card among `methods` and `cards`: a card brings its account and is written; an account
  /// drops the card; no pick leaves neither. The currency follows the account as `picking`
  /// says.
  static func choosing(
    _ selection: UUID?, for payment: ScheduledPayment, methods: [PaymentMethod],
    cards: [PaymentCard], currencyChosen: Bool, defaultCurrency: CurrencyCode
  ) -> ScheduledPayment {
    let resolved = CardRules.resolve(selection: selection, cards: cards)
    let account = methods.first { $0.id == resolved.accountId }
    var payment = picking(
      account, for: payment, currencyChosen: currencyChosen, defaultCurrency: defaultCurrency)
    payment.cardId = account == nil ? nil : resolved.cardId
    return payment
  }

  private var presetBinding: Binding<FrequencyPreset> {
    Binding(get: { draft.preset }, set: { draft.choose($0, today: environment.today) })
  }

  private var unitBinding: Binding<Frequency> {
    Binding(get: { draft.payment.freq }, set: { draft.setUnit($0, today: environment.today) })
  }

  private var lastDayBinding: Binding<Bool> {
    Binding(get: { draft.lastDay }, set: { draft.setLastDay($0, today: environment.today) })
  }

  private var nextDateBinding: Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(draft.payment.nextDate ?? environment.today) },
      set: { draft.setNextDate(environment.calendar.day(of: $0), today: environment.today) })
  }

  private func issue(_ choices: PlanningChoices) -> ScheduledIssue? {
    guard let tree = choices.tree else { return nil }
    return draft.issue(original: original, tree: tree, today: environment.today)
  }

  private func day(_ value: Binding<DateOnly?>, fallback: DateOnly) -> Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(value.wrappedValue ?? fallback) },
      set: { value.wrappedValue = environment.calendar.day(of: $0) })
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

// MARK: - Mark as paid

struct MarkAsPaidForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let status: ScheduledStatus
  @State private var amount: AmountE4 = .zero
  @State private var date = Date()
  @State private var method: UUID?
  @State private var updatePrice = false
  /// Read as typed, like the rate field of the ↓ panel: a value field would take it only on
  /// Return, and «Провести» would save the one before.
  @State private var rateText = ""
  @State private var needsRate = false
  @State private var loaded = false
  /// «Списано со счёта» as the field shows it, and whether the owner typed it from the
  /// statement — a typed figure is kept, a prefill follows the amount, the day and the rate.
  @State private var charge = FormCharge()
  /// The bank's rates, read once when the form opens.
  @State private var rates = RateTable()

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    let payment = status.payment
    VStack(alignment: .leading) {
      Text(verbatim: environment.format("form.markAsPaid.title", table: "Planning", payment.name))
        .appFont(.headline)
      Text(
        verbatim: environment.format(
          "form.markAsPaid.due", table: "Planning",
          environment.dates.longDay(status.nextDue))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
      Form {
        LabeledContent(t("form.amount")) {
          HStack {
            AmountField(amount: $amount, locale: environment.language.locale)
            Text(verbatim: payment.currency.code).foregroundStyle(.secondary)
          }
        }
        DatePicker(t("form.date"), selection: $date)
        if needsRate {
          // No rate of the bank for this currency and day: one typed by hand, as in the
          // entry line.
          LabeledContent(
            environment.format("form.rate", table: "Planning", payment.currency.code)
          ) {
            RateTextField(
              title: environment.format("form.rate", table: "Planning", payment.currency.code),
              text: $rateText)
          }
        }
        AccountPicker(
          title: environment.language("entry.account.from", table: "Entry"),
          accounts: choices.methods, cards: cards, selection: $method)
        ChargeRow(charge: $charge)
        if payment.kind == .subscription, amount != status.amountNext {
          Toggle(t("form.updatePrice"), isOn: $updatePrice)
        }
        if payment.reimbursable {
          let back = ScheduledPaymentForm.shownReturn(
            payment, charge: amount, rubPerUnit: compute.snapshot?.context.rubPerUnit ?? [:])
          Text(
            verbatim: environment.format(
              "form.markAsPaid.forOther", table: "Planning",
              choices.people.first { $0.id == payment.debtorPersonId }?.name ?? "—",
              environment.money.exact(back.amount, currency: back.currency))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      CountingFormButtons(
        title: t("scheduled.markAsPaid"),
        enabled: Self.canPay(
          amount: amount, needsRate: needsRate, rate: rate, charged: charge.typedFigure,
          chargeComplete: charge.isComplete),
        failure: { failure(payment.currency) },
        ask: { question(payment) }, moment: { date }, name: payment.name
      ) { moment in
        guard let dependencies else { return false }
        return PlanningActions(dependencies).markAsPaid(
          payment, due: status.nextDue, amount: amount, on: moment ?? date, account: account,
          charged: charge.typedFigure, updatePrice: updatePrice, rate: needsRate ? rate : nil,
          card: .chosen(card))
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 460)
    // Read once per day chosen, not on every keystroke: it asks the cache of rates.
    .onChange(of: date, initial: true) {
      needsRate = !environment.knowsRate(status.payment.currency, on: date)
    }
    .onChange(of: ChargeInputs(amount: amount, date: date, account: account, rate: rateText)) {
      refreshCharge()
    }
    .onAppear {
      guard !loaded else { return }
      loaded = true
      rates = (try? environment.rates?.table()) ?? RateTable()
      amount = status.amountNext
      method = Self.startingChoice(payment, among: choices.methods, cards: cards)
      date = PlanningActions.paidAt(
        due: status.nextDue, today: environment.today, calendar: environment.calendar)
      refreshCharge()
    }
  }

  /// Every card: the picker offers the live ones under their accounts.
  private var cards: [PaymentCard] { compute.snapshot?.dataset.cards ?? [] }

  /// The account the operation goes on: the one picked, or the account of the card picked.
  private var account: UUID? { CardRules.resolve(selection: method, cards: cards).accountId }

  /// The card picked, if any.
  private var card: UUID? { CardRules.resolve(selection: method, cards: cards).cardId }

  /// What the account field of «Провести» starts on: the payment's card while it is live and of
  /// the account the payment is paid from, else that account — the main one when its own is
  /// gone or archived. A card in the archive is left off: the account pays alone.
  static func startingChoice(
    _ payment: ScheduledPayment, among accounts: [PaymentMethod], cards: [PaymentCard]
  ) -> UUID? {
    ScheduledPaymentForm.shownChoice(payment, among: accounts, cards: cards)
  }

  /// Whether «Провести» can write: an amount, «Списано со счёта» when the account needs it, and
  /// the rubles — the bank's rate, one typed by hand, or a ruble figure typed from the
  /// statement, which is the operation's rubles and gives the rate itself.
  static func canPay(
    amount: AmountE4, needsRate: Bool, rate: Decimal?, charged: Money?, chargeComplete: Bool
  ) -> Bool {
    amount.raw > 0 && chargeComplete && (!needsRate || rate != nil || charged?.currency == .rub)
  }

  /// The rate typed by hand: a positive number, with a comma or a point, or a formula that
  /// comes to one (`RateText`).
  private var rate: Decimal? {
    RateText.rate(rateText)
  }

  private func refreshCharge() {
    let accounts = PlanningChoices(compute, environment).methods
    charge.refresh(
      FormAccounts.charge(
        amount: amount, currency: status.payment.currency, at: date,
        rate: needsRate ? rate : nil, account: FormAccounts.account(account, among: accounts),
        table: rates, calendar: environment.calendar))
  }

  /// What «Провести» asks before it writes: about a later count when the chosen moment lies
  /// before it and the due is earlier than its day, else about the counts of the operation's
  /// own day — the operation it would write, saved now.
  private func question(_ payment: ScheduledPayment) -> DueCountAsk {
    guard let dependencies,
      let entry = try? PlanningActions(dependencies).markAsPaidEntry(
        payment, due: status.nextDue, amount: amount, on: date, account: account,
        charged: charge.typedFigure, updatePrice: updatePrice, rate: needsRate ? rate : nil,
        card: .chosen(card)
      ).entry
    else { return .none }
    return FormAccounts.dueQuestion(
      about: entry, due: status.nextDue, savedAt: Date(), snapshot: compute.snapshot,
      calendar: environment.calendar, remembered: environment.rememberedCountAnswers())
  }

  private func failure(_ currency: CurrencyCode) -> String {
    // A rate typed by hand was there: whatever failed, it was not the rate.
    guard let dependencies, !(needsRate && rate != nil) else { return "" }
    return environment.format(
      PlanningActions(dependencies).failureKey(currency: currency, on: date), table: "Planning",
      currency.code)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// What «Списано со счёта» of a form is worked out from: a change of any of them works it out
/// again.
private struct ChargeInputs: Equatable {
  var amount: AmountE4
  var date: Date
  var account: UUID?
  var rate: String
}

// MARK: - «Провести» on an account

/// The card «Провести» writes: the payment's own while it is live and of the account paid from
/// (a reminder's «Провести»), or the one picked in the form — none for the account alone.
enum MarkAsPaidCard: Equatable {
  case payments
  case chosen(UUID?)
}

extension PlanningActions {
  /// The operation «Провести» writes for `due` of `payment`, with the plan it comes from: on
  /// `account` — the one chosen while it is live, else the main account — and, when that
  /// account does not hold the payment's currency, what it was charged: `charged` when the
  /// owner typed it from the statement, else the prefill at the rate the operation is saved
  /// with (`FormAccounts.lay`).
  func markAsPaidEntry(
    _ payment: ScheduledPayment, due: DateOnly, amount: AmountE4, on day: Date, account: UUID?,
    charged: Money?, updatePrice: Bool, rate: Decimal?, card: MarkAsPaidCard = .payments
  ) throws -> (entry: TransactionEntry, plan: MarkAsPaidPlan) {
    let history = ManualQualityHistory(
      entries: (try? environment.transactions?.entriesRatedByHand()) ?? [])
    let plan = try ScheduledRules.markAsPaid(
      payment, due: due, amount: amount, occurredAt: day, paidAt: rate,
      rubPerUnit: snapshot?.context.rubPerUnit ?? [:], updatePrice: updatePrice,
      prices: snapshot?.dataset.planning.prices ?? [], categories: tree ?? CategoryTree(),
      history: history, eventId: event(of: payment, due: due),
      cards: snapshot?.dataset.cards ?? [])
    var draft = plan.draft
    // A rate by hand is the rate of the day it was typed for, like one in the entry line.
    if draft.rateSource == .manual { draft.rateDate = environment.calendar.day(of: day) }
    try FormAccounts.lay(on: &draft, account: account, charged: charged, actions: self)
    if case .chosen(let chosen) = card { draft.cardId = chosen }
    // The payment's card goes with its own account only: paid from another, it is left off.
    if let card = draft.cardId,
      snapshot?.dataset.cards.first(where: { $0.id == card })?.accountId != draft.paymentMethodId
    {
      draft.cardId = nil
    }
    // Without any rate the ruble figure gives one (`materialize`): the rate of this day.
    if draft.currency != .rub, draft.rate == nil, draft.accountCurrency == .rub {
      draft.rateDate = environment.calendar.day(of: day)
    }
    let entry = try operation(draft, link: .scheduled(paymentId: payment.id, due: due))
    return (entry, plan)
  }

  /// The count «Провести» without a form — a reminder's — asks «Это было до сверки в 14:05?»
  /// about: the operation it writes on the payment's account at `moment`, dated on the day of
  /// the latest count of the balance it moves and saved after that count. `nil` when nothing
  /// asks.
  func countToAsk(
    paying payment: ScheduledPayment, due: DateOnly, amount: AmountE4, on moment: Date,
    savedAt: Date = Date()
  ) -> Date? {
    guard
      let entry = try? markAsPaidEntry(
        payment, due: due, amount: amount, on: moment, account: payment.paymentMethodId,
        charged: nil, updatePrice: false, rate: nil
      ).entry
    else { return nil }
    return FormAccounts.countToAsk(
      about: entry, savedAt: savedAt, snapshot: snapshot, calendar: environment.calendar)
  }

  /// «Провести» on an account: the operation of `markAsPaidEntry`, the payment moved past
  /// `due`, a new price when asked, and the ordinary operations that paid the dates before
  /// `due` keyed to them — one write, one step of ⌘Z.
  @discardableResult
  func markAsPaid(
    _ payment: ScheduledPayment, due: DateOnly, amount: AmountE4, on day: Date, account: UUID?,
    charged: Money?, updatePrice: Bool, rate: Decimal? = nil, card: MarkAsPaidCard = .payments
  ) -> Bool {
    guard
      let made = try? markAsPaidEntry(
        payment, due: due, amount: amount, on: day, account: account, charged: charged,
        updatePrice: updatePrice, rate: rate, card: card)
    else { return false }
    var rows = PlanningRows.empty
    rows.scheduled = [made.plan.payment]
    if let price = made.plan.newPrice { rows.prices = [price] }
    return apply(
      PlanningChange(
        created: [made.entry], upsert: rows,
        rewritten: keyedMatches(of: payment, before: due)))
  }

  /// The ordinary operations that pay the due dates of `payment` from its `next_date` up to
  /// `due` by matching them, each keyed to its due date — as «Привязать» would — in the write
  /// that moves the payment past `due`: once `next_date` is past them nothing matches them any
  /// more, and unkeyed, what they paid would drop out of the month's funding.
  private func keyedMatches(
    of payment: ScheduledPayment, before due: DateOnly
  ) -> [TransactionEntry] {
    guard let snapshot, let next = payment.nextDate else { return [] }
    let matches = snapshot.planning.matches
    return matches.matchedDues(of: payment.id).keys
      .filter { $0 >= next && $0 < due }
      .sorted()
      .compactMap { earlier in
        guard let operationId = matches.operation(for: payment.id, earlier),
          let entry = snapshot.ledger.entry(operationId)
        else { return nil }
        return ScheduledMatching.bind(
          entry, to: payment, due: earlier, eventId: event(of: payment, due: earlier)
        ).operation
      }
  }
}

// MARK: - The account a form writes on

/// Why a form's operation was not made.
enum FormChargeError: Error, Equatable {
  /// The account does not hold the currency, and no rate gives «Списано со счёта»: the owner
  /// types it.
  case chargeMissing
}

/// «Списано со счёта» of an operation a form of Planning or Debts writes: what it needs, what
/// the field shows and what it keeps once the owner typed it from the statement — as the ↓
/// panel does: a typed figure stays while the account is charged in the same currency, and
/// once the amount, the currency, the day or the account it was typed for changes it says it
/// was not worked out again.
struct FormCharge: Equatable {
  /// The currency the account is charged in; `nil` when it holds the operation's currency and
  /// nothing is charged apart.
  private(set) var currency: CurrencyCode?
  /// The figure the field shows: the prefill or the one typed; `nil` while nothing gives it.
  private(set) var amount: AmountE4?
  /// The owner typed the figure: it stays while the account is charged in the same currency.
  private(set) var typed = false
  /// The figure shown rests on a rate the bank has not published for the day yet.
  private(set) var provisional = false
  /// What the rates give now, which zero in the field brings back at once.
  private var latest: FormAccounts.Charge?
  /// What the typed figure was typed for.
  private var typedFor: FormAccounts.Basis?

  /// Something the save can write: nothing is charged apart, or there is a figure.
  var isComplete: Bool { currency == nil || amount != nil }

  /// A typed figure kept for another amount, currency, day or account than the operation has
  /// now: «Списано со счёта не пересчитано — проверьте».
  var needsCheck: Bool { typed && typedFor != latest?.basis }

  /// The figure the owner typed, for the save; a prefill is worked out again there, at the
  /// rate the operation is saved with.
  var typedFigure: Money? {
    guard typed, let currency, let amount else { return nil }
    return Money(amount: amount, currency: currency)
  }

  /// Takes what the rates give now: a typed figure in the same currency stays, anything else
  /// follows.
  mutating func refresh(_ charge: FormAccounts.Charge?) {
    guard let charge else {
      self = FormCharge()
      return
    }
    latest = charge
    if typed, currency == charge.currency { return }
    follow(charge)
  }

  /// The owner typed `figure`; zero gives the field back to the prefill at once.
  mutating func type(_ figure: AmountE4) {
    guard currency != nil, figure != amount else { return }
    guard !figure.isZero else {
      if let latest { follow(latest) } else { amount = nil }
      return
    }
    amount = figure
    typed = true
    typedFor = latest?.basis
    provisional = false
  }

  private mutating func follow(_ charge: FormAccounts.Charge) {
    currency = charge.currency
    amount = charge.amount
    typed = false
    typedFor = nil
    provisional = charge.provisional && charge.amount != nil
  }
}

/// The accounts a form of Planning or Debts offers, the one its operation is written on, what
/// that account was charged, and the question «Это было до сверки в 14:05?» before the write.
@MainActor
enum FormAccounts {
  /// «Списано со счёта» an operation needs: its currency and, when a rate gives it, the figure;
  /// whether that figure rests on a rate still to come; and what it was worked out for.
  struct Charge: Equatable {
    var currency: CurrencyCode
    var amount: AmountE4?
    var provisional = false
    var basis: Basis?
  }

  /// What a figure of «Списано со счёта» is worked out for: a typed one is checked once any of
  /// it changes.
  struct Basis: Equatable {
    var amount: AmountE4
    var currency: CurrencyCode
    var day: DateOnly
    var account: UUID?
  }

  /// The accounts offered: the live ones in the order of every menu, the main one first.
  static func offered(_ accounts: [PaymentMethod], locale: Locale) -> [PaymentMethod] {
    AccountRules.ordered(accounts, locale: locale)
  }

  /// The account an operation is written on: the one chosen while it is live, else the main
  /// account — every operation has one.
  static func account(_ chosen: UUID?, among accounts: [PaymentMethod]) -> PaymentMethod? {
    let live = accounts.filter { !$0.archived }
    return live.first { $0.id == chosen } ?? live.first(where: \.isDefault)
  }

  /// What `account` is charged for `amount` in `currency` at `moment`: `nil` when it holds the
  /// currency; otherwise its main currency and the prefill from the bank's rates
  /// (`AccountRules.prefillLeg`) — in rubles at the rate the operation is saved with (`rate`
  /// when one is typed by hand), so an untouched prefill changes no ruble figure; the figure
  /// is `nil` when no rate gives it and has to be typed.
  static func charge(
    amount: AmountE4, currency: CurrencyCode, at moment: Date, rate: Decimal?,
    account: PaymentMethod?, table: RateTable, calendar: CalendarContext
  ) -> Charge? {
    guard let account, let leg = AccountRules.legCurrency(for: currency, account: account)
    else { return nil }
    var draft = TransactionDraft(occurredAt: moment, currency: currency, amount: amount)
    if let rate {
      draft.rate = rate
      draft.rateSource = .manual
    }
    AppEnvironment.applyRate(to: &draft, from: table, calendar: calendar)
    let day = calendar.day(of: moment)
    let figure = AccountRules.prefillLeg(
      amount: amount, currency: currency, rate: draft.rate, day: day, account: account,
      rates: dayRates(table))
    // Either rate the figure goes through may be a guess the bank will refine: the operation's
    // own, or the one of the account's currency.
    let ownIsProvisional = currency != .rub && draft.rateProvisional
    let legIsProvisional = leg != .rub && (table.resolve(leg, on: day)?.isProvisional ?? true)
    return Charge(
      currency: leg, amount: figure,
      provisional: figure != nil && (ownIsProvisional || legIsProvisional),
      basis: Basis(amount: amount, currency: currency, day: day, account: account.id))
  }

  /// Lays the account on `draft` — the one chosen while live, else the main one — and «Списано
  /// со счёта» when that account does not hold the draft's currency: `charged` when typed in
  /// that currency, else the prefill at the rate the save lays. Throws `chargeMissing` when
  /// nothing gives the figure. The accounts are read from the database, the screen's when
  /// there is none.
  static func lay(
    on draft: inout TransactionDraft, account chosen: UUID?, charged: Money?,
    actions: PlanningActions
  ) throws {
    let environment = actions.environment
    let accounts =
      (try? environment.references?.paymentMethods(includeArchived: true))
      ?? actions.snapshot?.dataset.paymentMethods ?? []
    guard let account = account(chosen, among: accounts) else {
      draft.paymentMethodId = chosen
      return
    }
    draft.paymentMethodId = account.id
    draft.accountCurrency = nil
    draft.accountAmount = nil
    guard let leg = AccountRules.legCurrency(for: draft.currency, account: account) else {
      return
    }
    if let charged, charged.currency == leg, charged.amount.raw > 0 {
      draft.accountCurrency = leg
      draft.accountAmount = charged.amount
      return
    }
    let table = (try? environment.rates?.table()) ?? RateTable()
    var rated = draft
    AppEnvironment.applyRate(to: &rated, from: table, calendar: environment.calendar)
    guard
      let figure = AccountRules.prefillLeg(
        amount: draft.amount, currency: draft.currency, rate: rated.rate,
        day: environment.calendar.day(of: draft.occurredAt), account: account,
        rates: dayRates(table))
    else { throw FormChargeError.chargeMissing }
    draft.accountCurrency = leg
    draft.accountAmount = figure
  }

  /// The bank's rates by day, for one unit.
  static func dayRates(_ table: RateTable) -> DayRates {
    var series: [CurrencyCode: [DayRate]] = [:]
    for rate in table.rates {
      series[rate.currency, default: []].append(DayRate(day: rate.date, perUnit: rate.perUnit))
    }
    return DayRates(series: series)
  }

  /// The count to ask «Это было до сверки в 14:05?» about before `entry` is written at
  /// `savedAt`: it is dated on the day of the latest count of a balance it moves and saved
  /// after that count. `nil` when nothing asks.
  static func countToAsk(
    about entry: TransactionEntry, savedAt: Date, snapshot: DataSnapshot?,
    calendar: CalendarContext
  ) -> Date? {
    guard let snapshot else { return nil }
    let keys = AccountReconciliation.movedKeys(
      of: entry, mainId: mainId(snapshot), tree: snapshot.ledger.tree)
    return AccountReconciliation.beforeTheCount(
      occurredAt: entry.transaction.occurredAt, savedAt: savedAt, keys: keys,
      balances: snapshot.planning.accounts.balances, calendar: calendar)
  }

  /// The same for a line of a debt journal that moves money by itself (money borrowed or lent
  /// through the journal).
  static func countToAsk(
    about line: DebtEntry, of debt: Debt, savedAt: Date, snapshot: DataSnapshot?,
    calendar: CalendarContext
  ) -> Date? {
    guard let snapshot, let moment = line.occurredAt else { return nil }
    let keys = AccountReconciliation.movedKeys(
      of: line, debt: debt, mainId: mainId(snapshot), calendar: calendar)
    return AccountReconciliation.beforeTheCount(
      occurredAt: moment, savedAt: savedAt, keys: keys,
      balances: snapshot.planning.accounts.balances, calendar: calendar)
  }

  /// What saving `entry` at `savedAt` asks about the counts of its day: every count of a
  /// balance it moves made that day before it was saved, oldest first, the answers remembered
  /// for their reconciliations applied (`AccountReconciliation.countToAsk`).
  static func countAsk(
    about entry: TransactionEntry, savedAt: Date, snapshot: DataSnapshot?,
    calendar: CalendarContext, remembered: [UUID: Bool]
  ) -> CountAsk {
    guard let snapshot else { return .none }
    let keys = AccountReconciliation.movedKeys(
      of: entry, mainId: mainId(snapshot), tree: snapshot.ledger.tree)
    return AccountReconciliation.countToAsk(
      occurredAt: entry.transaction.occurredAt, savedAt: savedAt, keys: keys,
      balances: snapshot.planning.accounts.balances, calendar: calendar, remembered: remembered)
  }

  /// The same for a line of a debt journal that moves money by itself.
  static func countAsk(
    about line: DebtEntry, of debt: Debt, savedAt: Date, snapshot: DataSnapshot?,
    calendar: CalendarContext, remembered: [UUID: Bool]
  ) -> CountAsk {
    guard let snapshot, let moment = line.occurredAt else { return .none }
    let keys = AccountReconciliation.movedKeys(
      of: line, debt: debt, mainId: mainId(snapshot), calendar: calendar)
    return AccountReconciliation.countToAsk(
      occurredAt: moment, savedAt: savedAt, keys: keys,
      balances: snapshot.planning.accounts.balances, calendar: calendar, remembered: remembered)
  }

  /// What paying `due` with `entry` asks: «Деньги за «X» ушли до сверки …?» when the
  /// operation's moment lies before a later count of a balance it moves (the due on an earlier
  /// day), else the questions of its own day (`countAsk`).
  static func dueQuestion(
    about entry: TransactionEntry, due: DateOnly, savedAt: Date, snapshot: DataSnapshot?,
    calendar: CalendarContext, remembered: [UUID: Bool]
  ) -> DueCountAsk {
    guard let snapshot else { return .none }
    let keys = AccountReconciliation.movedKeys(
      of: entry, mainId: mainId(snapshot), tree: snapshot.ledger.tree)
    return AccountReconciliation.dueQuestion(
      due: due, occurredAt: entry.transaction.occurredAt, savedAt: savedAt, keys: keys,
      balances: snapshot.planning.accounts.balances, calendar: calendar, remembered: remembered)
  }

  /// The moment the answer dates the operation with: «Да» — a second before the count, unless
  /// it is dated before it already; «Нет» — after the count. Neither leaves the day of the
  /// count in the owner's `calendar`: the day decides the month the money is spent in.
  static func stamped(
    _ moment: Date, _ answer: (count: Date, wasBefore: Bool), calendar: CalendarContext
  ) -> Date {
    let stamped = AccountReconciliation.stamped(
      occurredAt: moment, count: answer.count, wasBefore: answer.wasBefore, calendar: calendar)
    return answer.wasBefore ? min(moment, stamped) : stamped
  }

  private static func mainId(_ snapshot: DataSnapshot) -> UUID? {
    snapshot.dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
  }
}

/// The account picker of a form: the live accounts, the main one first; «—» only while there
/// is no account at all.
struct AccountPicker: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let title: String
  let accounts: [PaymentMethod]
  /// The cards offered under their accounts, «Т-Банк › Black»; none — the accounts alone.
  var cards: [PaymentCard] = []
  @Binding var selection: UUID?

  var body: some View {
    let locale = environment.language.locale
    // The banks name the accounts as every list does: a bank with one account is told by its name.
    let offered = AccountCardChoices.items(
      accounts: FormAccounts.offered(accounts, locale: locale), cards: cards,
      banks: compute.snapshot?.dataset.banks ?? [], among: accounts, locale: locale)
    Picker(title, selection: $selection) {
      if offered.isEmpty || !offered.contains(where: { $0.id == selection }) {
        Text(verbatim: "—").tag(UUID?.none)
      }
      ForEach(offered) { Text(verbatim: $0.name).tag(Optional($0.id)) }
    }
  }
}

/// «Списано со счёта» under the account of a form, while the account does not hold the
/// currency: the figure, editable from the statement, in the currency the account is charged
/// in. Like the field of the ↓ panel it says in words and with a symbol when the prefill rests
/// on a rate still to come, when a typed figure was typed for another amount, day or account,
/// and when there is no rate and the figure has to be typed.
struct ChargeRow: View {
  @Dependency(\.environment) private var environment
  @Binding var charge: FormCharge

  var body: some View {
    if let currency = charge.currency {
      LabeledContent(t("entry.accountCharge")) {
        HStack {
          AmountField(
            amount: Binding(get: { charge.amount ?? .zero }, set: { charge.type($0) }),
            locale: environment.language.locale
          )
          .accessibilityLabel(Text(verbatim: t("entry.accountCharge")))
          Text(verbatim: currency.code).foregroundStyle(.secondary)
        }
      }
      if charge.provisional {
        note("entry.accountCharge.provisional", symbol: "hourglass")
          .help(t("entry.accountCharge.provisionalHelp"))
      }
      if charge.needsCheck {
        note("entry.accountCharge.check", symbol: "exclamationmark.triangle")
      }
      if charge.amount == nil {
        note("entry.error.chargeMissing", symbol: "exclamationmark.triangle")
      }
    }
  }

  private func note(_ key: String, symbol: String) -> some View {
    Label {
      Text(verbatim: t(key))
    } icon: {
      Image(systemName: symbol)
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }
}

/// «Cancel» and the main action of a form that writes money on an account. Before the write it
/// asks «Это было до сверки в 14:05?» when the operation is dated on the day of the latest
/// count of a balance it moves and saved after that count, or «Деньги за «X» ушли до сверки
/// …?» when a due of an earlier day is paid before a later count; the answer goes to `save`,
/// which dates the operation by it. The sheet closes only over a write that landed.
struct CountingFormButtons: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  let title: String
  let enabled: Bool
  let failure: () -> String
  /// What the save asks before it writes (`FormAccounts.dueQuestion`).
  let ask: () -> DueCountAsk
  /// The moment the form would write at: «Да» of the dated question keeps it while it is
  /// before the count.
  let moment: () -> Date
  /// The payment or debt the dated question names.
  let name: String?
  /// Writes at the moment the answers give; `nil` — at the form's own.
  let save: (_ at: Date?) -> Bool
  /// «Это было до сверки в 14:05?» about every count of the day, in turn.
  @State private var question: BeforeTheCountQuestion?
  /// «Деньги за «X» ушли до сверки …?».
  @State private var dated: BeforeTheCountQuestion?
  @State private var failed: String?

  init(
    title: String, enabled: Bool, failure: @escaping () -> String,
    ask: @escaping () -> DueCountAsk, moment: @escaping () -> Date, name: String? = nil,
    save: @escaping (_ at: Date?) -> Bool
  ) {
    self.title = title
    self.enabled = enabled
    self.failure = failure
    self.ask = ask
    self.moment = moment
    self.name = name
    self.save = save
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if let failed {
        Text(verbatim: failed)
          .appFont(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(title) {
          switch ask() {
          case .none, .sameDay(.none):
            finish(nil)
          case .sameDay(.answered(let stamp)):
            finish(stamp)
          case .sameDay(.ask(let questions)):
            question = BeforeTheCountQuestion(
              count: questions.count, reconciliation: questions.reconciliation,
              questions: questions)
          case .dueBefore(let count, let due, let reconciliation):
            dated = BeforeTheCountQuestion(
              count: count, reconciliation: reconciliation, due: due, name: name)
          case .dueAnswered(let stamp):
            // Answered for this count's reconciliation already: saved at that moment, unasked.
            finish(stamp)
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!enabled)
      }
      // One dialog per view: the dated question hangs on the row of buttons.
      .beforeTheCountQuestion($dated) { count, wasBefore in
        finish(
          AccountReconciliation.dueAnswer(
            count: count, occurredAt: moment(), wasBefore: wasBefore, now: Date()))
      }
    }
    .padding(.top, 8)
    .beforeTheCountQuestions($question) { finish($0) }
  }

  private func finish(_ moment: Date?) {
    if save(moment) {
      dismiss()
    } else {
      let reason = failure()
      failed = reason.isEmpty ? environment.language("form.notSaved", table: "Planning") : reason
    }
  }
}
