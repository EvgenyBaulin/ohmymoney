import AppCore
import AppDatabase
import SwiftUI

/// Why the conditions typed in an editor were not saved: a sum that does not read. Nothing is
/// written then.
enum BankConditionsIssue: Error, Hashable, Sendable {
  case amount
}

/// «Условия банка» of the editor of an account or of a card, as typed until «Сохранить». An empty
/// field is a condition not said; a filled one is an amount not below zero. Nothing here is
/// learned from the bank: the owner types what the bank's own app says.
struct BankConditionsDraft: Equatable {
  var id: UUID
  var freeCash: String
  var freeSbp: String
  var freeInterbank: String
  var serviceSpend: String
  var serviceBalance: String
  var minBalance: String
  var note: String

  init(_ conditions: BankConditions? = nil) {
    id = conditions?.id ?? UUID()
    freeCash = conditions?.freeCashE4.map(CreditDraft.text) ?? ""
    freeSbp = conditions?.freeSbpE4.map(CreditDraft.text) ?? ""
    freeInterbank = conditions?.freeInterbankE4.map(CreditDraft.text) ?? ""
    serviceSpend = conditions?.serviceFreeSpendE4.map(CreditDraft.text) ?? ""
    serviceBalance = conditions?.serviceFreeBalanceE4.map(CreditDraft.text) ?? ""
    minBalance = conditions?.minBalanceE4.map(CreditDraft.text) ?? ""
    note = conditions?.note ?? ""
  }

  /// The conditions the draft saves for a product; one that says nothing is still returned (the
  /// repository deletes the row of a product that states nothing).
  func conditions(
    accountId: UUID, cardId: UUID?, currency: CurrencyCode
  ) -> Result<BankConditions, BankConditionsIssue> {
    guard let cash = CreditDraft.sum(freeCash), let sbp = CreditDraft.sum(freeSbp),
      let interbank = CreditDraft.sum(freeInterbank), let spend = CreditDraft.sum(serviceSpend),
      let balance = CreditDraft.sum(serviceBalance), let minimum = CreditDraft.sum(minBalance)
    else { return .failure(.amount) }
    let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return .success(
      BankConditions(
        id: id, accountId: accountId, cardId: cardId, currency: currency,
        freeCashE4: cash.value, freeSbpE4: sbp.value, freeInterbankE4: interbank.value,
        serviceFreeSpendE4: spend.value, serviceFreeBalanceE4: balance.value,
        minBalanceE4: minimum.value, note: text.isEmpty ? nil : text))
  }

  var isValid: Bool {
    if case .success = conditions(accountId: UUID(), cardId: nil, currency: .rub) { return true }
    return false
  }
}

/// Reading and writing the conditions of a product, off the form.
@MainActor
enum BankConditionsStore {
  /// The row of an account (`card == nil`) or of one of its cards, as the database has it now.
  static func read(
    account: UUID, card: UUID? = nil, _ environment: AppEnvironment
  ) -> BankConditions? {
    (try? environment.bankConditions?.conditions(account: account, card: card)) ?? nil
  }

  /// Writes the row; a row that states nothing deletes the product's row. `false` when the
  /// database refused.
  @discardableResult
  static func write(_ conditions: BankConditions, _ environment: AppEnvironment) -> Bool {
    guard let repository = environment.bankConditions else { return false }
    do {
      try repository.save(conditions)
      AppLog.info(
        "banks.conditions.saved", .db, "the conditions of a bank product were saved",
        [
          LogPair("account", .id(conditions.accountId)),
          LogPair("empty", .flag(conditions.isEmpty)),
        ])
      return true
    } catch {
      AppLog.error(
        "banks.conditions.failed", .db, "the conditions of a bank product were not saved",
        [LogPair("error", .error(error))])
      return false
    }
  }
}

/// «Условия банка» in the editor of an account or a card: the free limits (an account), the
/// spending or the balance that makes the service free, the balance to keep, and a note.
struct BankConditionsSection: View {
  @Dependency(\.environment) private var environment
  @Binding var draft: BankConditionsDraft
  /// The currency of the account: every sum is in it.
  let currency: CurrencyCode
  /// The limits of cash and transfers belong to the account; a card states only service terms.
  let isAccount: Bool

  private func t(_ key: String) -> String { BankText.t(key, environment) }

  var body: some View {
    Section {
      if isAccount {
        field("bank.cond.freeCash", $draft.freeCash)
        if currency == .rub { field("bank.cond.freeSbp", $draft.freeSbp) }
        field("bank.cond.freeInterbank", $draft.freeInterbank)
      }
      field("bank.cond.serviceSpend", $draft.serviceSpend)
      field("bank.cond.serviceBalance", $draft.serviceBalance)
      if isAccount { field("bank.cond.minBalance", $draft.minBalance) }
      NameField(title: t("bank.cond.note"), text: $draft.note, identifier: "bank.cond.note")
      if !draft.isValid {
        Label {
          Text(verbatim: t("bank.cond.invalid"))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
        .appFont(.callout)
      }
    } header: {
      Text(verbatim: t("bank.cond.title"))
    } footer: {
      Text(verbatim: t("bank.cond.hint")).foregroundStyle(.secondary)
    }
  }

  private func field(_ key: String, _ text: Binding<String>) -> some View {
    LabeledContent {
      HStack(spacing: 4) {
        TextField(text: text, prompt: Text(verbatim: "—")) { Text(verbatim: t(key)) }
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .appFont(.body.monospacedDigit())
          .frame(width: 120)
          .accessibilityIdentifier(key)
        Text(verbatim: currency.code).foregroundStyle(.secondary)
      }
    } label: {
      Text(verbatim: t(key))
    }
  }
}

/// «Действует до» of a card: a month and a year, or nothing. The card works to the end of that
/// month.
struct CardExpiryField: View {
  @Dependency(\.environment) private var environment
  @Binding var month: MonthKey?

  private func t(_ key: String) -> String { BankText.t(key, environment) }

  private var years: [Int] {
    let this = environment.today.year
    let chosen = month?.year ?? this
    return Array(min(this - 1, chosen)...max(this + 15, chosen))
  }

  var body: some View {
    Section {
      Toggle(
        isOn: Binding(
          get: { month != nil },
          set: { month = $0 ? MonthKey(year: environment.today.year + 3, month: 12) : nil })
      ) {
        Text(verbatim: t("bank.card.expiresField"))
      }
      .accessibilityIdentifier("card.editor.expires")
      if let current = month {
        Picker(
          selection: Binding(
            get: { current.month }, set: { month = MonthKey(year: current.year, month: $0) })
        ) {
          ForEach(1...12, id: \.self) { value in
            Text(
              verbatim: environment.dates.monthTitle(MonthKey(year: 2000, month: value)).split(
                separator: " "
              ).first.map(String.init) ?? "\(value)"
            ).tag(value)
          }
        } label: {
          Text(verbatim: t("bank.card.expiresMonth"))
        }
        Picker(
          selection: Binding(
            get: { current.year }, set: { month = MonthKey(year: $0, month: current.month) })
        ) {
          ForEach(years, id: \.self) { year in
            Text(verbatim: String(year)).tag(year)
          }
        } label: {
          Text(verbatim: t("bank.card.expiresYear"))
        }
      }
    } footer: {
      Text(verbatim: t("bank.card.expiresHint")).foregroundStyle(.secondary)
    }
  }
}
