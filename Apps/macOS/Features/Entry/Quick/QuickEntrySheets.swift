import AppCore
import SwiftUI

/// Presents the sheets quick entry asks for, on the entry bar: the list pasted from the bank,
/// «повторить вчера», the drafts, which card some digits are, and the reconciliation a pasted
/// balance offered. The bar adds this once.
struct QuickEntrySheets: ViewModifier {
  @Bindable var model: QuickEntryModel
  @Binding var text: String
  @Environment(\.dependencies) private var dependencies
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute

  func body(content: Content) -> some View {
    content
      .sheet(item: $model.billList) { list in
        BillListSheet(list: list) { chosen in
          let drafts = model.drafts(for: chosen, environment: environment, compute: compute)
          let result = model.write(drafts, environment: environment, store: store)
          reportWritten(result)
        }
        .handingOver(dependencies)
      }
      .sheet(item: $model.repeatRequest) { request in
        RepeatSheet(request: request) { chosen in
          let result = model.write(
            chosen.filter(\.isSelected).map(\.draft), environment: environment, store: store)
          reportWritten(result)
        }
        .handingOver(dependencies)
      }
      .sheet(isPresented: $model.showsDrafts) {
        DraftsSheet(model: model.drafts) { draft in
          text = draft.text
          model.drafts.finishing = draft.id
          model.showsDrafts = false
        }
        .handingOver(dependencies)
      }
      .sheet(item: $model.cardAsk) { ask in
        CardAskSheet(ask: ask) { card in
          rememberDigits(ask.last4, on: card)
        }
        .handingOver(dependencies)
      }
      .sheet(isPresented: $model.showsReconcile) {
        ReconcileSheet().handingOver(dependencies)
      }
      .onReceive(NotificationCenter.default.publisher(for: .openDrafts)) { _ in
        model.drafts.reload()
        model.showsDrafts = true
      }
  }

  private func reportWritten(_ result: (written: Int, left: Int)) {
    if result.written > 0 {
      model.notice = QuickText.counted("quick.repeat.written", environment, result.written)
      model.failure = nil
    } else {
      model.failure = "quick.repeat.none"
    }
    if result.left > 0 {
      model.failure = "quick.repeat.left"
    }
  }

  /// The answer to «какая это карта?»: the digits are kept on the card, once, and the line
  /// names the card from now on.
  private func rememberDigits(_ last4: String, on card: PaymentCard) {
    var changed = card
    changed.last4 = last4
    let actions = CardActions(environment: environment, store: store)
    guard actions.save(changed, previous: card) == .done else {
      model.failure = "quick.draft.failed"
      return
    }
    if var offer = model.bank, offer.question == .unknown(last4: last4) {
      let named = offer.line + " " + card.name
      let parsed = model.parser(environment).parse(named, today: environment.today)
      if parsed.cardId == card.id {
        offer.line = named
        text = named
      }
      offer.question = .none
      model.bank = offer
    }
  }
}

extension View {
  func quickEntrySheets(_ model: QuickEntryModel, text: Binding<String>) -> some View {
    modifier(QuickEntrySheets(model: model, text: text))
  }
}

// MARK: - A list pasted from the bank

/// The operations of a pasted list, each with a tick; those the ledger already has are unticked
/// and say so. «Записать» writes the ticked ones as one step of ⌘Z.
struct BillListSheet: View {
  @State var list: QuickEntryModel.BillList
  let write: ([BankImportCandidate]) -> Void
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let ticked = list.candidates.filter(\.isSelected).count
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: QuickText.t("quick.bills.title", environment)).appFont(.headline)
      Text(verbatim: QuickText.t("quick.bills.subtitle", environment))
        .appFont(.callout).foregroundStyle(.secondary)
      List {
        ForEach(list.candidates.indices, id: \.self) { index in
          row(index)
        }
      }
      .frame(minHeight: 180)
      if list.skipped > 0 {
        Label {
          Text(verbatim: QuickText.counted("quick.bills.skipped", environment, list.skipped))
        } icon: {
          Image(systemName: "questionmark.circle")
        }
        .appFont(.caption).foregroundStyle(.secondary)
      }
      Text(verbatim: QuickText.t("quick.bills.categoryNote", environment))
        .appFont(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(QuickText.counted("quick.bills.write", environment, ticked)) {
          write(list.candidates)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(ticked == 0)
        .accessibilityIdentifier("quick.bills.write")
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 460)
  }

  private func row(_ index: Int) -> some View {
    let candidate = list.candidates[index]
    let message = candidate.message
    return Toggle(
      isOn: Binding(
        get: { list.candidates[index].isSelected },
        set: { list.candidates[index].isSelected = $0 })
    ) {
      HStack(spacing: 8) {
        Text(verbatim: QuickBillText.title(of: message))
          .lineLimit(1)
        if candidate.isDuplicate {
          Label {
            Text(verbatim: QuickText.t("quick.bills.duplicate", environment))
          } icon: {
            Image(systemName: "doc.on.doc")
          }
          .appFont(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 6)
        Text(
          verbatim: QuickBillText.amount(of: message, environment)
        )
        .monospacedDigit()
      }
    }
    .toggleStyle(.checkbox)
  }
}

enum QuickBillText {
  static func title(of message: BankMessage) -> String {
    if let merchant = message.merchant, !merchant.isEmpty { return merchant }
    return message.source
  }

  /// «−1,250 ₽» for spending, «+85,000 ₽» for income, the minus U+2212.
  @MainActor
  static func amount(of message: BankMessage, _ environment: AppEnvironment) -> String {
    let sign: String
    switch message.kind {
    case .expense: sign = "\u{2212}"
    case .income, .refund, .reimbursement: sign = "+"
    }
    return sign + environment.money.exact(message.money.amount, currency: message.money.currency)
  }
}

// MARK: - Repeat yesterday

struct RepeatSheet: View {
  @State var request: QuickEntryModel.RepeatRequest
  let write: ([RepeatProposal]) -> Void
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let ticked = request.proposals.filter(\.isSelected).count
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: QuickText.t("quick.repeat.title", environment)).appFont(.headline)
      Text(
        verbatim: QuickText.f(
          "quick.repeat.subtitle", environment, environment.dates.longDay(request.day))
      )
      .appFont(.callout).foregroundStyle(.secondary)
      List {
        ForEach($request.proposals) { $proposal in
          Toggle(isOn: $proposal.isSelected) {
            HStack {
              Text(verbatim: proposal.draft.note ?? QuickText.t("quick.operation", environment))
                .lineLimit(1)
              Spacer(minLength: 6)
              Text(
                verbatim: environment.money.exact(
                  proposal.draft.amount, currency: proposal.draft.currency)
              )
              .monospacedDigit()
            }
          }
          .toggleStyle(.checkbox)
        }
      }
      .frame(minHeight: 160)
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(QuickText.counted("quick.repeat.write", environment, ticked)) {
          write(request.proposals)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(ticked == 0)
        .accessibilityIdentifier("quick.repeat.write")
      }
    }
    .padding(20)
    .sheetFrame(width: 480, height: 420)
  }
}

// MARK: - Drafts

struct DraftsSheet: View {
  let model: DraftsModel
  let finish: (PendingDraft) -> Void
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let waiting = model.waiting
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: QuickText.t("quick.drafts.title", environment)).appFont(.headline)
      Text(verbatim: QuickText.t("quick.drafts.hint", environment))
        .appFont(.callout).foregroundStyle(.secondary)
      if waiting.isEmpty {
        Text(verbatim: QuickText.t("quick.drafts.empty", environment))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 80)
      } else {
        List(waiting) { draft in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: draft.text).lineLimit(2)
              Text(
                verbatim: environment.dates.longDay(environment.calendar.day(of: draft.createdAt))
              )
              .appFont(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button(QuickText.t("quick.drafts.finish", environment)) { finish(draft) }
              .controlSize(.small)
            Button(QuickText.t("quick.drafts.delete", environment), role: .destructive) {
              model.resolve(draft.id)
            }
            .controlSize(.small)
          }
        }
        .frame(minHeight: 160)
      }
      HStack {
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 480, height: 380)
    .onAppear { model.reload() }
  }
}

// MARK: - Which card has these digits

struct CardAskSheet: View {
  let ask: QuickEntryModel.CardAsk
  let choose: (PaymentCard) -> Void
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let cards = (compute.snapshot?.dataset.cards ?? []).filter { !$0.archived }
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: QuickText.f("quick.cardAsk.title", environment, ask.last4))
        .appFont(.headline)
      Text(verbatim: QuickText.t("quick.cardAsk.message", environment))
        .appFont(.callout).foregroundStyle(.secondary)
      List(cards) { card in
        Button {
          choose(card)
          dismiss()
        } label: {
          HStack {
            Image(systemName: "creditcard")
            Text(verbatim: card.name)
            Spacer(minLength: 6)
            if let masked = CardDetails(last4: card.last4).masked {
              Text(verbatim: masked).foregroundStyle(.secondary).monospacedDigit()
            }
          }
        }
        .buttonStyle(.plain)
      }
      .frame(minHeight: 140)
      HStack {
        Spacer()
        Button(QuickText.t("quick.cardAsk.none", environment), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 360)
  }
}
