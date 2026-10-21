import AppCore
import SwiftUI

/// An account as the editor holds it until «Сохранить»: its name and kind, the bank it is under,
/// its currencies in order — the first is the main one —, its group, whether it is main, its
/// other names and the balances typed for currencies never counted.
struct AccountDraft: Equatable {
  var id: UUID
  var name: String
  var kind: PaymentMethodKind
  /// The first is the main currency: an operation in a currency the account does not hold is
  /// charged in it.
  var currencies: [CurrencyCode]
  var groupId: UUID?
  /// The bank the account is under; `nil`: a bank of its own, a new one named `newBankName` —
  /// like the account when that is empty — or the live bank of that name.
  var bankId: UUID?
  var newBankName = ""
  var isMain: Bool
  var aliases: [String]
  /// «Остаток сейчас», as typed, by currency; an empty field counts nothing.
  var openings: [CurrencyCode: String] = [:]
  /// «Проценты»: the interest the balance earns, as typed.
  var interest = InterestDraft(nil)
  /// «Деньги подушки безопасности»: the money of the account, every currency of it, is the
  /// owner's safety cushion.
  var cushion = false
  /// «Кредитная карта»: the terms of a credit card, as typed.
  var credit = CreditDraft(nil)
  /// «Основная карта»: the card a purchase on the account is made with unless it says
  /// otherwise; `nil` — none chosen.
  var mainCardId: UUID?

  /// The fields of an account there is.
  init(_ account: PaymentMethod) {
    id = account.id
    name = account.name
    kind = account.kind
    currencies = account.currencies
    groupId = account.groupId
    bankId = account.bankId
    isMain = account.isDefault
    aliases = account.aliases
    interest = InterestDraft(account.interest)
    cushion = account.cushion
    credit = CreditDraft(account.credit)
    mainCardId = account.mainCardId
  }

  /// A new account: a bank account in the default currency, in no group, under a bank — `bank`
  /// when it is given (an account added from a bank), else a new one.
  init(newIn currency: CurrencyCode, kind: PaymentMethodKind = .card, bank: UUID? = nil) {
    id = UUID()
    name = ""
    self.kind = kind
    currencies = [currency]
    groupId = nil
    bankId = bank
    isMain = false
    aliases = []
  }

  /// The account the draft saves, over `previous` so what the editor does not show — the
  /// place in the list, the archive — stays as it was. The interest is laid on it apart, once
  /// it reads (`InterestDraft.terms(accountId:)`).
  func account(over previous: PaymentMethod?) -> PaymentMethod {
    var account =
      previous ?? PaymentMethod(id: id, name: name)
    account.name = name
    account.kind = kind
    account.currency = currencies.first
    account.otherCurrencies = Array(currencies.dropFirst())
    account.groupId = groupId
    account.bankId = bankId
    account.isDefault = isMain
    account.aliases = aliases
    account.cushion = cushion
    account.mainCardId = mainCardId
    return account
  }

  mutating func add(_ currency: CurrencyCode) {
    guard !currencies.contains(currency) else { return }
    currencies.append(currency)
  }

  /// Takes a currency off; the last one stays — an account holds at least its main currency.
  mutating func remove(_ currency: CurrencyCode) {
    guard currencies.count > 1 else { return }
    currencies.removeAll { $0 == currency }
    openings[currency] = nil
  }

  /// The currency becomes the first, the main one; the others keep their order.
  mutating func makeMain(_ currency: CurrencyCode) {
    guard let index = currencies.firstIndex(of: currency), index > 0 else { return }
    currencies.insert(currencies.remove(at: index), at: 0)
  }

  /// One place up (`by: -1`) or down (`by: 1`).
  mutating func move(_ currency: CurrencyCode, by step: Int) {
    guard let index = currencies.firstIndex(of: currency) else { return }
    let target = index + step
    guard currencies.indices.contains(target) else { return }
    currencies.swapAt(index, target)
  }

  /// The balances typed, read as amounts: an empty field is left out, a field that does not
  /// read is refused by its currency.
  func typedOpenings() -> Result<[CurrencyCode: AmountE4], AccountRefusal> {
    var result: [CurrencyCode: AmountE4] = [:]
    for currency in currencies {
      let text = (openings[currency] ?? "").trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      // Read by the rule of every amount field: «1,500» is 1 500, «1,5» is 1.5, a formula
      // counts.
      guard let value = try? ExpressionEvaluator.evaluate(text),
        let amount = try? AmountE4(decimal: value)
      else {
        return .failure(.unreadableBalance(currency))
      }
      result[currency] = amount
    }
    return .success(result)
  }

  /// Enter writes the balance back the way the app writes amounts. A zero typed stays «0»: an
  /// empty field is «не знаю» and counts nothing, so zero must not be written back as empty.
  @MainActor mutating func settleOpening(_ currency: CurrencyCode) {
    guard let text = openings[currency], let settled = BalanceField.settledText(text)
    else { return }
    openings[currency] = settled
  }
}

/// The form of one account, new or there already: name, kind, currencies in order, group,
/// «Основной счёт», other names and, for a currency never counted, «Остаток сейчас». Shown
/// as a sheet from the settings and from the sidebar; «Сохранить» is one step of ⌘Z.
struct AccountEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  /// `nil` for a new account.
  let previous: PaymentMethod?
  /// Called once the sheet is done with: the id of the account saved or brought back from the
  /// archive, `nil` when nothing was written.
  let finish: (UUID?) -> Void

  @State private var draft: AccountDraft
  @State private var books: AccountBooks?
  @State private var groups: [AccountGroup] = []
  @State private var banks: [Bank] = []
  /// Every account, for «Куда» of the interest.
  @State private var accounts: [PaymentMethod] = []
  @State private var enabled: [CurrencyCode] = []
  /// The live cards of the account, for «Основная карта».
  @State private var cards: [PaymentCard] = []
  @State private var refusal: AccountRefusal?
  @State private var failed = false

  /// `bank`: the bank a new account is added to, from the menu of a bank.
  init(
    previous: PaymentMethod?, defaultCurrency: CurrencyCode, bank: UUID? = nil,
    finish: @escaping (UUID?) -> Void
  ) {
    self.previous = previous
    self.finish = finish
    _draft = State(
      initialValue: previous.map(AccountDraft.init)
        ?? AccountDraft(newIn: defaultCurrency, bank: bank))
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(previous == nil ? "account.editor.newTitle" : "account.editor.title"))
        .appFont(.headline)
      Form {
        NameField(
          title: t("account.editor.name"), text: $draft.name, identifier: "account.editor.name")
        Picker(selection: $draft.kind) {
          ForEach(PaymentMethodKind.allCases, id: \.self) { kind in
            Text(verbatim: t(AccountText.kindKey(kind))).tag(kind)
          }
        } label: {
          Text(verbatim: t("account.editor.kind"))
        }
        bankSection
        currenciesSection
        Section {
          Picker(selection: $draft.groupId) {
            Text(verbatim: t("account.editor.noGroup")).tag(UUID?.none)
            ForEach(groupChoices, id: \.id) { group in
              Text(verbatim: AccountText.groupTitle(group, environment)).tag(UUID?.some(group.id))
            }
          } label: {
            Text(verbatim: t("account.editor.group"))
          }
          Toggle(isOn: $draft.isMain) {
            Text(verbatim: t("account.editor.main"))
          }
          .disabled(wasMain || previous?.archived == true)
        } footer: {
          Text(verbatim: t(wasMain ? "account.editor.mainStays" : "account.editor.mainHint"))
            .foregroundStyle(.secondary)
        }
        if !cards.isEmpty {
          AccountMainCardPicker(selection: $draft.mainCardId, cards: cards)
        }
        AccountCreditSection(
          draft: $draft.credit, currency: draft.currencies.first ?? .rub)
        AccountInterestSection(draft: $draft.interest, payoutChoices: payoutChoices)
        Section {
          Toggle(isOn: $draft.cushion) {
            Text(verbatim: t("account.editor.cushion"))
          }
          .accessibilityIdentifier("account.editor.cushion")
        } footer: {
          Text(verbatim: t("account.editor.cushionHint"))
            .foregroundStyle(.secondary)
        }
        Section {
          AccountOtherNames(names: $draft.aliases)
        } header: {
          Text(verbatim: t("account.editor.otherNames"))
        } footer: {
          Text(verbatim: t("account.editor.otherNamesHint"))
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      if let refusal {
        AccountRefusalNote(refusal: refusal, restore: restoreFromArchive)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(nil) }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(books == nil || store.isWritingInBackground)
      }
    }
    .padding(20)
    // No taller than the settings window it hangs from (620 points as it opens): a sheet taller
    // than that went past the bottom of the window, and of a smaller screen, with the fields
    // below. The form scrolls inside instead.
    .sheetFrame(width: 480)
    .frame(minHeight: 420, idealHeight: 600, maxHeight: 700)
    .task {
      groups = actions.groups
      banks = actions.banks
      accounts = actions.all
      enabled = actions.enabledCurrencies
      cards = CardRules.ordered(
        actions.cards.filter { !$0.archived }, of: draft.id, locale: environment.language.locale)
      if draft.mainCardId != nil, !cards.contains(where: { $0.id == draft.mainCardId }) {
        draft.mainCardId = nil
      }
      books = await actions.books()
      // Without the books nothing can be checked or saved: said, not a greyed button alone.
      if books == nil { failed = true }
    }
    .onChange(of: draft) { _, _ in refusal = nil }
    .refusedWriteAlert($failed, environment)
  }

  // MARK: The bank

  /// The bank the account is under: one of the live banks, or a new one, called like the account
  /// unless the owner names it. The bank the account is in is offered even from the archive.
  private var bankSection: some View {
    Section {
      Picker(selection: $draft.bankId) {
        Text(verbatim: t("account.editor.bank.new")).tag(UUID?.none)
        ForEach(bankChoices, id: \.id) { bank in
          Text(verbatim: bank.name).tag(UUID?.some(bank.id))
        }
      } label: {
        Text(verbatim: t("account.editor.bank"))
      }
      .accessibilityIdentifier("account.editor.bank")
      if draft.bankId == nil {
        NameField(
          title: t("account.editor.bank.newName"), text: $draft.newBankName,
          prompt: draft.name.trimmingCharacters(in: .whitespaces),
          identifier: "account.editor.newBankName")
      }
    } footer: {
      Text(
        verbatim: t(
          draft.bankId == nil ? "account.editor.bank.newHint" : "account.editor.bank.hint")
      )
      .foregroundStyle(.secondary)
    }
  }

  /// The live banks, and the one the account is in even when it is in the archive.
  private var bankChoices: [Bank] {
    banks.filter { !$0.archived || $0.id == draft.bankId }
      .sorted { BankRules.precedes($0, $1, locale: environment.language.locale) }
  }

  // MARK: Currencies

  private var currenciesSection: some View {
    Section {
      ForEach(Array(draft.currencies.enumerated()), id: \.element) { index, currency in
        currencyRow(currency, isMain: index == 0, index: index)
        if countsOpening(currency) {
          LabeledContent {
            TextField(
              text: Binding(
                get: { draft.openings[currency] ?? "" },
                set: { draft.openings[currency] = $0 })
            ) {
              // Empty means not counted — no starting point —, which is not a zero balance.
              Text(verbatim: t("account.editor.notCounted"))
            }
            .appFont(.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 140)
            .onSubmit { draft.settleOpening(currency) }
          } label: {
            Text(
              verbatim: environment.format(
                "account.editor.balanceNow", table: "Accounts", currency.code))
          }
        }
      }
      // A balance may be below zero: a credit card owes the bank.
      if draft.currencies.contains(where: countsOpening) {
        Text(verbatim: t("account.balance.creditHint"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Menu {
        ForEach(addable, id: \.code) { currency in
          Button(currency.code) { draft.add(currency) }
        }
      } label: {
        Label {
          Text(verbatim: t("account.editor.addCurrency"))
        } icon: {
          Image(systemName: "plus")
        }
      }
      .disabled(addable.isEmpty)
    } header: {
      Text(verbatim: t("account.editor.currencies"))
    } footer: {
      Text(verbatim: t("account.editor.currenciesHint"))
        .foregroundStyle(.secondary)
    }
  }

  private func currencyRow(_ currency: CurrencyCode, isMain: Bool, index: Int) -> some View {
    let locked = hasMoney(currency)
    let unknown = locked && books?.isUnknown(key(currency)) == true
    return HStack(spacing: 8) {
      Text(verbatim: currency.code)
        .appFont(.body.monospaced())
      Text(verbatim: environment.money.symbol(for: currency))
        .foregroundStyle(.secondary)
      if isMain {
        Text(verbatim: t("account.editor.mainCurrency"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if locked {
        // Said in words, not only by a greyed button: money in this currency keeps it here —
        // or a balance nobody knows yet, which is not called money.
        Label {
          Text(
            verbatim: t(
              unknown ? "account.editor.currencyBalanceUnknown" : "account.editor.currencyHasMoney"
            ))
        } icon: {
          Image(systemName: "lock")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      Menu {
        if !isMain {
          Button(t("account.editor.makeMainCurrency")) { draft.makeMain(currency) }
        }
        Button(t("account.editor.up")) { draft.move(currency, by: -1) }
          .disabled(index == 0)
        Button(t("account.editor.down")) { draft.move(currency, by: 1) }
          .disabled(index == draft.currencies.count - 1)
        Divider()
        Button(t("account.editor.removeCurrency"), role: .destructive) { draft.remove(currency) }
          .disabled(locked || draft.currencies.count == 1)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: t("account.editor.currencyMenu")))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  /// Currencies switched on that the account does not hold yet.
  private var addable: [CurrencyCode] {
    enabled.filter { !draft.currencies.contains($0) }
  }

  /// Where the interest may go besides this account: the other live accounts, and the one it
  /// goes to now even from the archive, named as every list names them.
  private var payoutChoices: [AccountCardChoices.Item] {
    let offered = AccountRules.ordered(
      accounts.filter {
        $0.id != draft.id && (!$0.archived || $0.id == draft.interest.payoutAccountId)
      }, locale: environment.language.locale, includeArchived: true)
    return AccountCardChoices.accountItems(
      accounts: offered, banks: banks, among: accounts.filter { !$0.archived },
      locale: environment.language.locale)
  }

  /// The groups to file it under: the live ones, and the one it is in even when archived.
  private var groupChoices: [AccountGroup] {
    groups.filter { !$0.archived || $0.id == draft.groupId }
  }

  private var wasMain: Bool { previous?.isDefault == true && previous?.archived == false }

  private func key(_ currency: CurrencyCode) -> BalanceKey {
    BalanceKey(accountId: draft.id, currency: currency)
  }

  /// Money on the account in this currency: it cannot be taken off.
  private func hasMoney(_ currency: CurrencyCode) -> Bool {
    guard previous != nil, let books else { return false }
    return books.hasMoney(key(currency))
  }

  /// A currency never counted and never moved asks for its balance now.
  private func countsOpening(_ currency: CurrencyCode) -> Bool {
    guard let books else { return false }
    return !books.balances.hasHistory(key(currency))
  }

  // MARK: Saving

  private func save() {
    guard let books else { return }
    guard !draft.currencies.isEmpty else {
      refusal = .noCurrency
      return
    }
    let openings: [CurrencyCode: AmountE4]
    switch draft.typedOpenings() {
    case .success(let typed): openings = typed
    case .failure(let reason):
      refusal = reason
      return
    }
    var account = draft.account(over: previous)
    switch draft.interest.terms(accountId: draft.id) {
    case .success(let terms): account.interest = terms
    case .failure(let issue):
      refusal = .interest(issue)
      return
    }
    switch draft.credit.terms() {
    case .success(let terms): account.credit = terms
    case .failure(let issue):
      refusal = .credit(issue)
      return
    }
    switch actions.save(
      account, previous: previous, openings: openings, books: books,
      newBankNamed: draft.bankId == nil ? draft.newBankName : nil)
    {
    case .done:
      Self.logCushion(of: account, previous: previous)
      finish(account.id)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }

  /// A saved account that became or stopped being money of the cushion is said in the journal,
  /// by count only.
  static func logCushion(of account: PaymentMethod, previous: PaymentMethod?) {
    guard account.cushion != (previous?.cushion ?? false) else { return }
    AppLog.info(
      "cushion.accounts.changed", .db, "an account of the safety cushion changed",
      [LogPair("accounts", .count(1)), LogPair("cushion", .flag(account.cushion))])
  }

  /// A new account named like one in the archive: that one comes back instead of a second
  /// account with the same name.
  private func restoreFromArchive(_ id: UUID) {
    switch actions.restore(id) {
    case .done: finish(id)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}

/// A name field of a grouped form: its label on the left as before, its text read from the left.
/// The form puts the text of a labelled field on the right, where a space typed last — «Сбер. » —
/// shows only once the next letter comes, as if it had not been typed; the alignment of the text
/// is taken back only from a field whose own label is hidden, so the label is drawn beside it.
/// VoiceOver still hears the field by `title`. Amounts stay on the right, under each other.
struct NameField: View {
  let title: String
  @Binding var text: String
  /// The grey text of an empty field.
  var prompt: String? = nil
  /// How a UI test finds the field.
  let identifier: String

  var body: some View {
    LabeledContent {
      TextField(text: $text, prompt: prompt.map { Text(verbatim: $0) }) {
        Text(verbatim: title)
      }
      .labelsHidden()
      .multilineTextAlignment(.leading)
      .accessibilityIdentifier(identifier)
    } label: {
      Text(verbatim: title)
    }
  }
}

/// The other names of an account or of a card, one row each with ×, and a field to add one: the
/// entry line knows the account by any of them («Т-Банк» — «тинькофф», «тинек»), and a card too,
/// putting the operation on the card's account («кофе 300 виртуалка»).
struct AccountOtherNames: View {
  @Dependency(\.environment) private var environment
  @Binding var names: [String]
  @State private var typed = ""

  var body: some View {
    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
      HStack {
        Text(verbatim: name)
        Spacer()
        Button {
          names.remove(at: index)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .accessibilityLabel(
              Text(verbatim: environment.language("account.editor.removeName", table: "Accounts")))
        }
        .buttonStyle(.borderless)
      }
    }
    HStack {
      NameField(
        title: environment.language("account.editor.newName", table: "Accounts"), text: $typed,
        identifier: "account.editor.newOtherName"
      )
      .onSubmit(add)
      Button(environment.language("action.add"), action: add)
        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  private func add() {
    let name = typed.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }
    let key = AccountActions.folded(name)
    if !names.contains(where: { AccountActions.folded($0) == key }) { names.append(name) }
    typed = ""
  }
}
