import AppCore
import AppDatabase
import SwiftUI

/// A payout of interest to record as the ordinary income it is: what the form starts with — the
/// sum expected, the day it was due, the account it goes to and in which currency. The owner
/// may change any of it before the income is written.
struct DepositIncomePrefill: Identifiable, Hashable, Sendable {
  /// The account that earned the interest.
  var depositId: UUID
  var accountId: UUID
  var currency: CurrencyCode
  var amount: AmountE4
  var day: DateOnly

  var id: String { "\(depositId.uuidString) \(day.iso)" }

  init(_ payout: DepositPayout) {
    depositId = payout.accountId
    accountId = payout.target.accountId
    currency = payout.target.currency
    amount = payout.expectedE4
    day = payout.payDate
  }

  /// The moment the income is dated with: a day gone by at noon — the month it belongs to
  /// must be right —, today now, as the entry line dates today's operations.
  static func moment(of day: DateOnly, today: DateOnly, calendar: CalendarContext) -> Date {
    guard day != today else { return Date() }
    return calendar.noon(of: day)
  }
}

/// What «Проценты» of an account's screen says, in the words of the interface, built without a
/// view so it can be checked in both languages. Every sum of interest is an estimate: «≈», and
/// grey where it is shown — never income until the owner records it.
struct AccountInterestLines: Equatable {
  /// A payout to ask about, with «Записать…».
  struct Ask: Equatable, Identifiable {
    var text: String
    /// Nothing came days after the pay date (`DepositPayout.State.missing`): «не пришли?».
    var isMissing: Bool
    var prefill: DepositIncomePrefill
    var id: String { prefill.id }
  }

  /// «Ставка 16 % · выплата 31 октября».
  var headline: String
  /// «Вклад до 31 марта 2027», «Накопительный счёт», or that the deposit has ended.
  var kind: String
  /// The deposit ended: no interest any more.
  var ended: Bool
  /// «Сверьте счёт — без остатка проценты не посчитать», when the account was never counted.
  var notCounted: String?
  /// «Начислено с 1 октября ≈ 1,234.56 ₽».
  var accrued: String?
  /// «К выплате 31 октября ≈ 2,345.67 ₽ → на этот счёт».
  var payout: String?
  /// «К концу срока ≈ 12,345.67 ₽», for a deposit.
  var toEnd: String?
  /// Payouts due or missing, oldest first.
  var asks: [Ask]
}

/// The words of interest: the account's block, the forecast line and the rows of «Поступления».
@MainActor
enum InterestText {

  static func issueKey(_ issue: InterestIssue) -> String {
    switch issue {
    case .rate: "account.interest.refusal.rate"
    case .endNeeded: "account.interest.refusal.endNeeded"
    case .endBeforeOpening: "account.interest.refusal.endBeforeOpening"
    case .payoutAccount: "account.interest.refusal.payoutAccount"
    }
  }

  /// «16», «16.5»: the rate without trailing zeros, as numbers are written everywhere.
  static func rate(_ rate: Decimal, _ environment: AppEnvironment) -> String {
    environment.format(
      "account.interest.ratePercent", table: "Accounts", environment.money.number(rate))
  }

  /// «≈ 2,345.67 ₽».
  static func approximately(
    _ amount: AmountE4, _ currency: CurrencyCode, _ environment: AppEnvironment
  ) -> String {
    "≈\u{00A0}" + environment.money.exact(amount, currency: currency)
  }

  /// «на этот счёт», «на «Карта»».
  static func destination(
    of payout: DepositPayout, names: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    if payout.target.accountId == payout.accountId {
      return environment.language("account.interest.toThisAccount", table: "Accounts")
    }
    return environment.format(
      "account.interest.toAccount", table: "Accounts", names[payout.target.accountId] ?? "—")
  }

  /// Everything the block says of `outlook` on `today`; `names` name the accounts by id.
  static func lines(
    _ outlook: DepositOutlook, names: [UUID: String], today: DateOnly,
    _ environment: AppEnvironment
  ) -> AccountInterestLines {
    func t(_ key: String) -> String { environment.language(key, table: "Accounts") }
    let dates = environment.dates
    let terms = outlook.terms
    let current = outlook.counted ? outlook.current(today: today) : nil
    let ended = terms.endsOn.map { $0 < today } ?? false

    var headline = rate(terms.rate, environment)
    if let current, !ended {
      headline +=
        " · "
        + environment.format(
          "account.interest.paysOn", table: "Accounts", dates.dayAndMonth(current.payDate))
    } else if !ended {
      headline += " · " + t(AccountInterestSection.periodKey(terms.period)).lowercased()
    }

    let kind: String
    if let endsOn = terms.endsOn {
      kind = environment.format(
        ended ? "account.interest.depositEnded" : "account.interest.depositUntil",
        table: "Accounts",
        dates.longDay(endsOn))
    } else {
      kind = t("account.interest.isSavings")
    }

    var lines = AccountInterestLines(
      headline: headline, kind: kind, ended: ended, notCounted: nil, accrued: nil, payout: nil,
      toEnd: nil, asks: [])
    guard outlook.counted else {
      lines.notCounted = t("account.interest.notCounted")
      return lines
    }
    let currency = outlook.key.currency
    if let current, !ended {
      if current.payDate > today || current.state == .accruing {
        lines.accrued = environment.format(
          "account.interest.accrued", table: "Accounts", dates.dayAndMonth(current.periodStart),
          approximately(current.accruedE4, currency, environment))
      }
      if case .received = current.state {
        lines.payout = environment.format(
          "account.interest.received", table: "Accounts", dates.dayAndMonth(current.payDate))
      } else {
        lines.payout = environment.format(
          "account.interest.payout", table: "Accounts", dates.dayAndMonth(current.payDate),
          approximately(current.expectedE4, current.target.currency, environment),
          destination(of: current, names: names, environment))
      }
    }
    if let toEnd = outlook.toEndE4, !ended, toEnd.raw > 0 {
      lines.toEnd = environment.format(
        "account.interest.toEnd", table: "Accounts", approximately(toEnd, currency, environment))
    }
    lines.asks = outlook.payouts.compactMap { payout in
      switch payout.state {
      case .missing:
        return AccountInterestLines.Ask(
          text: environment.format(
            "account.interest.missing", table: "Accounts",
            approximately(payout.expectedE4, payout.target.currency, environment),
            dates.dayAndMonth(payout.payDate)),
          isMissing: true, prefill: DepositIncomePrefill(payout))
      case .due where payout.payDate < today:
        return AccountInterestLines.Ask(
          text: environment.format(
            "account.interest.due", table: "Accounts",
            approximately(payout.expectedE4, payout.target.currency, environment),
            dates.dayAndMonth(payout.payDate)),
          isMissing: false, prefill: DepositIncomePrefill(payout))
      default:
        return nil
      }
    }
    return lines
  }

  /// The names of the accounts, by id, archived ones too.
  static func names(_ accounts: [PaymentMethod]) -> [UUID: String] {
    Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }
}

/// «Проценты» on the screen of an account that earns interest: the rate and the next payout,
/// what the period has earned so far, what is to be paid and where, what is still to come to
/// the end of a deposit, and the payouts that did not come — each with «Записать…», which
/// opens the ordinary income prefilled. Everything is an estimate, grey and with «≈»: interest
/// is income only once recorded.
struct AccountInterestBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let accountId: UUID

  @State private var outlook: DepositOutlook?
  @State private var loaded = false
  @State private var recording: DepositIncomePrefill?

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  /// The account earns interest by its terms in the data.
  private var earns: Bool {
    compute.snapshot?.dataset.paymentMethods.first { $0.id == accountId }?.interest != nil
  }

  var body: some View {
    Group {
      if earns {
        ComputedBlock(
          title: t("account.interest.title"), state: state, retry: nil
        ) { outlook in
          content(outlook)
        }
        .accessibilityIdentifier("account.interest")
      }
    }
    .task(id: InterestKey(account: accountId, generation: compute.generation)) {
      guard let snapshot = compute.snapshot else { return }
      let accountId = self.accountId
      outlook = await Task.detached(priority: .userInitiated) {
        AccountInterestBlock.outlook(of: accountId, snapshot: snapshot)
      }.value
      loaded = true
    }
    .sheet(item: $recording) { prefill in
      DepositIncomeSheet(prefill: prefill) { recording = nil }
        .handingOver(dependencies)
    }
  }

  /// The outlook of the account in the data of `snapshot`, as every screen works it out.
  nonisolated static func outlook(of accountId: UUID, snapshot: DataSnapshot) -> DepositOutlook? {
    DepositPayouts.outlook(
      of: accountId, ledger: snapshot.ledger, balances: snapshot.planning.accounts.balances,
      interestCategoryId: snapshot.dataset.accountSettings.interestCategoryId,
      today: snapshot.today, through: snapshot.today.monthKey.lastDay)
  }

  private var state: BlockState<DepositOutlook> {
    guard loaded, let outlook else { return .calculating }
    return .ready(outlook, at: environment.now())
  }

  private func content(_ outlook: DepositOutlook) -> some View {
    let lines = InterestText.lines(
      outlook, names: InterestText.names(compute.snapshot?.dataset.paymentMethods ?? []),
      today: environment.today, environment)
    return VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: lines.headline)
        .fontWeight(.medium)
      Label {
        Text(verbatim: lines.kind)
      } icon: {
        Image(systemName: lines.ended ? "calendar.badge.checkmark" : "calendar")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      if let notCounted = lines.notCounted {
        Label {
          Text(verbatim: notCounted)
        } icon: {
          Image(systemName: "hourglass")
        }
        .foregroundStyle(.secondary)
      }
      // Estimates: grey, with «≈» in the words — never colour alone.
      ForEach([lines.accrued, lines.payout, lines.toEnd].compactMap { $0 }, id: \.self) { line in
        Text(verbatim: line)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      ForEach(lines.asks) { ask in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: ask.isMissing ? "questionmark.circle" : "clock")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(verbatim: ask.text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
          Spacer(minLength: 6)
          Button(t("account.interest.record")) { recording = ask.prefill }
            .controlSize(.small)
            .accessibilityIdentifier("account.interest.record")
        }
        .accessibilityElement(children: .combine)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct InterestKey: Hashable {
  var account: UUID
  var generation: Int
}

/// «Записать проценты»: the ordinary income of interest, prefilled with what the payout was
/// expected to bring — the sum, the day, the account it goes to — in the category of interest.
/// The owner corrects the sum to what the bank paid. One step of ⌘Z; a day of a count asks
/// whether it came before it, like every form that moves money.
struct DepositIncomeSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute

  let prefill: DepositIncomePrefill
  let finish: () -> Void

  @State private var amount: AmountE4 = .zero
  @State private var date = Date()
  @State private var account: UUID?
  @State private var loaded = false

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    VStack(alignment: .leading) {
      Text(verbatim: t("account.interest.recordTitle"))
        .appFont(.headline)
      Text(verbatim: depositName)
        .appFont(.caption)
        .foregroundStyle(.secondary)
      Form {
        LabeledContent(t("account.interest.recordAmount")) {
          HStack {
            AmountField(amount: $amount, locale: environment.language.locale)
              .accessibilityIdentifier("account.interest.recordAmount")
            Text(verbatim: prefill.currency.code).foregroundStyle(.secondary)
          }
        }
        DatePicker(t("account.interest.recordDate"), selection: $date)
        AccountPicker(
          title: t("account.interest.recordAccount"), accounts: accounts, selection: $account)
        LabeledContent(t("account.interest.recordCategory")) {
          Text(verbatim: categoryName)
        }
        Text(verbatim: t("account.interest.recordHint"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      CountingFormButtons(
        title: t("account.interest.recordSave"), enabled: amount.raw > 0 && account != nil,
        failure: { "" }, ask: question, moment: { date }
      ) { moment in
        guard let account else { return false }
        return actions.recordInterest(
          amount: amount, currency: prefill.currency, accountId: account, at: moment ?? date,
          dataset: compute.snapshot?.dataset) == .done
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 420)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      amount = prefill.amount
      date = DepositIncomePrefill.moment(
        of: prefill.day, today: environment.today, calendar: environment.calendar)
      account =
        accounts.contains { $0.id == prefill.accountId } ? prefill.accountId : accounts.first?.id
    }
    .onDisappear(perform: finish)
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  /// The live accounts that hold the currency of the interest: it comes in that currency.
  private var accounts: [PaymentMethod] {
    (compute.snapshot?.dataset.paymentMethods ?? []).filter {
      !$0.archived && $0.holds(prefill.currency)
    }
  }

  private var depositName: String {
    compute.snapshot?.dataset.paymentMethods.first { $0.id == prefill.depositId }?.name ?? ""
  }

  /// The category the income goes to: the one of interest, or the one the save will make.
  private var categoryName: String {
    let dataset = compute.snapshot?.dataset
    let id = dataset?.accountSettings.interestCategoryId
    return dataset?.categories.first { $0.id == id && !$0.archived }?.name
      ?? t("account.interest.category")
  }

  /// «Это было до сверки?» when the income is dated on the day of a count of its account.
  private func question() -> DueCountAsk {
    guard let account,
      let entry = try? actions.interestEntry(
        amount: amount, currency: prefill.currency, accountId: account, at: date,
        categoryId: UUID())
    else { return .none }
    return .sameDay(
      FormAccounts.countAsk(
        about: entry, savedAt: Date(), snapshot: compute.snapshot,
        calendar: environment.calendar, remembered: environment.rememberedCountAnswers()))
  }
}

extension AccountActions {
  /// The income of interest as the entry line would write it: one part in `categoryId`, on
  /// `accountId`, at `at`, rubles at the bank's rate of its day.
  func interestEntry(
    amount: AmountE4, currency: CurrencyCode, accountId: UUID, at: Date, categoryId: UUID
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .income, occurredAt: at, currency: currency, amount: amount,
      paymentMethodId: accountId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = categoryId
    draft.parts[0].categorySource = .manual
    environment.applyRate(to: &draft)
    return try draft.materialize(
      now: environment.now(), rublesConverter: environment.rublesConverter(for: draft))
  }

  /// Records a payout of interest — the ordinary income it is — and, when there is no live
  /// category of interest yet, makes or brings it back in the same write: one step of ⌘Z.
  /// `dataset` is the data the form was shown on: the categories and the setting are read
  /// from it.
  func recordInterest(
    amount: AmountE4, currency: CurrencyCode, accountId: UUID, at: Date, dataset: Dataset?
  ) -> AccountActionOutcome {
    guard amount.raw > 0 else { return .refused(.notFound) }
    guard let dataset else { return .failed }
    let now = environment.now()
    let books = AccountBooks(dataset: dataset, at: now, calendar: environment.calendar)
    var change = PlanningChange(at: now)
    let categoryId = addInterestCategory(to: &change, books: books)
    do {
      change.created = [
        try interestEntry(
          amount: amount, currency: currency, accountId: accountId, at: at,
          categoryId: categoryId)
      ]
    } catch {
      return .failed
    }
    let outcome = apply(change)
    if outcome == .done {
      AppLog.info(
        "interest.recorded", .db, "a payout of interest was recorded",
        [LogPair("account", .id(accountId))])
    }
    return outcome
  }
}
