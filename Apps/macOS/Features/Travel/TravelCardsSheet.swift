import AppCore
import AppDatabase
import SwiftUI

/// What a card costs abroad as the owner types it from the tariff of the bank: the fields as
/// text, an empty one meaning «not typed» (and 0 meaning a fee of nothing), read into
/// `CardForeignTerms` once they all make sense.
struct CardForeignDraft: Equatable {
  var conversionFee = ""
  var atmFeePercent = ""
  var atmFeeFixed = ""
  var atmFeeFixedCurrency = ""

  init() {}

  init(_ terms: CardForeignTerms) {
    conversionFee = terms.conversionFee.map { Self.text($0.decimal) } ?? ""
    atmFeePercent = terms.atmFeePercent.map { Self.text($0.decimal) } ?? ""
    atmFeeFixed = terms.atmFeeFixed.map { Self.text($0.amount.decimal) } ?? ""
    atmFeeFixedCurrency = terms.atmFeeFixed?.currency.code ?? ""
  }

  /// Why the fields cannot be read, or the terms they make. A percent is 0…100 with at most
  /// four places; a fixed fee is a sum with its currency (three Latin letters) or neither.
  enum Reading: Equatable {
    case terms(CardForeignTerms)
    case badPercent
    case badFixed
  }

  var reading: Reading {
    guard case .some(let conversion) = Self.percent(conversionFee),
      case .some(let atm) = Self.percent(atmFeePercent)
    else { return .badPercent }
    let fixedText = atmFeeFixed.trimmingCharacters(in: .whitespaces)
    let code = atmFeeFixedCurrency.trimmingCharacters(in: .whitespaces).uppercased()
    var fixed: Money?
    if !fixedText.isEmpty || !code.isEmpty {
      guard let amount = DecimalMath.parse(fixedText), amount >= 0,
        let e4 = try? AmountE4(decimal: amount),
        code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter })
      else { return .badFixed }
      fixed = Money(amount: e4, currency: CurrencyCode(code))
    }
    return .terms(
      CardForeignTerms(conversionFee: conversion, atmFeePercent: atm, atmFeeFixed: fixed))
  }

  /// `.none` — unreadable; `.some(nil)` — empty, nothing typed.
  private static func percent(_ text: String) -> CashbackPercent?? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return .some(nil) }
    guard let decimal = DecimalMath.parse(trimmed), let percent = CashbackPercent(decimal: decimal)
    else { return .none }
    return .some(percent)
  }

  private static func text(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
  }
}

/// «Карты за границей»: the fees of each live card from its tariff and, above them, the card
/// that loses least on converting a sum of an example. A card whose conversion fee is not typed
/// takes no part and says «условия не заведены». Nothing is read from past debits.
struct TravelCardsSheet: View {
  /// The sum the cards are compared on, in rubles.
  static let sample = AmountE4(whole: 100_000)

  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  @State private var drafts: [UUID: CardForeignDraft] = [:]
  @State private var refusal: String?

  var body: some View {
    let cards = (compute.snapshot?.dataset.cards ?? []).filter { !$0.archived }
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: TravelText.t("travel.cards.title", environment))
        .appFont(.headline)
        .accessibilityAddTraits(.isHeader)
      comparison(cards)
      List(cards) { card in row(card) }
        .accessibilityIdentifier("travel.cards.list")
      if let refusal {
        Text(verbatim: refusal).appFont(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save")) { save(cards) }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("travel.cards.save")
      }
    }
    .padding(20)
    .sheetFrame(width: 620, height: 520)
    .onAppear {
      for card in cards where drafts[card.id] == nil {
        drafts[card.id] = CardForeignDraft(card.foreign)
      }
    }
  }

  @ViewBuilder
  private func comparison(_ cards: [PaymentCard]) -> some View {
    let typed = cards.map { card -> PaymentCard in
      var card = card
      if case .terms(let terms)? = drafts[card.id]?.reading { card.foreign = terms }
      return card
    }
    let result = TravelCardComparison(cards: typed, sample: Self.sample)
    VStack(alignment: .leading, spacing: 4) {
      if let best = result.best, let fee = best.conversionFee {
        Label {
          Text(
            verbatim: TravelText.format(
              "travel.cards.best", environment, best.name, environment.money.percent(fee),
              environment.money.rounded(Self.sample),
              environment.money.rounded(best.loss ?? .zero)))
        } icon: {
          Image(systemName: "creditcard")
        }
        .accessibilityIdentifier("travel.cards.best")
      } else {
        Text(verbatim: TravelText.t("travel.cards.noBest", environment))
          .foregroundStyle(.secondary)
      }
      ForEach(result.entries.filter { $0.conversionFee != nil }, id: \.cardId) { entry in
        Text(
          verbatim: TravelText.format(
            "travel.cards.loss", environment, entry.name,
            entry.conversionFee.map(environment.money.percent) ?? "",
            environment.money.rounded(Self.sample), environment.money.rounded(entry.loss ?? .zero))
        )
        .appFont(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
      }
    }
  }

  private func row(_ card: PaymentCard) -> some View {
    let binding = Binding(
      get: { drafts[card.id] ?? CardForeignDraft(card.foreign) },
      set: { drafts[card.id] = $0 })
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(verbatim: card.name).appFont(.headline)
        if binding.wrappedValue.conversionFee.trimmingCharacters(in: .whitespaces).isEmpty {
          Text(verbatim: TravelText.t("travel.cards.notTyped", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      HStack {
        field("travel.cards.fx", binding.conversionFee)
        field("travel.cards.atmPercent", binding.atmFeePercent)
        field("travel.cards.atmFixed", binding.atmFeeFixed)
        field("travel.cards.atmCurrency", binding.atmFeeFixedCurrency, width: 70)
      }
    }
    .padding(.vertical, 4)
  }

  private func field(_ key: String, _ text: Binding<String>, width: CGFloat = 110) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: TravelText.t(key, environment)).appFont(.caption).foregroundStyle(.secondary)
      TextField(text: text) { Text(verbatim: TravelText.t(key, environment)) }
        .labelsHidden()
        .frame(width: width)
        .multilineTextAlignment(.trailing)
    }
  }

  private func save(_ cards: [PaymentCard]) {
    var changes: [(UUID, CardForeignTerms)] = []
    for card in cards {
      let draft = drafts[card.id] ?? CardForeignDraft(card.foreign)
      switch draft.reading {
      case .terms(let terms): if terms != card.foreign { changes.append((card.id, terms)) }
      case .badPercent:
        refusal = TravelText.format("travel.cards.badPercent", environment, card.name)
        return
      case .badFixed:
        refusal = TravelText.format("travel.cards.badFixed", environment, card.name)
        return
      }
    }
    guard let stack = environment.stack else { return }
    let repository = TravelRepository(writer: stack.writer)
    for (id, terms) in changes { try? repository.saveForeignTerms(terms, ofCard: id) }
    compute.refreshLight()
    dismiss()
  }
}
