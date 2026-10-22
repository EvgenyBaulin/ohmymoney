import AppCore
import SwiftUI

// MARK: - Scheduled payments

/// Scheduled payments, as one block of both kinds or — on the Planning screen — as two:
/// «Платежи» (`kind: .bill`) with the money each account needs, and «Подписки»
/// (`kind: .subscription`) with their price a month and a year and the subscriptions the
/// purchases suggest. Each lists the nearest due first, as many as `length` says, the rest behind
/// «Показать все»; an empty one says what it is for, with the button that adds the first.
struct ScheduledBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.planningCardHosted) private var hosted
  @Binding var sheet: PlanningSheet?
  /// Which payments the block lists; `nil` — both kinds.
  var kind: ScheduledKind? = nil
  /// How many of the nearest payments show before «Показать все».
  var length: PlanningListLength = .all
  @State private var showsAll = false

  var body: some View {
    ComputedBlock(
      title: hosted ? nil : t(titleKey), state: compute.states.data,
      style: hosted ? .plain : .card, retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let planning = snapshot.planning
      let statuses = planning.scheduled.filter { kind == nil || $0.payment.kind == kind }
      let shown = PlanningShortListView.shown(
        statuses, length: length, expanded: showsAll, date: { $0.nextUnpaid })
      VStack(alignment: .leading, spacing: 10) {
        if kind == nil || (kind == .subscription && !statuses.isEmpty) {
          Text(
            verbatim: environment.language.format(
              "scheduled.totals", table: "Planning",
              environment.money.rounded(planning.subscriptionsMonthly),
              environment.money.rounded(planning.subscriptionsYearly))
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        if statuses.isEmpty, hosted, kind == .bill {
          PlanningEmptyHint(block: .payments) { add() }
            .guideTarget("planning.addPayment")
        } else if statuses.isEmpty, hosted, kind == .subscription {
          PlanningEmptyHint(block: .subscriptions) { add() }
        } else {
          HStack {
            if statuses.isEmpty {
              Text(verbatim: t("scheduled.none")).foregroundStyle(.secondary)
            }
            Spacer()
            if kind == .subscription {
              addButton
            } else {
              addButton.guideTarget("planning.addPayment")
            }
          }
        }
        ForEach(shown.items) { status in
          ScheduledRow(
            status: status, prices: planning.book.prices, matches: planning.matches,
            sheet: $sheet)
        }
        if kind != .subscription {
          NPDPaymentRows(
            months: NPDPaymentRows.rows(
              npd: planning.npd, categories: snapshot.dataset.categories, today: snapshot.today),
            quarters: NPDPaymentRows.quarterRows(npd: planning.npd))
        }
        PlanningShowAllButton(
          block: kind == .subscription ? .subscriptions : .payments, total: statuses.count,
          hidden: shown.hidden, expanded: $showsAll)
        if kind != .subscription, !planning.funding.isEmpty {
          FundingLines(lines: planning.funding, methods: snapshot.dataset.paymentMethods)
        }
        if kind != .bill {
          ForEach(planning.candidates.prefix(3)) { candidate in
            HStack(spacing: 6) {
              Image(systemName: "sparkle.magnifyingglass").accessibilityHidden(true)
              Text(
                verbatim: environment.language.format(
                  "scheduled.candidate", table: "Planning", candidateName(candidate, snapshot),
                  environment.money.rounded(candidate.typicalAmount, currency: candidate.currency))
              )
              Spacer()
              Button(t("scheduled.candidateCreate")) {
                sheet = .subscription(from: candidate, name: candidateName(candidate, snapshot))
              }
              .buttonStyle(.link)
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var addButton: some View {
    Button(t(kind == .subscription ? "layout.add.subscriptionButton" : "scheduled.add")) {
      add()
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private var titleKey: String {
    switch kind {
    case .bill: "layout.block.payments"
    case .subscription: "layout.block.subscriptions"
    case nil: "scheduled.title"
    }
  }

  /// «+ Платёж» opens an empty payment; in «Подписки» the form starts as a subscription.
  private func add() {
    sheet = kind == .subscription ? .newSubscription(environment) : .payment(nil)
  }

  /// What a candidate is called: the place it was bought at, or the description of its
  /// latest purchase as the owner typed it — never the key it was grouped by.
  private func candidateName(_ candidate: SubscriptionCandidate, _ snapshot: DataSnapshot) -> String
  {
    if let placeId = candidate.placeId,
      let place = snapshot.dataset.places.first(where: { $0.id == placeId })
    {
      return place.name
    }
    let latest = snapshot.dataset.entries
      .filter {
        !$0.transaction.isDeleted
          && SubscriptionCandidates.normalized($0.transaction.note ?? "") == candidate.key
      }
      .max { $0.transaction.occurredAt < $1.transaction.occurredAt }
    return latest?.transaction.note ?? candidate.key
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// One payment: when, what, how much, how it is paid and for whom, with «Mark as paid» and
/// «Skip»; a subscription opens to its price per month and per year, its price history, the
/// end of its trial and the link to cancel it.
struct ScheduledRow: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let status: ScheduledStatus
  let prices: [SubscriptionPrice]
  /// The due dates paid, by a key or by a matching operation.
  let matches: ScheduledMatches
  @Binding var sheet: PlanningSheet?
  @State private var expanded = false
  @State private var confirmsDeletion = false

  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    let payment = status.payment
    let tint = status.isOverdue ? surfaces.negative : surfaces.accent
    HStack(alignment: .top, spacing: 12) {
      // The tile says what the row is by its symbol; an overdue one says so by the symbol, the
      // word in the line under the name and the red, never by the red alone.
      Image(systemName: tileSymbol)
        .appFont(.callout.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 36, height: 36)
        .background(tint.opacity(0.14), in: .rect(cornerRadius: 10))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(verbatim: payment.name)
            .appFont(.body.weight(.semibold))
            .lineLimit(1)
          if Self.showsDetails(status, prices: prices) {
            Button {
              expanded.toggle()
            } label: {
              Image(systemName: expanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: t("scheduled.details")))
          }
        }
        subtitle
        if Self.canPay(status, matches: matches) {
          HStack(spacing: 14) {
            Button(t("scheduled.markAsPaid")) { sheet = .markAsPaid(Self.paying(status)) }
            Button(t("scheduled.skip")) {
              if let dependencies {
                PlanningActions(dependencies).skip(payment, due: status.nextUnpaid)
              }
            }
          }
          .buttonStyle(.borderless)
          .appFont(.callout)
        }
        MatchedDues(status: status)
        if expanded && Self.showsDetails(status, prices: prices) { details }
      }
      Spacer(minLength: 6)
      Text(verbatim: environment.money.exact(status.amountNext, currency: payment.currency))
        .appFont(.body.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button(environment.language("action.edit")) { sheet = .payment(payment) }
      Button(environment.language("action.delete")) { confirmsDeletion = true }
    }
    .confirmationDialog(
      environment.format("scheduled.deleteTitle", table: "Planning", payment.name),
      isPresented: $confirmsDeletion, titleVisibility: .visible
    ) {
      Button(environment.language("action.delete"), role: .destructive) {
        if let dependencies { PlanningActions(dependencies).delete(payment) }
      }
    } message: {
      Text(verbatim: t("scheduled.deleteMessage"))
    }
  }

  private var tileSymbol: String {
    if status.isOverdue { return "exclamationmark.circle" }
    return status.payment.kind == .subscription ? "arrow.triangle.2.circlepath" : "calendar"
  }

  /// The day the first due date nothing paid falls on. An ordinary operation that matches a due
  /// date pays it, and `next_date` stays behind until «Привязать» or «Провести» moves it. A due
  /// date of another year says its year: «8 мая 2027», not «8 мая».
  private var dueText: String {
    status.nextUnpaid.year == environment.today.year
      ? environment.dates.dayAndMonth(status.nextUnpaid)
      : environment.dates.longDay(status.nextUnpaid)
  }

  /// «Провести» and «Пропустить» are for a due date nothing has paid. When every due date left
  /// is paid already — a one-off payment paid by an ordinary expense — the row shows the last
  /// one, paid: paying it again would count the money twice, so the row offers only
  /// «Привязать» under it.
  static func canPay(_ status: ScheduledStatus, matches: ScheduledMatches) -> Bool {
    !matches.isPaid(status.payment.id, status.nextUnpaid)
  }

  /// The status «Провести» pays: its first unpaid due date. The ones between `next_date` and
  /// it are paid by matching operations already; the action keys those operations to their
  /// due dates in the same write, so the payment moving past them keeps what they paid.
  static func paying(_ status: ScheduledStatus) -> ScheduledStatus {
    var paying = status
    paying.nextDue = status.nextUnpaid
    return paying
  }

  /// The price history of a subscription, newest first, as its details list it.
  static func history(
    of status: ScheduledStatus, in prices: [SubscriptionPrice]
  )
    -> [SubscriptionPrice]
  {
    prices.filter { $0.paymentId == status.payment.id }.sorted { $0.date > $1.date }
  }

  /// A subscription's chevron opens its details, and shows only when they hold something: the
  /// figure per month and per year (none on a one-off one, `perMonthYearText`), the trial's end,
  /// the price history or a working cancel link. A new one-off subscription has none of these
  /// — its price history starts with the first edit of the price — and would open empty.
  static func showsDetails(_ status: ScheduledStatus, prices: [SubscriptionPrice]) -> Bool {
    let payment = status.payment
    guard payment.kind == .subscription else { return false }
    return !status.isOneOff || payment.trialEnd != nil || payment.cancelLink != nil
      || !history(of: status, in: prices).isEmpty
  }

  /// «1,500 ₽ в месяц · 18,000 ₽ в год» under a payment with a rhythm; nothing under a planned
  /// expense of one date («Разово»), which is one charge and has no figure per month or per
  /// year — its line would say «0 ₽ в месяц · 0 ₽ в год».
  static func perMonthYearText(
    _ status: ScheduledStatus, language: AppLanguage, money: MoneyFormatter
  ) -> String? {
    guard !status.isOneOff else { return nil }
    let currency = status.payment.currency
    return language.format(
      "scheduled.perMonthYear", table: "Planning",
      money.rounded(status.monthly, currency: currency),
      money.rounded(status.yearly, currency: currency))
  }

  /// What the person gives back, as the row says it: «10.00 $ ≈ 1,050 ₽» in its own currency
  /// with the rubles of today's rate, «920 ₽» in rubles — the rule of the form's «Возвращает»
  /// (`ScheduledPaymentForm.shownReturn`, `returnRubles`), so the two never disagree. The
  /// figure set on the payment, the whole charge when none is set; the rubles are what the
  /// person gives back, even above the charge. A currency without a rate today is shown alone.
  static func returnText(
    _ status: ScheduledStatus, money: MoneyFormatter, rubPerUnit: [CurrencyCode: Decimal]
  ) -> String {
    let payment = status.payment
    let shown = ScheduledPaymentForm.shownReturn(
      payment, charge: status.amountNext, rubPerUnit: rubPerUnit)
    guard shown.currency != .rub else { return money.rounded(shown.amount) }
    let own = money.exact(shown.amount, currency: shown.currency)
    guard
      let rubles = ScheduledPaymentForm.returnRubles(
        payment, charge: status.amountNext, rubPerUnit: rubPerUnit)
    else { return own }
    return "\(own) ≈\u{00A0}\(money.rounded(rubles))"
  }

  /// What pays a payment, as its row names it: «Т-Банк · Black» when it names a card, only
  /// «Сбер» when the card is called like its account; and whether that card is in the archive.
  static func paidWith(
    _ payment: ScheduledPayment, accounts: [PaymentMethod], cards: [PaymentCard]
  ) -> (name: String?, cardArchived: Bool) {
    guard let account = accounts.first(where: { $0.id == payment.paymentMethodId }) else {
      return (nil, false)
    }
    let card = payment.cardId.flatMap { id in cards.first { $0.id == id } }
    return (
      CardRules.displayName(account: account.name, card: card?.name), card?.archived == true
    )
  }

  @ViewBuilder
  private var subtitle: some View {
    let payment = status.payment
    let dataset = compute.snapshot?.dataset
    let paidWith = Self.paidWith(
      payment, accounts: dataset?.paymentMethods ?? [], cards: dataset?.cards ?? [])
    let method = paidWith.name
    let debtor = dataset?.people.first { $0.id == (payment.debtorPersonId ?? payment.forPersonId) }?
      .name
    let pieces = [
      (status.isOverdue ? t("planning.overdue") + " · " : "") + dueText,
      method,
      payment.reimbursable
        ? environment.language.format(
          "scheduled.forOther", table: "Planning", debtor ?? "—",
          Self.returnText(
            status, money: environment.money,
            rubPerUnit: compute.snapshot?.context.rubPerUnit ?? [:]))
        : nil,
      payment.forWhom == .me ? nil : environment.label(for: payment.forWhom),
      status.chargedDifferently ? t("scheduled.chargedDifferently") : nil,
      dataset?.events.first { $0.id == payment.eventId }.map {
        environment.format("scheduled.event", table: "Planning", $0.name)
      },
    ].compactMap { $0 }
    if !pieces.isEmpty {
      Text(verbatim: pieces.joined(separator: " · "))
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
    // Its card is in the archive: «Провести» pays from the account alone.
    if paidWith.cardArchived {
      Label {
        Text(verbatim: t("scheduled.cardArchived"))
      } icon: {
        Image(systemName: "creditcard")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
    // Paid from the main account while its own is archived: said with a symbol and words.
    if status.accountArchived {
      Label {
        Text(verbatim: t("scheduled.accountArchived"))
      } icon: {
        Image(systemName: "archivebox")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var details: some View {
    let payment = status.payment
    let history = Self.history(of: status, in: prices)
    return VStack(alignment: .leading, spacing: 3) {
      if let perMonthYear = Self.perMonthYearText(
        status, language: environment.language, money: environment.money)
      {
        Text(verbatim: perMonthYear)
      }
      if let trial = payment.trialEnd {
        Text(
          verbatim: environment.format(
            "scheduled.trialEnds", table: "Planning",
            environment.dates.longDay(trial)))
      }
      ForEach(history, id: \.id) { price in
        Text(
          verbatim:
            "\(environment.dates.longDay(price.date)) — \(environment.money.exact(price.amountE4, currency: payment.currency))"
        )
        .monospacedDigit()
      }
      if let link = payment.cancelLink {
        Link(t("scheduled.cancelLink"), destination: link)
      }
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }

  private func t(_ key: String) -> String {
    key.hasPrefix("action.")
      ? environment.language(key) : environment.language(key, table: "Planning")
  }
}

/// «Т-Банк — 1,348 ₽, 12 $ · проведено 900 ₽»: what each account needs this month, by the
/// currency it is taken in — a payment in a currency the account does not hold is counted in
/// the account's own at today's rate, or left in its own with «без курса». The lines come in
/// the order of every menu, the main account first (`Funding.month`).
private struct FundingLines: View {
  @Dependency(\.environment) private var environment
  let lines: [FundingLine]
  let methods: [PaymentMethod]

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: environment.language("funding.title", table: "Planning"))
        .appFont(.caption.weight(.semibold))
      ForEach(Self.byAccount(lines), id: \.account) { group in
        Text(
          verbatim: "\(name(group.account)) — "
            + group.lines.map { amount($0.remaining, $0) }.joined(separator: ", ")
            + " · "
            + environment.language.format(
              "funding.paid", table: "Planning",
              group.lines.map { amount($0.paid, $0) }.joined(separator: ", "))
        )
        .monospacedDigit()
      }
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }

  /// The lines of one account together, in the order they came: the core orders them.
  static func byAccount(_ lines: [FundingLine]) -> [(account: UUID?, lines: [FundingLine])] {
    var result: [(account: UUID?, lines: [FundingLine])] = []
    for line in lines {
      if let index = result.firstIndex(where: { $0.account == line.paymentMethodId }) {
        result[index].lines.append(line)
      } else {
        result.append((line.paymentMethodId, [line]))
      }
    }
    return result
  }

  private func amount(_ value: AmountE4, _ line: FundingLine) -> String {
    let text = environment.money.rounded(value, currency: line.currency)
    guard line.withoutRate else { return text }
    return text + " " + environment.language("funding.withoutRate", table: "Planning")
  }

  private func name(_ id: UUID?) -> String {
    guard let id, let method = methods.first(where: { $0.id == id }) else {
      return environment.language("funding.noMethod", table: "Planning")
    }
    return method.name
  }
}

/// «оплачено операцией 14.09 — «аренда» 30,000 ₽»: due dates an ordinary operation pays by
/// matching them. «Привязать» ties the operation to the due date for good, as «Провести»
/// would have written it; «Это другое» says the operation is not this payment, and the due
/// date waits for its payment again. Each is one step of ⌘Z.
private struct MatchedDues: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let status: ScheduledStatus

  /// The latest ones: a payment paid by hand for a year lists its last few, and says how
  /// many more there are.
  private static let shown = 3

  var body: some View {
    let dues = status.matchedDues.keys.sorted(by: >)
    if !dues.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(dues.prefix(Self.shown), id: \.self) { due in
          if let operationId = status.matchedDues[due] {
            line(due: due, operationId: operationId)
          }
        }
        if dues.count > Self.shown {
          Text(
            verbatim: environment.language.format(
              "scheduled.matchedMore", table: "Planning", dues.count - Self.shown)
          )
          .appFont(.caption)
          .foregroundStyle(.tertiary)
        }
      }
    }
  }

  private func line(due: DateOnly, operationId: UUID) -> some View {
    let entry = compute.snapshot?.ledger.entry(operationId)
    // Read out of the row, each button says which payment and which due date it is about.
    let context = "\(status.payment.name), \(environment.dates.dayAndMonth(due))"
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      Label {
        Text(verbatim: text(due: due, entry: entry))
      } icon: {
        Image(systemName: "checkmark.circle")
      }
      .foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Button(t("scheduled.bind")) {
        if let dependencies {
          PlanningActions(dependencies).bind(operationId, to: status.payment, due: due)
        }
      }
      .help(t("scheduled.bindHint"))
      .accessibilityLabel(Text(verbatim: "\(t("scheduled.bind")): \(context)"))
      Button(t("scheduled.notThis")) {
        if let dependencies {
          PlanningActions(dependencies).reject(operationId, for: status.payment, due: due)
        }
      }
      .help(t("scheduled.notThisHint"))
      .accessibilityLabel(Text(verbatim: "\(t("scheduled.notThis")): \(context)"))
    }
    .buttonStyle(.link)
    .appFont(.caption)
  }

  private func text(due: DateOnly, entry: TransactionEntry?) -> String {
    let what =
      entry.map { entry in
        let note = entry.transaction.note.flatMap { $0.isEmpty ? nil : "«\($0)» " } ?? ""
        return note
          + environment.money.exact(
            entry.transaction.amountE4, currency: entry.transaction.currency)
          + " · "
          + environment.dates.dayAndMonth(
            environment.calendar.day(of: entry.transaction.occurredAt))
      } ?? "—"
    return environment.format(
      "scheduled.paidByOperation", table: "Planning", environment.dates.dayAndMonth(due), what)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

extension ScheduledPayment {
  /// The page «Отменить подписку» opens, from the address as the owner typed it: «netflix.com»
  /// is how an address is usually written, and a URL without a scheme opens nothing, so it
  /// gets «https://». Only a web page or a letter is opened — a file or another app's scheme,
  /// which an imported book could carry, is not a link.
  var cancelLink: URL? {
    guard let text = cancelURL?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    let lowered = text.lowercased()
    if lowered.hasPrefix("mailto:") { return URL(string: text) }
    if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
      return URL(string: text).flatMap { $0.host?.isEmpty == false ? $0 : nil }
    }
    if text.contains("://") { return nil }
    return URL(string: "https://" + text).flatMap { $0.host?.isEmpty == false ? $0 : nil }
  }
}

// MARK: - The tax of self-employment

/// «Налог НПД за октябрь ≈ X до 28 ноября» and «Налог УСН за III квартал 2026 ≈ X до 28
/// октября» with «Заплатить…»: lines worked out from the tax of self-employment, not scheduled
/// payments — their money is already in the line «Налог самозанятого» of the free sum, so it is
/// never held back twice. The tax on professional income by the month, a tax at another rate by
/// the quarter (`TaxQuarter`): each one over and unpaid, then the one under way while it has a
/// tax; only that one cannot be paid yet.
struct NPDPaymentRows: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let months: [NPDMonth]
  var quarters: [TaxQuarter] = []
  @State private var paying: PayingMonth?
  @State private var payingQuarter: PayingQuarter?

  var body: some View {
    ForEach(quarters, id: \.paymentKey) { quarter in
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: quarter.state == .overdue ? "exclamationmark.circle" : "doc.text")
          .accessibilityLabel(
            Text(
              verbatim: environment.language(
                quarter.state == .overdue ? "planning.overdue" : "scheduled.npd.symbol",
                table: "Planning")))
        Text(verbatim: Self.text(quarter, environment))
          .monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 6)
        if quarter.state != .accruing {
          Button(environment.language("npd.pay.open", table: "Allocation")) {
            payingQuarter = PayingQuarter(quarter: quarter)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("scheduled.tax.pay")
        }
      }
      .appFont(.callout)
      .accessibilityIdentifier("scheduled.tax")
      Divider()
    }
    .sheet(item: $payingQuarter) { paying in
      NPDPaymentSheet(quarter: paying.quarter)
        .handingOver(dependencies)
    }
    ForEach(months, id: \.month) { month in
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: month.state == .overdue ? "exclamationmark.circle" : "doc.text")
          .accessibilityLabel(
            Text(
              verbatim: environment.language(
                month.state == .overdue ? "planning.overdue" : "scheduled.npd.symbol",
                table: "Planning")))
        Text(verbatim: Self.text(month, environment))
          .monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 6)
        if month.state != .accruing {
          Button(environment.language("npd.pay.open", table: "Allocation")) {
            paying = PayingMonth(month: month)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("scheduled.npd.pay")
        }
      }
      .appFont(.callout)
      .accessibilityIdentifier("scheduled.npd")
      Divider()
    }
    .sheet(item: $paying) { paying in
      NPDPaymentSheet(month: paying.month)
        .handingOver(dependencies)
    }
  }

  /// «Налог НПД за октябрь ≈ 4,800 ₽ до 28 ноября»; the month under way «≈ … пока».
  static func text(_ month: NPDMonth, _ environment: AppEnvironment) -> String {
    environment.format(
      month.state == .accruing ? "scheduled.npd.accruing" : "scheduled.npd",
      table: "Planning", PlanningText.monthInSentence(month.month, environment),
      environment.money.rounded(month.toPayE4), environment.dates.dayAndMonth(month.due))
  }

  /// «Налог УСН за III квартал 2026 ≈ 10,200 ₽ до 28 октября»; the quarter under way «≈ … пока».
  static func text(_ quarter: TaxQuarter, _ environment: AppEnvironment) -> String {
    environment.format(
      quarter.state == .accruing ? "scheduled.tax.accruing" : "scheduled.tax",
      table: "Planning", quarterName(quarter, environment),
      environment.money.rounded(quarter.toPayE4), environment.dates.dayAndMonth(quarter.due))
  }

  /// «III квартал 2026», «Q3 2026».
  static func quarterName(_ quarter: TaxQuarter, _ environment: AppEnvironment) -> String {
    environment.format(
      "scheduled.tax.quarter.\(quarter.quarter)", table: "Planning", String(quarter.year))
  }

  /// The quarters of a tax at another rate the block lists: over and unpaid with something to
  /// pay, then the quarter under way while it has a tax. None while self-employment is off.
  static func quarterRows(npd: NPDState?) -> [TaxQuarter] {
    guard let npd else { return [] }
    return npd.quarters.filter { quarter in
      guard quarter.toPayE4.raw > 0 else { return false }
      switch quarter.state {
      case .due, .overdue, .accruing: return true
      case .paid: return false
      }
    }
  }

  /// The months the block lists: over and unpaid with something to pay, then today's month
  /// while it has a tax. None while self-employment is off. The tax of the other rates is not
  /// in them: it is paid by the quarter (`quarterRows`).
  static func rows(npd: NPDState?, categories: [CoreKit.Category], today: DateOnly) -> [NPDMonth] {
    guard let npd else { return [] }
    return npd.months.filter { month in
      guard month.toPayE4.raw > 0 else { return false }
      switch month.state {
      case .due, .overdue: return true
      case .accruing: return month.month == today.monthKey
      case .carried, .paid: return false
      }
    }
  }
}
