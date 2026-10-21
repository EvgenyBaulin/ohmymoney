import AppCore
import SwiftUI

/// Why the terms of a credit card were not saved. Nothing is written then.
enum CreditTermsIssue: Error, Hashable, Sendable {
  /// The limit does not read as an amount above zero.
  case limit
  /// A rate does not read as a percent above zero and up to 100.
  case rate
  /// The minimum payment does not read: a percent above zero and up to 100, a sum not below
  /// zero.
  case minimum
  /// The fee of cash does not read: a percent from zero up to 100, a sum not below zero.
  case fee
  /// The day of the statement is not 1…31, the days to pay not 1…60, the days from a purchase
  /// not 1…366.
  case days
}

/// «Кредитная карта» of the account editor, as typed until «Сохранить»: whether the account is a
/// credit card and its terms — the limit, the grace period («выписка N-го, оплатить за M дней»
/// as Т-Банк, or «N дней с первой покупки»), the rates of purchases and of cash, the minimum
/// payment, the fee of cash and «снятие и переводы без льготного периода». Everything is in the
/// main currency of the account.
struct CreditDraft: Equatable {
  enum GraceKind: String, CaseIterable, Hashable {
    case statement
    case fromPurchase
  }

  var isOn: Bool
  var limitText: String
  var graceKind: GraceKind
  var statementDay: Int
  var payDays: Int
  var purchaseDays: Int
  var purchaseRateText: String
  var cashRateText: String
  var minPercentText: String
  var minFloorText: String
  var feePercentText: String
  var feeFixedText: String
  var cashWithoutGrace: Bool

  /// The days to pay a statement in, unless the owner says otherwise: Т-Банк gives 25.
  static let defaultPayDays = 25

  init(_ terms: CreditCardTerms?) {
    isOn = terms != nil
    limitText = terms.map { Self.text($0.limitE4) } ?? ""
    switch terms?.grace ?? .statement(day: 1, payDays: Self.defaultPayDays) {
    case .statement(let day, let pay):
      graceKind = .statement
      statementDay = day
      payDays = pay
      purchaseDays = 100
    case .fromPurchase(let days):
      graceKind = .fromPurchase
      statementDay = 1
      payDays = Self.defaultPayDays
      purchaseDays = days
    }
    purchaseRateText = terms?.purchaseRate.map(Self.text) ?? ""
    cashRateText = terms?.cashRate.map(Self.text) ?? ""
    minPercentText = terms?.minPercent.map(Self.text) ?? ""
    minFloorText = terms?.minFloorE4.map(Self.text) ?? ""
    feePercentText = terms?.cashFeePercent.map(Self.text) ?? ""
    feeFixedText = terms?.cashFeeFixedE4.map(Self.text) ?? ""
    cashWithoutGrace = terms?.cashWithoutGrace ?? false
  }

  /// The terms the draft saves: `nil` with the switch off, or why they cannot be saved. An empty
  /// field is a term not said.
  func terms() -> Result<CreditCardTerms?, CreditTermsIssue> {
    guard isOn else { return .success(nil) }
    guard let limit = Self.amount(limitText), limit.raw > 0 else { return .failure(.limit) }
    let grace: CreditGrace
    switch graceKind {
    case .statement:
      guard (1...31).contains(statementDay), (1...60).contains(payDays) else {
        return .failure(.days)
      }
      grace = .statement(day: statementDay, payDays: payDays)
    case .fromPurchase:
      guard (1...366).contains(purchaseDays) else { return .failure(.days) }
      grace = .fromPurchase(days: purchaseDays)
    }
    guard let purchaseRate = Self.rate(purchaseRateText), let cashRate = Self.rate(cashRateText)
    else { return .failure(.rate) }
    guard let minPercent = Self.rate(minPercentText), let minFloor = Self.sum(minFloorText)
    else { return .failure(.minimum) }
    guard let feePercent = Self.percent(feePercentText), let feeFixed = Self.sum(feeFixedText)
    else { return .failure(.fee) }
    return .success(
      CreditCardTerms(
        limitE4: limit, grace: grace, purchaseRate: purchaseRate.value, cashRate: cashRate.value,
        minPercent: minPercent.value, minFloorE4: minFloor.value,
        cashFeePercent: feePercent.value, cashFeeFixedE4: feeFixed.value,
        cashWithoutGrace: cashWithoutGrace))
  }

  // MARK: Reading the fields

  /// A field that may be left empty: `.some(nil)` — not said; `nil` — does not read.
  struct Said<Value> {
    var value: Value?
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespaces)
  }

  /// A rate of a year, above zero and up to 100 %: «29,9», «29.9 %».
  static func rate(_ text: String) -> Said<Decimal>? {
    guard !trimmed(text).isEmpty else { return Said(value: nil) }
    guard let rate = DebtPayoff.parseRate(text), rate > 0, rate <= 100 else { return nil }
    return Said(value: rate)
  }

  /// A percent of a fee, from zero up to 100.
  static func percent(_ text: String) -> Said<Decimal>? {
    guard !trimmed(text).isEmpty else { return Said(value: nil) }
    guard let rate = DebtPayoff.parseRate(text), rate >= 0, rate <= 100 else { return nil }
    return Said(value: rate)
  }

  /// A sum not below zero.
  static func sum(_ text: String) -> Said<AmountE4>? {
    guard !trimmed(text).isEmpty else { return Said(value: nil) }
    guard let amount = amount(text), amount.raw >= 0 else { return nil }
    return Said(value: amount)
  }

  /// An amount read by the rule of every amount field: «150,000», «150к» is not, a formula is.
  static func amount(_ text: String) -> AmountE4? {
    let text = trimmed(text)
    guard !text.isEmpty, let value = try? ExpressionEvaluator.evaluate(text) else { return nil }
    return try? AmountE4(decimal: value)
  }

  static func text(_ amount: AmountE4) -> String {
    NumberText.decimal(amount.decimal, fractionDigits: 0...2)
  }

  static func text(_ value: Decimal) -> String {
    NumberText.decimal(value, fractionDigits: 0...4)
  }
}

/// «Кредитная карта» in the editor of an account: «Это кредитная карта», then the limit, the
/// grace period, the rates, the minimum payment, the fee of cash and its switch. The footer says
/// the card is kept as an account below zero, not as a debt.
struct AccountCreditSection: View {
  @Dependency(\.environment) private var environment
  @Binding var draft: CreditDraft
  /// The main currency of the account: every term is in it.
  let currency: CurrencyCode

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    Section {
      Toggle(isOn: $draft.isOn) {
        Text(verbatim: t("account.credit.toggle"))
      }
      .accessibilityIdentifier("account.credit.toggle")
      if draft.isOn {
        amountField(
          "account.credit.limit", text: $draft.limitText, prompt: "150000",
          identifier: "account.credit.limit")
        Picker(selection: $draft.graceKind) {
          Text(verbatim: t("account.credit.grace.statement")).tag(CreditDraft.GraceKind.statement)
          Text(verbatim: t("account.credit.grace.fromPurchase"))
            .tag(CreditDraft.GraceKind.fromPurchase)
        } label: {
          Text(verbatim: t("account.credit.grace"))
        }
        .accessibilityIdentifier("account.credit.grace")
        switch draft.graceKind {
        case .statement:
          Picker(selection: $draft.statementDay) {
            ForEach(1...31, id: \.self) { day in
              Text(verbatim: day == 31 ? t("account.credit.dayLast") : "\(day)").tag(day)
            }
          } label: {
            Text(verbatim: t("account.credit.statementDay"))
          }
          Stepper(value: $draft.payDays, in: 1...60) {
            Text(
              verbatim: environment.format(
                "account.credit.payDays", table: AccountText.table, "\(draft.payDays)"))
          }
        case .fromPurchase:
          Stepper(value: $draft.purchaseDays, in: 1...366) {
            Text(
              verbatim: environment.format(
                "account.credit.purchaseDays", table: AccountText.table,
                "\(draft.purchaseDays)"))
          }
        }
        percentField(
          "account.credit.purchaseRate", text: $draft.purchaseRateText, prompt: "29.9",
          identifier: "account.credit.purchaseRate")
        percentField(
          "account.credit.cashRate", text: $draft.cashRateText, prompt: "49.9",
          identifier: "account.credit.cashRate")
        percentField(
          "account.credit.minPercent", text: $draft.minPercentText, prompt: "8",
          identifier: "account.credit.minPercent")
        amountField(
          "account.credit.minFloor", text: $draft.minFloorText, prompt: "600",
          identifier: "account.credit.minFloor")
        percentField(
          "account.credit.feePercent", text: $draft.feePercentText, prompt: "2.9",
          identifier: "account.credit.feePercent")
        amountField(
          "account.credit.feeFixed", text: $draft.feeFixedText, prompt: "290",
          identifier: "account.credit.feeFixed")
        Toggle(isOn: $draft.cashWithoutGrace) {
          Text(verbatim: t("account.credit.cashWithoutGrace"))
        }
        .accessibilityIdentifier("account.credit.cashWithoutGrace")
      }
    } header: {
      Text(verbatim: t("account.credit.title"))
    } footer: {
      Text(
        verbatim: draft.isOn
          ? environment.format("account.credit.hint", table: AccountText.table, currency.code)
          : t("account.credit.offHint")
      )
      .foregroundStyle(.secondary)
    }
  }

  private func amountField(
    _ key: String, text: Binding<String>, prompt: String, identifier: String
  ) -> some View {
    LabeledContent {
      HStack(spacing: 4) {
        TextField(text: text, prompt: Text(verbatim: prompt)) { Text(verbatim: t(key)) }
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .appFont(.body.monospacedDigit())
          .frame(width: 120)
          .accessibilityIdentifier(identifier)
        Text(verbatim: currency.code).foregroundStyle(.secondary)
      }
    } label: {
      Text(verbatim: t(key))
    }
  }

  private func percentField(
    _ key: String, text: Binding<String>, prompt: String, identifier: String
  ) -> some View {
    LabeledContent {
      HStack(spacing: 4) {
        TextField(text: text, prompt: Text(verbatim: prompt)) { Text(verbatim: t(key)) }
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .appFont(.body.monospacedDigit())
          .frame(width: 80)
          .accessibilityIdentifier(identifier)
        Text(verbatim: "%").foregroundStyle(.secondary)
      }
    } label: {
      Text(verbatim: t(key))
    }
  }
}

/// «Основная карта» in the editor of an account with live cards: the card a purchase on the
/// account is made with unless it says otherwise; «Нет» leaves the choice to the one live card,
/// when there is only one.
struct AccountMainCardPicker: View {
  @Dependency(\.environment) private var environment
  @Binding var selection: UUID?
  /// The live cards of the account, in list order.
  let cards: [PaymentCard]

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    Section {
      Picker(selection: $selection) {
        Text(verbatim: t("account.mainCard.none")).tag(UUID?.none)
        ForEach(cards) { card in
          Text(verbatim: card.name).tag(UUID?.some(card.id))
        }
      } label: {
        Text(verbatim: t("account.mainCard"))
      }
      .accessibilityIdentifier("account.editor.mainCard")
    } footer: {
      Text(verbatim: t("account.mainCard.hint"))
        .foregroundStyle(.secondary)
    }
  }
}

extension CreditTermsIssue {
  var messageKey: String {
    switch self {
    case .limit: "account.credit.refusal.limit"
    case .rate: "account.credit.refusal.rate"
    case .minimum: "account.credit.refusal.minimum"
    case .fee: "account.credit.refusal.fee"
    case .days: "account.credit.refusal.days"
    }
  }
}
