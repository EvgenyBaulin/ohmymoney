import AppCore
import SwiftUI

// The forms of the Planning section, one sheet at a time on the root of the section. A form
// is content: system `Form`, no glass of its own. «Save» writes one `PlanningChange` — one
// step of ⌘Z — and closes the sheet only over a write that landed.

// MARK: - Expected income

struct ExpectedIncomeForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let original: ExpectedIncome?
  @State private var income = ExpectedIncome(name: "", totalE4: .zero)
  @State private var loaded = false
  /// «On the last day of the month» of a recurring income; read off the stored day.
  @State private var lastDay = false
  /// The other days of the month the income comes on (`ExpectedIncome.terms`), of a new income.
  @State private var extraTerms: [IncomeTerm] = []

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "form.expected.new" : "form.expected.edit")).appFont(
        .headline)
      Form {
        TextField(t("form.name"), text: $income.name)
        Picker(t("form.kind"), selection: $income.kind) {
          Text(verbatim: t("form.expected.oneOff")).tag(ExpectedIncomeKind.oneOff)
          Text(verbatim: t("form.expected.recurring")).tag(ExpectedIncomeKind.recurring)
        }
        .pickerStyle(.segmented)
        .onChange(of: income.kind) { followTheLastDay() }
        LabeledContent(t(income.kind == .oneOff ? "form.expected.total" : "form.expected.each")) {
          HStack {
            AmountField(amount: $income.totalE4, locale: environment.language.locale)
            Picker(selection: $income.currency) {
              ForEach(choices.currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
            } label: {
              EmptyView()
            }
            .labelsHidden()
            .fixedSize()
          }
        }
        Stepper(value: $income.partsExpected, in: 1...12) {
          Text(
            verbatim: environment.language.format(
              "form.expected.parts", table: "Planning", income.partsExpected))
        }
        DatePicker(
          t("form.expected.due"),
          selection: Binding(
            get: { environment.calendar.startOfDay(income.dueDate ?? environment.today) },
            set: {
              income.dueDate = environment.calendar.day(of: $0)
              followTheLastDay()
            }),
          displayedComponents: .date)
        if offersLastDay {
          Toggle(
            t("form.lastDay"),
            isOn: Binding(
              get: { lastDay },
              set: {
                lastDay = $0
                followTheLastDay()
              }))
        }
        if offersTerms {
          ForEach($extraTerms) { $term in
            HStack {
              Stepper(value: $term.day, in: 1...31) {
                Text(
                  verbatim: term.isLastDay
                    ? t("form.expected.termLast")
                    : environment.language.format(
                      "form.expected.termDay", table: "Planning", term.day))
              }
              AmountField(amount: $term.amountE4, locale: environment.language.locale)
                .frame(maxWidth: 140)
              Button {
                extraTerms.removeAll { $0.id == term.id }
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .help(t("form.expected.termRemove"))
              .accessibilityLabel(Text(verbatim: t("form.expected.termRemove")))
            }
          }
          if extraTerms.count < ExpectedIncome.maxExtraTerms {
            Button {
              extraTerms.append(IncomeTerm(day: 31, amountE4: income.totalE4))
            } label: {
              Label {
                Text(verbatim: t("form.expected.termAdd"))
              } icon: {
                Image(systemName: "plus")
              }
            }
            .help(t("form.expected.termHint"))
            .accessibilityIdentifier("expected.termAdd")
          }
        }
        if income.kind == .recurring {
          Picker(
            t("form.freq"),
            selection: Binding(
              get: { income.freq ?? .monthly },
              set: {
                income.freq = $0
                followTheLastDay()
              })
          ) {
            ForEach(Frequency.allCases, id: \.self) {
              Text(verbatim: t("form.freq.\($0.rawValue)")).tag($0)
            }
          }
        }
        Picker(t("form.category"), selection: $income.categoryId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.options(.income)) {
            Text(verbatim: choices.label($0)).tag(Optional($0.id))
          }
        }
        Picker(t("form.person"), selection: $income.personId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
        Picker(t("form.toAccount"), selection: $income.paymentMethodId) {
          ForEach(
            ExpectedIncomeAccounts.options(
              compute.snapshot?.dataset.paymentMethods ?? [], selection: income.paymentMethodId,
              auto: t("form.toAccount.auto"), locale: environment.language.locale), id: \.self
          ) { option in
            Text(verbatim: option.title).tag(option.id)
          }
        }
        .accessibilityIdentifier("expected.account")
      }
      .formStyle(.grouped)
      HStack {
        if let original, !original.closed {
          Button(t("expected.close")) {
            if let dependencies, PlanningActions(dependencies).close(original) { dismiss() }
          }
        }
        FormButtons(
          title: environment.language("action.save"),
          enabled: !income.name.trimmingCharacters(in: .whitespaces).isEmpty
            && income.totalE4.raw > 0
        ) {
          guard let dependencies else { return false }
          let ready = income.readyToSave(
            today: environment.today, lastDay: offersLastDay && lastDay)
          // The other terms of the month are incomes of their own, written with this one in one
          // step: one ⌘Z takes them all back.
          let others = offersTerms ? income.terms(extraTerms, today: environment.today) : []
          return PlanningActions(dependencies).save([ready] + others)
        }
      }
    }
    .padding(20)
    .sheetFrame(width: 480, height: 520)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      income =
        original
        ?? Self.newIncome(defaultCurrency: environment.defaultCurrency, today: environment.today)
      lastDay = income.isOnLastDay
    }
  }

  /// A new expected income: in the default currency, due today until another day is picked.
  static func newIncome(defaultCurrency: CurrencyCode, today: DateOnly) -> ExpectedIncome {
    ExpectedIncome(name: "", totalE4: .zero, currency: defaultCurrency, dueDate: today)
  }

  private var offersLastDay: Bool { income.offersLastDay }

  /// «Ещё срок в месяце» is offered for a new income by the month; a saved one is one income, and
  /// another term is made from a new form.
  private var offersTerms: Bool {
    original == nil && income.kind == .recurring && (income.freq ?? .monthly) == .monthly
  }

  private func followTheLastDay() { income.followTheLastDay(&lastDay, today: environment.today) }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// «На счёт» of an expected income: where its money is to come to. The first choice leaves it
/// open — the account of the latest income received for it, else the main one —; then the
/// live accounts in the order of every menu, the main one first. An account chosen before and
/// archived since stays in the list, so the form shows what is stored.
@MainActor
enum ExpectedIncomeAccounts {
  struct Option: Hashable {
    var id: UUID?
    var title: String
  }

  static func options(
    _ accounts: [PaymentMethod], selection: UUID?, auto: String, locale: Locale
  ) -> [Option] {
    let offered = FormAccounts.offered(accounts, locale: locale)
    var options = [Option(id: nil, title: auto)]
    options += offered.map { Option(id: $0.id, title: $0.name) }
    if let selection, !offered.contains(where: { $0.id == selection }),
      let kept = accounts.first(where: { $0.id == selection })
    {
      options.append(Option(id: kept.id, title: kept.name))
    }
    return options
  }
}

extension ExpectedIncome {
  /// Only a recurring income by the month or the year comes on a day of the month.
  var offersLastDay: Bool { kind == .recurring && freq != .weekly }

  /// The income as the last-day switch of its form leaves it: with the switch on, the first due
  /// date is the last day of its month. A switch the form no longer shows — a one-off income,
  /// a weekly one — is turned off: out of sight it would move a date picked later.
  mutating func followTheLastDay(_ lastDay: inout Bool, today: DateOnly) {
    guard offersLastDay else {
      lastDay = false
      return
    }
    guard lastDay else { return }
    dueDate = MonthEnd.lastDay(of: dueDate ?? today)
  }

  /// Whether a recurring income comes on the last day of the month: its day is the one a rule
  /// keeps for it (`MonthEnd`).
  var isOnLastDay: Bool {
    kind == .recurring
      && MonthEnd.isLastDay(day: day, freq: freq ?? .monthly, month: dueDate?.month)
  }

  /// The row the form saves: a recurring income keeps its frequency and the day of it, a
  /// one-off one neither, and a due date left empty is today — the day the date field shows.
  /// With `lastDay` a monthly or yearly income keeps the day of the last day of the month, so
  /// a first due of 30 September is followed by 31 October, not by 30 October.
  func readyToSave(today: DateOnly, lastDay: Bool = false) -> ExpectedIncome {
    var saved = self
    // The date first: the day of the schedule is read off it.
    if saved.dueDate == nil { saved.dueDate = today }
    if saved.kind == .recurring {
      let freq = saved.freq ?? .monthly
      saved.freq = freq
      saved.day = saved.dueDate.map { due in
        lastDay && freq != .weekly
          ? MonthEnd.day(freq: freq, month: due.month)
          : Recurrence.anchor(of: due, freq: freq).day
      }
    } else {
      saved.freq = nil
      saved.day = nil
    }
    return saved
  }
}

/// One more day of the month an income comes on, and how much comes then — «Ещё срок в месяце».
struct IncomeTerm: Hashable, Identifiable {
  var id = UUID()
  /// 1…31; 31 is the last day of the month.
  var day: Int
  var amountE4: AmountE4

  init(day: Int = 31, amountE4: AmountE4 = .zero) {
    self.day = min(max(day, 1), 31)
    self.amountE4 = amountE4
  }

  /// Whether this term is the last day of the month.
  var isLastDay: Bool { day == 31 }
}

extension ExpectedIncome {
  /// Terms more than this a month do not fit one form.
  static let maxExtraTerms = 3

  /// The other terms of an income that comes several times a month — the parents' money on the
  /// 15th and on the last day, 25,000 each —: for every term with an amount a monthly recurring
  /// copy of this income (the same name, category, person, account and currency) with that term's
  /// amount and its day, first due on that day in the month of this income's first due date, or
  /// in the next month when that day has passed in it. Each is an income of its own, so every
  /// term is due, received and linked on its own. Only an income by the month has terms, and at
  /// most `maxExtraTerms` are made. The rows are ready to save (`readyToSave`).
  func terms(_ terms: [IncomeTerm], today: DateOnly) -> [ExpectedIncome] {
    guard kind == .recurring, (freq ?? .monthly) == .monthly else { return [] }
    let first = dueDate ?? today
    return terms.prefix(Self.maxExtraTerms).compactMap { term in
      guard term.amountE4.raw > 0 else { return nil }
      var copy = self
      copy.id = UUID()
      copy.freq = .monthly
      copy.totalE4 = term.amountE4
      copy.closed = false
      var due = Self.date(of: term, in: first.monthKey)
      if due < first { due = Self.date(of: term, in: first.monthKey.adding(months: 1)) }
      copy.dueDate = due
      // The day of the rule is the term's own, not the one a short month clipped its first due
      // date to: the 30th of February is 28 February once and the 30th every month after.
      var ready = copy.readyToSave(today: today, lastDay: term.isLastDay)
      ready.day = term.isLastDay ? MonthEnd.day(freq: .monthly, month: nil) : term.day
      return ready
    }
  }

  /// The day of `term` in `month`, clipped to its length: the last day for 31.
  private static func date(of term: IncomeTerm, in month: MonthKey) -> DateOnly {
    DateOnly(year: month.year, month: month.month, day: min(term.day, month.dayCount))
  }
}

/// Ties an income already received to what was expected: the income of the last 60 days not
/// tied to anything yet, the likeliest first (same category and person).
struct LinkIncomeForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let status: ExpectedIncomeStatus

  var body: some View {
    let candidates = self.candidates
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("form.link.title", table: "Planning", status.income.name))
        .appFont(.headline)
      if candidates.isEmpty {
        Text(verbatim: t("form.link.none")).foregroundStyle(.secondary)
      }
      List(candidates, id: \.id) { entry in
        HStack {
          Text(
            verbatim: environment.dates.longDay(
              environment.calendar.day(of: entry.transaction.occurredAt))
          )
          .monospacedDigit()
          .foregroundStyle(.secondary)
          Text(verbatim: entry.transaction.note ?? "—").lineLimit(1)
          Spacer()
          Text(
            verbatim: environment.money.exact(
              entry.transaction.amountE4, currency: entry.transaction.currency)
          )
          .monospacedDigit()
          Button(t("expected.link")) {
            guard let dependencies else { return }
            if PlanningActions(dependencies).link(income: entry.id, to: status.income) { dismiss() }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .frame(minHeight: 220)
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 380)
  }

  private var candidates: [TransactionEntry] {
    guard let snapshot = compute.snapshot else { return [] }
    let linked = Set(snapshot.dataset.planning.expectedLinks.map(\.transactionId))
    let since = environment.calendar.adding(days: -60, to: snapshot.today)
    return snapshot.dataset.entries
      .filter {
        $0.transaction.kind == .income && !$0.transaction.isDeleted && !linked.contains($0.id)
          && environment.calendar.day(of: $0.transaction.occurredAt) >= since
      }
      .sorted { lhs, rhs in
        let left = likely(lhs)
        let right = likely(rhs)
        return left != right ? left : lhs.transaction.occurredAt > rhs.transaction.occurredAt
      }
  }

  private func likely(_ entry: TransactionEntry) -> Bool {
    entry.parts.contains {
      $0.categoryId == status.income.categoryId && status.income.categoryId != nil
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// How a menu names the expected incomes it offers. Names may repeat: an income whose name
/// another one of the menu has too is told apart by its amount and the date it is awaited —
/// «Зарплата · 50,000 ₽ · 15 октября» —, one with a name of its own is its name alone.
@MainActor
enum ExpectedIncomeLabels {
  static func titles(
    _ statuses: [ExpectedIncomeStatus], money: (AmountE4, CurrencyCode) -> String,
    day: (DateOnly) -> String
  ) -> [UUID: String] {
    let namesakes = ExpectedIncomeRules.namesakes(among: statuses.map(\.income))
    var titles: [UUID: String] = [:]
    for status in statuses {
      guard namesakes.contains(status.id) else {
        titles[status.id] = status.income.name
        continue
      }
      var pieces = [status.income.name, money(status.income.totalE4, status.currency)]
      if let due = awaited(status) { pieces.append(day(due)) }
      titles[status.id] = pieces.joined(separator: " · ")
    }
    return titles
  }

  static func titles(
    _ statuses: [ExpectedIncomeStatus], _ environment: AppEnvironment
  ) -> [UUID: String] {
    titles(
      statuses, money: { environment.money.rounded($0, currency: $1) },
      day: { environment.dates.dayAndMonth($0) })
  }

  /// The date the income waits for money on: its first due date still short of money, else the
  /// latest one listed, else the stored first one.
  private static func awaited(_ status: ExpectedIncomeStatus) -> DateOnly? {
    status.occurrences.first { !$0.isFulfilled }?.due ?? status.current?.due
      ?? status.income.dueDate
  }
}
