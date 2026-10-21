import AppCore
import SwiftUI

/// What «Платежи и подписки» of an account's screen shows: the payments paid from the account
/// or any of its cards — on the main account also those that name none —, by the next due date.
struct AccountPaymentsModel: Equatable {
  struct Row: Equatable, Identifiable {
    var status: ScheduledStatus
    /// The card the payment names; `nil` — the account itself.
    var cardName: String?
    /// The card it names is in the archive: «Провести» goes to the account alone.
    var cardArchived: Bool
    var id: UUID { status.id }
  }

  var rows: [Row]

  init(accountId: UUID, statuses: [ScheduledStatus], cards: [PaymentCard], mainAccountId: UUID?) {
    let byId = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    rows = AccountPayments.on(accountId, statuses: statuses, mainAccountId: mainAccountId).map {
      status in
      let card = status.payment.cardId.flatMap { byId[$0] }
      return Row(status: status, cardName: card?.name, cardArchived: card?.archived == true)
    }
  }

  /// A short list opens by itself; a long one waits to be opened.
  var opensByItself: Bool { rows.count <= 5 }
}

/// «Платежи и подписки» of an account's screen: the next due date («просрочен» when it passed),
/// the name, the card it is paid with, the amount. A double click or «Изменить…» opens the
/// payment's form; «Добавить платёж…» starts one paid from this account.
struct AccountPaymentsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let accountId: UUID

  @State private var sheet: PlanningSheet?
  @State private var expanded: Bool?

  private func t(_ key: String) -> String { environment.language(key, table: CardText.table) }

  private var model: AccountPaymentsModel? {
    guard let snapshot = compute.snapshot else { return nil }
    let dataset = snapshot.dataset
    return AccountPaymentsModel(
      accountId: accountId, statuses: snapshot.planning.scheduled, cards: dataset.cards,
      mainAccountId: dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id)
  }

  var body: some View {
    let model = self.model
    VStack(alignment: .leading, spacing: 8) {
      DisclosureGroup(
        isExpanded: Binding(
          get: { expanded ?? model?.opensByItself ?? true }, set: { expanded = $0 })
      ) {
        VStack(alignment: .leading, spacing: 6) {
          if let model, model.rows.isEmpty {
            Text(verbatim: t("account.screen.paymentsNone")).foregroundStyle(.secondary)
          }
          ForEach(model?.rows ?? []) { row in
            rowView(row)
          }
        }
        .padding(.top, 4)
      } label: {
        Text(verbatim: t("account.screen.payments")).appFont(.headline)
      }
      Button {
        sheet = Self.newPaymentSheet(
          on: accountId, accounts: compute.snapshot?.dataset.paymentMethods ?? [],
          defaultCurrency: environment.defaultCurrency, today: environment.today)
      } label: {
        Label {
          Text(verbatim: t("account.screen.paymentAdd"))
        } icon: {
          Image(systemName: "plus")
        }
      }
      .accessibilityIdentifier("account.payments.add")
    }
    .contentCard()
    .sheet(item: $sheet) { sheet in
      PlanningSheetView(sheet: sheet).handingOver(dependencies)
    }
  }

  /// The form «Добавить платёж…» opens: a new payment as Planning starts one — due today, in
  /// the default currency — paid from this account and in its main currency. The currency is
  /// not the owner's pick yet, so another account picked in the form moves it.
  static func newPaymentSheet(
    on accountId: UUID, accounts: [PaymentMethod], defaultCurrency: CurrencyCode, today: DateOnly
  ) -> PlanningSheet {
    var payment = ScheduledPaymentForm.newPayment(defaultCurrency: defaultCurrency, today: today)
    if let account = accounts.first(where: { $0.id == accountId }) {
      payment = ScheduledPaymentForm.picking(
        account, for: payment, currencyChosen: false, defaultCurrency: defaultCurrency)
    } else {
      payment.paymentMethodId = accountId
    }
    return .newPayment(payment, currencyChosen: false)
  }

  private func rowView(_ row: AccountPaymentsModel.Row) -> some View {
    let status = row.status
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      if status.isOverdue {
        Label {
          Text(verbatim: PlanningText.t("planning.overdue", environment))
        } icon: {
          Image(systemName: "exclamationmark.circle")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      Text(
        verbatim: status.nextUnpaid.year == environment.today.year
          ? environment.dates.dayAndMonth(status.nextUnpaid)
          : environment.dates.longDay(status.nextUnpaid)
      )
      .monospacedDigit()
      .foregroundStyle(status.isOverdue ? .primary : .secondary)
      .frame(minWidth: 52, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: status.payment.name).lineLimit(1)
        if row.cardArchived {
          Label {
            Text(verbatim: t("account.screen.paymentCardArchived"))
          } icon: {
            Image(systemName: "archivebox")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        } else if let name = row.cardName {
          Label {
            Text(
              verbatim: environment.format(
                "account.screen.paymentCard", table: CardText.table, name))
          } icon: {
            Image(systemName: "creditcard")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(
        verbatim: environment.money.exact(status.amountNext, currency: status.payment.currency)
      )
      .monospacedDigit()
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { sheet = .payment(status.payment) }
    .contextMenu {
      Button(environment.language("action.edit")) { sheet = .payment(status.payment) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAction(named: Text(verbatim: environment.language("action.edit"))) {
      sheet = .payment(status.payment)
    }
  }
}
