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

// MARK: - The frame of a sheet of quick entry

/// What the sheets of quick entry share, as the design draws them: the head — the title, a line
/// under it, the cross —, a rule, the body, a rule, and the buttons at the right
/// (`QuickSheetMetrics`). The sheet itself, its corners and its shadow are the system's.
struct QuickSheetFrame<Content: View, Buttons: View>: View {
  let title: String
  var line: String? = nil
  @ViewBuilder let content: () -> Content
  @ViewBuilder let buttons: () -> Buttons
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: QuickSheetMetrics.rowGap) {
        VStack(alignment: .leading, spacing: QuickSheetMetrics.headLineGap) {
          Text(verbatim: title)
            .appFont(QuickSheetType.title)
            .accessibilityIdentifier("quick.sheet.title")
          if let line {
            Text(verbatim: line)
              .appFont(QuickSheetType.line)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .appFont(AppFont.system(size: 10, weight: .semibold))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(environment.language("action.close"))
        .accessibilityLabel(Text(verbatim: environment.language("action.close")))
        .accessibilityIdentifier("quick.sheet.close")
      }
      .padding(.horizontal, QuickSheetMetrics.headHorizontal)
      .padding(.vertical, QuickSheetMetrics.headVertical)
      Divider()
      VStack(alignment: .leading, spacing: QuickSheetMetrics.bodyGap) {
        content()
      }
      .padding(QuickSheetMetrics.body)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      HStack(spacing: QuickSheetMetrics.footGap) {
        Spacer(minLength: 0)
        buttons()
      }
      .padding(.horizontal, QuickSheetMetrics.footHorizontal)
      .padding(.vertical, QuickSheetMetrics.footVertical)
    }
  }
}

/// The rows of a sheet of quick entry in a card rounded 10, 12 at its sides, a rule between two
/// rows; the rows scroll when there are more than the sheet holds.
struct QuickSheetList<Row: View>: View {
  let count: Int
  @ViewBuilder let row: (Int) -> Row
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(0..<count, id: \.self) { index in
          if index > 0 { Divider() }
          row(index)
            .padding(.vertical, QuickSheetMetrics.rowVertical)
        }
      }
      .padding(.horizontal, QuickSheetMetrics.listSide)
    }
    .background(surfaces.card, in: RoundedRectangle(cornerRadius: QuickSheetMetrics.listRadius))
    .overlay(
      RoundedRectangle(cornerRadius: QuickSheetMetrics.listRadius)
        .strokeBorder(surfaces.cardBorder, lineWidth: 1))
  }
}

/// A hint of a sheet of quick entry: a dot and its words, 12 inside a plate rounded 10.
struct QuickSheetHint: View {
  let text: String
  @Environment(\.appTheme) private var theme

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: QuickSheetMetrics.rowGap) {
      Circle()
        .fill(.secondary)
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(verbatim: text)
        .appFont(QuickSheetType.line)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.surfaceSegmented, in: RoundedRectangle(cornerRadius: 10))
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
    QuickSheetFrame(
      title: QuickText.t("quick.bills.title", environment),
      line: QuickText.t("quick.bills.subtitle", environment)
    ) {
      QuickSheetList(count: list.candidates.count) { index in row(index) }
      if list.skipped > 0 {
        Label {
          Text(verbatim: QuickText.counted("quick.bills.skipped", environment, list.skipped))
        } icon: {
          Image(systemName: "questionmark.circle")
        }
        .appFont(QuickSheetType.line).foregroundStyle(.secondary)
      }
      QuickSheetHint(text: QuickText.t("quick.bills.categoryNote", environment))
    } buttons: {
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
    .sheetFrame(width: QuickSheetMetrics.width, height: 460)
  }

  private func row(_ index: Int) -> some View {
    let candidate = list.candidates[index]
    let message = candidate.message
    return Toggle(
      isOn: Binding(
        get: { list.candidates[index].isSelected },
        set: { list.candidates[index].isSelected = $0 })
    ) {
      HStack(spacing: QuickSheetMetrics.rowGap) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: QuickBillText.title(of: message))
            .appFont(QuickSheetType.row)
            .lineLimit(1)
          if candidate.isDuplicate {
            Label {
              Text(verbatim: QuickText.t("quick.bills.duplicate", environment))
            } icon: {
              Image(systemName: "doc.on.doc")
            }
            .appFont(QuickSheetType.rowDetail).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 6)
        Text(verbatim: QuickBillText.amount(of: message, environment))
          .appFont(QuickSheetType.rowFigure)
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
    QuickSheetFrame(title: QuickText.t("quick.drafts.title", environment)) {
      if waiting.isEmpty {
        Text(verbatim: QuickText.t("quick.drafts.empty", environment))
          .appFont(QuickSheetType.row)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 120)
          .accessibilityIdentifier("quick.drafts.empty")
      } else {
        QuickSheetList(count: waiting.count) { index in row(waiting[index]) }
        Text(verbatim: QuickText.t("quick.drafts.hint", environment))
          .appFont(QuickSheetType.line)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } buttons: {
      Button(environment.language("action.close")) { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .sheetFrame(width: QuickSheetMetrics.width, height: waiting.isEmpty ? 275 : 380)
    .onAppear { model.reload() }
  }

  private func row(_ draft: PendingDraft) -> some View {
    HStack(spacing: QuickSheetMetrics.rowGap) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: draft.text)
          .appFont(QuickSheetType.row)
          .lineLimit(2)
        Text(verbatim: environment.dates.longDay(environment.calendar.day(of: draft.createdAt)))
          .appFont(QuickSheetType.rowDetail)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      Button(QuickText.t("quick.drafts.delete", environment), role: .destructive) {
        model.resolve(draft.id)
      }
      .buttonStyle(.borderless)
      .appFont(QuickSheetType.rowDetail)
      Button(QuickText.t("quick.drafts.finish", environment)) { finish(draft) }
        .buttonStyle(.borderless)
        .appFont(QuickSheetType.rowFigure)
        .accessibilityIdentifier("quick.drafts.finish")
    }
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
