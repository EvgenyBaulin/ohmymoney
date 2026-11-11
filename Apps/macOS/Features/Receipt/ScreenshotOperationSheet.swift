import AppCore
import Foundation
import SwiftUI
import Vision

/// Text recognition supplies editable facts; matching and its tolerances belong to the core.
enum ScreenshotText {
  static func read(_ data: Data) -> String {
    guard let image = ReceiptQRDetector.image(from: data) else { return "" }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ru-RU", "en-US"]
    guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil
    else { return "" }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}

struct ScreenshotOperationSheet: View {
  let data: Data?
  let onOpen: (UUID) -> Void
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  @State private var amount = ""
  @State private var currency = "RUB"
  @State private var kind: TransactionKind = .expense
  @State private var account: UUID?
  @State private var moment = Date()
  @State private var hasTime = false
  @State private var reading = true

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: t("screenshot.title")).appFont(.headline)
      Text(verbatim: t("screenshot.confirmFacts")).appFont(.callout).foregroundStyle(.secondary)
      if reading { ProgressView() }
      Form {
        TextField(t("screenshot.amount"), text: $amount)
          .accessibilityIdentifier("screenshot.amount")
        TextField(t("screenshot.currency"), text: $currency)
        Picker(t("screenshot.kind"), selection: $kind) {
          ForEach(TransactionKind.allCases, id: \.self) { value in
            Text(verbatim: environment.language("kind.\(value.rawValue)"))
              .tag(value)
          }
        }
        Picker(t("screenshot.account"), selection: $account) {
          Text(verbatim: t("screenshot.chooseAccount")).tag(Optional<UUID>.none)
          ForEach(accounts) { value in
            Text(verbatim: value.name).tag(Optional(value.id))
          }
        }
        DatePicker(t("screenshot.date"), selection: $moment, displayedComponents: .date)
        Toggle(t("screenshot.hasTime"), isOn: $hasTime)
        if hasTime {
          DatePicker(t("screenshot.time"), selection: $moment, displayedComponents: .hourAndMinute)
        }
      }
      .appFont(.body)
      if let proposal {
        Text(
          verbatim: t(
            proposal.matches.isEmpty
              ? (hasTime ? "screenshot.none" : "screenshot.needsTime")
              : proposal.isSimilar ? "screenshot.similar" : "screenshot.exact")
        )
        .appFont(.callout)
        .accessibilityIdentifier("screenshot.matchTier")
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(proposal.matches) { candidate in
              Button {
                onOpen(candidate.id)
              } label: {
                HStack {
                  Text(
                    verbatim: environment.dates.dayAndMonth(
                      environment.calendar.day(
                        of: candidate.occurredAt, recordedIn: candidate.timeZoneID)))
                  Text(verbatim: title(candidate))
                  Spacer()
                  Text(
                    verbatim: environment.money.exact(
                      candidate.amount,
                      currency: candidate.currency))
                  if proposal.isSimilar { Text(verbatim: t("screenshot.similar")) }
                }
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("screenshot.match.\(candidate.id)")
            }
          }
          .appFont(.callout)
        }
      }
      HStack {
        Spacer()
        Button(environment.language("import.close", table: "Import")) { dismiss() }
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 520, idealWidth: 600, minHeight: 440, idealHeight: 560)
    .task {
      moment = environment.calendar.moment(environment.today, hour: 12, minute: 0)
      defer { reading = false }
      guard let data else { return }
      let text = await Task.detached(priority: .userInitiated) { ScreenshotText.read(data) }.value
      guard let message = BankTextParser().parse(text, today: environment.today) else { return }
      amount = CSVValue.string(amount: message.money.amount)
      currency = message.money.currency.code
      kind = message.kind
      hasTime = message.time != nil
      moment = environment.calendar.moment(
        message.day ?? environment.today,
        hour: message.time?.hour ?? 12, minute: message.time?.minute ?? 0)
      if let tail = message.cardLast4 {
        let cards =
          compute.snapshot?.dataset.cards.filter { $0.last4 == tail && !$0.archived } ?? []
        let ids = Set(cards.map(\.accountId))
        if ids.count == 1, let only = ids.first, accounts.contains(where: { $0.id == only }) {
          account = only
        }
      }
    }
    .accessibilityIdentifier("screenshot.search")
  }

  private var accounts: [PaymentMethod] {
    (compute.snapshot?.dataset.paymentMethods ?? []).filter {
      !$0.archived && compute.snapshot?.hiding.isHidden($0.id) != true
    }
  }

  private var proposal: ScreenshotProposal? {
    guard let account, let snapshot = compute.snapshot,
      let parsed = try? ExpressionEvaluator.evaluate(amount), parsed > 0,
      let money = try? AmountE4(decimal: parsed)
    else { return nil }
    let candidates = ScreenshotMatch.candidates(
      entries: snapshot.dataset.entries,
      transfers: snapshot.dataset.transfers)
    return ScreenshotMatch.propose(
      amount: money, kind: kind,
      currency: CurrencyCode(currency.uppercased()), accountID: account,
      day: environment.calendar.day(of: moment),
      time: hasTime ? environment.calendar.timeOfDay(moment) : nil,
      among: candidates, calendar: environment.calendar)
  }

  private func title(_ candidate: ScreenshotCandidate) -> String {
    if candidate.isTransfer {
      return compute.snapshot?.dataset.transfers.first { $0.id == candidate.id }?.note
        ?? t("screenshot.transfer")
    }
    return compute.snapshot?.ledger.entry(candidate.id)?.transaction.note
      ?? environment.language("receipt.operation.generic", table: "Receipt")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Receipt") }
}
