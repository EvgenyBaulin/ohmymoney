import AppCore
import SwiftUI

/// What the editor adds for a purchase: the discount, the answer to «Не пожалели?», the day a
/// refund is waited for and the mileage of a fill-up. Each row shows only for the operations
/// that have it, and an empty field saves as none.
enum PurchaseFieldRules {
  /// The words that make a category a fuel one, in the names of both languages.
  private static let fuelWords = ["топлив", "бензин", "заправ", "fuel", "petrol", "gasoline"]

  /// Whether a name speaks of fuel.
  static func isFuelName(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return fuelWords.contains { lowered.contains($0) }
  }

  /// Whether the purchase is a fill-up: a part in a fuel category (or under one), or a note that
  /// names litres.
  static func isFillUp(_ draft: TransactionDraft, tree: CategoryTree) -> Bool {
    guard draft.kind == .expense else { return false }
    if FuelEconomy.liters(inNote: draft.note) != nil { return true }
    return draft.parts.contains { part in
      let category = tree.category(part.categoryId)
      let parent = tree.parent(of: part.categoryId)
      return [category?.name, parent?.name].contains { $0.map(isFuelName) ?? false }
    }
  }

  /// A saved purchase can be asked about: the panel offers the answer to a purchase the owner
  /// edits, never to a new line.
  static func showsRegret(_ draft: TransactionDraft, editsSaved: Bool) -> Bool {
    editsSaved && draft.kind == .expense
  }

  static func showsDiscount(_ draft: TransactionDraft) -> Bool { draft.kind == .expense }
  static func showsWaitingRefund(_ draft: TransactionDraft) -> Bool { draft.kind == .refund }

  /// The answer put on a draft the way `RegretSchedule.recording` puts it on an operation.
  static func answer(_ answer: PurchaseRegret, on draft: inout TransactionDraft, today: DateOnly) {
    draft.regret = answer
    draft.regretAskedOn = today
  }

  /// The text of the mileage field as the draft holds it.
  static func mileageText(_ km: Int?) -> String { km.map(String.init) ?? "" }

  /// The mileage a text says: whole kilometres above zero, spaces and thousands marks allowed.
  static func mileage(from text: String) -> Int? {
    let digits = text.filter(\.isNumber)
    guard !digits.isEmpty, digits.count <= 8, let km = Int(digits), km > 0 else { return nil }
    return km
  }
}

struct PurchaseFields: View {
  @Dependency(\.environment) private var environment
  @Binding var draft: TransactionDraft
  let tree: CategoryTree
  let editsSaved: Bool

  private func t(_ key: String) -> String { PurchaseHookText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if PurchaseFieldRules.showsDiscount(draft) { discountField }
      if PurchaseFieldRules.isFillUp(draft, tree: tree) { mileageField }
      if PurchaseFieldRules.showsWaitingRefund(draft) { refundField }
      if PurchaseFieldRules.showsRegret(draft, editsSaved: editsSaved) { regretBlock }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("entry.purchase")
  }

  private func label(_ key: String) -> some View {
    Text(verbatim: t(key)).appFont(.caption).foregroundStyle(.secondary)
  }

  // MARK: Discount

  private var discountField: some View {
    VStack(alignment: .leading, spacing: 4) {
      label("purchase.discount.title")
      AmountField(
        amount: Binding(
          get: { draft.discountE4 ?? .zero },
          set: { draft.discountE4 = $0.raw > 0 ? $0 : nil })
      )
      .accessibilityIdentifier("entry.discount")
    }
  }

  // MARK: Mileage

  private var mileageField: some View {
    VStack(alignment: .leading, spacing: 4) {
      label("purchase.mileage.title")
      TextField(
        text: Binding(
          get: { PurchaseFieldRules.mileageText(draft.odometerKm) },
          set: { draft.odometerKm = PurchaseFieldRules.mileage(from: $0) }),
        prompt: Text(verbatim: t("purchase.mileage.prompt"))
      ) {
        Text(verbatim: t("purchase.mileage.title"))
      }
      .labelsHidden()
      .monospacedDigit()
      .accessibilityIdentifier("entry.mileage")
    }
  }

  // MARK: A refund that is waited for

  private var refundField: some View {
    VStack(alignment: .leading, spacing: 4) {
      label("purchase.refund.title")
      HStack(spacing: 6) {
        if draft.refundWaitingUntil != nil {
          DatePicker(
            selection: Binding(
              get: {
                environment.calendar.startOfDay(draft.refundWaitingUntil ?? environment.today)
              },
              set: { draft.refundWaitingUntil = environment.calendar.day(of: $0) }),
            displayedComponents: .date
          ) {
            Text(verbatim: t("purchase.refund.title"))
          }
          .labelsHidden()
          .accessibilityIdentifier("entry.refundWaiting.date")
          Button(t("purchase.refund.credited")) {
            draft.refundWaitingUntil = nil
          }
          .accessibilityIdentifier("entry.refundWaiting.credited")
        } else {
          Button(t("purchase.refund.pick")) {
            draft.refundWaitingUntil = environment.calendar.adding(days: 7, to: environment.today)
          }
          .accessibilityIdentifier("entry.refundWaiting.pick")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  // MARK: «Не пожалели?»

  private var regretBlock: some View {
    VStack(alignment: .leading, spacing: 4) {
      label("purchase.regret.title")
      if let answered = draft.regret {
        HStack(spacing: 6) {
          Label(t("purchase.regret.answered.\(answered.rawValue)"), systemImage: symbol(answered))
            .appFont(.callout)
          Button(t("purchase.regret.change")) {
            draft.regret = nil
            draft.regretAskedOn = nil
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("entry.regret.change")
        }
      } else {
        FlowRow(spacing: 6, lineSpacing: 6) {
          answerButton(.no, "purchase.regret.no")
          answerButton(.yes, "purchase.regret.yes")
          answerButton(.skip, "purchase.regret.skip")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
    .accessibilityIdentifier("entry.regret")
  }

  private func symbol(_ answer: PurchaseRegret) -> String {
    switch answer {
    case .no: "hand.thumbsup"
    case .yes: "hand.thumbsdown"
    case .skip: "bell.slash"
    }
  }

  private func answerButton(_ answer: PurchaseRegret, _ key: String) -> some View {
    Button(t(key)) {
      PurchaseFieldRules.answer(answer, on: &draft, today: environment.today)
    }
    .accessibilityIdentifier("entry.regret.\(answer.rawValue)")
  }
}
