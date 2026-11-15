import AppCore
import SwiftUI

/// «Оформлен: дата и сумма» of a loan as a form holds it: off — neither is said; on — the day the
/// loan was taken out, today until changed, and what was borrowed then, a sum of zero as not said.
/// Both are optional and neither moves money: the balance the books began with stays the first
/// line of the journal.
struct DebtOpeningDraft: Hashable {
  var known = false
  var day: DateOnly?
  var amount: AmountE4 = .zero

  init() {}

  /// What `debt` says already: on when either half is there.
  init(debt: Debt) {
    known = debt.openedOn != nil || debt.originalAmountE4 != nil
    day = debt.openedOn
    amount = debt.originalAmountE4 ?? .zero
  }

  /// Only a loan I owe has an opening: what «Капитал» counts back from.
  static func applies(to debt: Debt) -> Bool { debt.direction == .iOwe && debt.type == .loan }

  /// A sum below zero is never saved; the form says nothing is wrong otherwise.
  var isValid: Bool { !known || !amount.isNegative }

  /// `debt` with the opening the form holds: both halves when on, neither when off. A debt that
  /// is no loan I owe is left as it is: the form shows it no opening to change.
  func applied(to debt: Debt, today: DateOnly) -> Debt {
    guard Self.applies(to: debt) else { return debt }
    var debt = debt
    if known {
      debt.openedOn = day ?? today
      debt.originalAmountE4 = amount.raw > 0 ? amount : nil
    } else {
      debt.openedOn = nil
      debt.originalAmountE4 = nil
    }
    return debt
  }
}

/// The rows of «Оформлен: дата и сумма»: a switch, then the day and the sum in the currency of
/// the debt. Shared by «Новый долг», the form of a new debt and «График…» of a loan.
struct DebtOpeningFields: View {
  @Dependency(\.environment) private var environment
  @Binding var draft: DebtOpeningDraft
  let currency: CurrencyCode

  var body: some View {
    Toggle(t("opening.known"), isOn: $draft.known)
      .accessibilityIdentifier("debt.opening.known")
    if draft.known {
      DatePicker(
        t("opening.day"),
        selection: Binding(
          get: { environment.calendar.noon(of: draft.day ?? environment.today) },
          set: { draft.day = environment.calendar.day(of: $0) }),
        displayedComponents: .date)
      LabeledContent(t("opening.amount")) {
        HStack {
          AmountField(amount: $draft.amount)
          Text(verbatim: currency.code).foregroundStyle(.secondary)
        }
      }
      .accessibilityIdentifier("debt.opening.amount")
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
