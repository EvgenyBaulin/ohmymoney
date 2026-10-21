import AppCore
import SwiftUI

/// The setup of the accounts: banks picked with one click, cash and any other account, the
/// accounts the database already has, and for each its currencies, its group and how much is on
/// it now — a field left empty is «не знаю», and a credit card's balance may go below zero.
/// «Готово» writes it all at once; «Позже» (Esc) puts it off with a main account made when there
/// is none. Neither is a step of ⌘Z.
///
/// Plain system controls in a form: this is content, not a floating control, so no glass.
struct AccountSetupSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var model: AccountSetupModel?
  @State private var otherName = ""
  @State private var groupName = ""
  @State private var failureKey: String?
  @State private var isWriting = false
  /// The accounts or the balances expected could not be read: nothing is counted until a
  /// read succeeds — a key counted before would be taken for zero.
  @State private var readFailed = false

  private func t(_ key: String) -> String { environment.language(key, table: "Onboarding") }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: t("onboarding.title"))
          .appFont(.title2.bold())
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: t("onboarding.intro"))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding([.horizontal, .top], 20)
      .padding(.bottom, 8)

      if model != nil {
        form
      } else if readFailed {
        Spacer()
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      footer
    }
    .sheetFrame(width: 720, height: 700)
    .task { await read() }
  }

  /// The accounts, then what the books expect for the keys counted before.
  private func read() async {
    readFailed = false
    if model == nil { model = AccountSetupModel.load(from: environment) }
    guard model != nil,
      let expected = await AccountSetupExpectations.load(from: environment, at: Date())
    else {
      readFailed = true
      return
    }
    model?.setExpected(expected)
  }

  // MARK: The form

  private var form: some View {
    Form {
      quickPick
      ForEach(model?.accounts ?? []) { account in
        accountSection(account)
      }
      if model?.leavesAccountsUncounted == true {
        Section {
          Label {
            Text(verbatim: t("onboarding.emptyBalances"))
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "info.circle")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      groupsSection
      mainSection
    }
    .formStyle(.grouped)
  }

  private var quickPick: some View {
    Section {
      ForEach(BankCatalog.Country.allCases, id: \.self) { country in
        LabeledContent {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
            alignment: .leading, spacing: 6
          ) {
            ForEach(BankCatalog.banks(in: country)) { bank in
              bankToggle(bank)
            }
          }
        } label: {
          Text(verbatim: t(country.nameKey))
        }
      }
      LabeledContent {
        HStack(spacing: 8) {
          let cash = t("onboarding.cash")
          Button {
            model?.addAccount(name: cash, kind: .cash)
          } label: {
            Label {
              Text(verbatim: cash)
            } icon: {
              Image(systemName: "banknote")
            }
          }
          // Cash under the name of either language is that cash: «Cash» of a database kept
          // in English is not added again as «Наличные».
          .disabled(model?.lists(names: BankCatalog.cashNames + [cash]) ?? true)
          TextField(text: $otherName, prompt: Text(verbatim: t("onboarding.other.placeholder"))) {
            Text(verbatim: t("onboarding.other.placeholder"))
          }
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .onSubmit(addOther)
          Button(t("onboarding.other.add"), action: addOther)
            .disabled(otherName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      } label: {
        Text(verbatim: t("onboarding.other"))
      }
    } header: {
      Text(verbatim: t("onboarding.quickPick"))
    }
  }

  /// A bank as a toggle button: pressed and ticked once its account is listed. An account the
  /// database already has cannot be taken away here.
  private func bankToggle(_ bank: BankCatalog.Bank) -> some View {
    let listed = model?.lists(bank) ?? false
    let stored = listed && !(model?.accounts.contains { $0.isNew && lists(bank, $0) } ?? false)
    return Toggle(
      isOn: Binding(
        get: { listed },
        set: { _ in
          model?.toggle(
            bank, languageCode: environment.language.resolvedCode,
            countryName: t(bank.country.nameKey))
        })
    ) {
      Label {
        Text(verbatim: bank.name(languageCode: environment.language.resolvedCode))
      } icon: {
        Image(systemName: listed ? "checkmark" : "plus")
      }
    }
    .toggleStyle(.button)
    .disabled(stored)
  }

  private func lists(_ bank: BankCatalog.Bank, _ account: AccountSetupModel.Account) -> Bool {
    bank.names.contains { AccountSetupModel.nameKey($0) == AccountSetupModel.nameKey(account.name) }
  }

  private func addOther() {
    guard model?.addAccount(name: otherName, kind: .card) != nil else { return }
    otherName = ""
  }

  // MARK: One account

  private func accountSection(_ account: AccountSetupModel.Account) -> some View {
    Section {
      TextField(text: accountBinding(account.id, \.name, "")) {
        Text(verbatim: t("onboarding.account.name"))
      }
      Picker(selection: accountBinding(account.id, \.kind, .card)) {
        ForEach(PaymentMethodKind.allCases, id: \.self) { kind in
          Text(verbatim: t("onboarding.kind.\(kind.rawValue)")).tag(kind)
        }
      } label: {
        Text(verbatim: t("onboarding.account.kind"))
      }
      Picker(selection: accountBinding(account.id, \.groupId, nil)) {
        Text(verbatim: t("onboarding.group.none")).tag(UUID?.none)
        ForEach(model?.groups ?? []) { group in
          Text(verbatim: group.name).tag(UUID?.some(group.id))
        }
      } label: {
        Text(verbatim: t("onboarding.account.group"))
      }
      ForEach(Array(account.currencies.enumerated()), id: \.element) { index, currency in
        currencyRow(account, currency, isMain: index == 0)
      }
      if account.kind == .card {
        // What a credit card holds is typed as what is owed, with a minus.
        Text(verbatim: environment.language("account.balance.creditHint", table: "Accounts"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Menu {
          ForEach(model?.addableCurrencies(to: account.id) ?? [], id: \.self) { currency in
            Button {
              model?.addCurrency(currency, to: account.id)
            } label: {
              Text(verbatim: currency.code)
            }
          }
        } label: {
          Text(verbatim: t("onboarding.currency.add"))
        }
        .fixedSize()
        Spacer()
        if account.isNew {
          Button(role: .destructive) {
            model?.removeAccount(account.id)
          } label: {
            Text(verbatim: t("onboarding.account.remove"))
          }
        } else {
          Text(verbatim: t("onboarding.account.existing"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      HStack(spacing: 6) {
        Text(verbatim: account.name.isEmpty ? t("onboarding.account.unnamed") : account.name)
        if model?.mainId == account.id {
          // The main account is told by a symbol and a word, never by colour alone.
          Label {
            Text(verbatim: t("onboarding.main.badge"))
          } icon: {
            Image(systemName: "star.fill")
          }
          .labelStyle(.titleAndIcon)
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func currencyRow(
    _ account: AccountSetupModel.Account, _ currency: CurrencyCode, isMain: Bool
  ) -> some View {
    let key = account.key(currency)
    return LabeledContent {
      HStack(spacing: 8) {
        // Empty is «не знаю»; a key counted before shows what the books expect instead, and
        // left empty it keeps its count.
        BalanceField(
          amount: Binding(
            get: { model?.balance(key) },
            set: { model?.setBalance($0, for: key) }),
          placeholder: model?.expected[key].map { BalanceField.text(for: $0) }
            ?? t("onboarding.balance.unknown")
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 150)
        // The label of the row does not reach a field among several views: named here, it is
        // not read out as its placeholder.
        .accessibilityLabel(
          Text(
            verbatim: environment.format("onboarding.balance", table: "Onboarding", currency.code)
          ))
        Text(verbatim: environment.money.symbol(for: currency))
          .foregroundStyle(.secondary)
        if let expected = model?.expected[key], let difference = model?.difference(key) {
          Text(
            verbatim: environment.format(
              "onboarding.expected", table: "Onboarding",
              environment.money.exact(expected, currency: currency),
              signed(difference, currency))
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Menu {
          if !isMain {
            Button(t("onboarding.currency.makeMain")) {
              model?.makeMainCurrency(currency, of: account.id)
            }
          }
          if model?.canRemove(currency, from: account.id) == true {
            Button(t("onboarding.currency.remove"), role: .destructive) {
              model?.removeCurrency(currency, from: account.id)
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isMain && model?.canRemove(currency, from: account.id) != true)
        .help(t("onboarding.currency.actions"))
        .accessibilityLabel(Text(verbatim: t("onboarding.currency.actions")))
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: environment.format("onboarding.balance", table: "Onboarding", currency.code))
        if isMain {
          Text(verbatim: t("onboarding.currency.main"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// «+500.00 ₽», «−500.00 ₽», «0.00 ₽»: the sign always says which way.
  private func signed(_ amount: AmountE4, _ currency: CurrencyCode) -> String {
    let text = environment.money.exact(amount, currency: currency)
    return amount > .zero ? "+" + text : text
  }

  // MARK: Groups and the main account

  private var groupsSection: some View {
    Section {
      ForEach(model?.groups ?? []) { group in
        HStack(spacing: 8) {
          TextField(
            text: groupBinding(group.id, \.name, ""),
            prompt: Text(verbatim: t("onboarding.group.name"))
          ) {
            Text(verbatim: t("onboarding.group.name"))
          }
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          Toggle(isOn: groupBinding(group.id, \.inSummary, true)) {
            Text(verbatim: t("onboarding.group.inSummary"))
          }
          if !group.inSummary {
            // Out of the summary: a symbol with the words, not a colour.
            Image(systemName: "eye.slash")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          if group.isNew {
            Button {
              model?.removeGroup(group.id)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(t("onboarding.group.remove"))
            .accessibilityLabel(Text(verbatim: t("onboarding.group.remove")))
          }
        }
      }
      HStack(spacing: 8) {
        ForEach(BankCatalog.Country.allCases, id: \.self) { country in
          let name = t(country.nameKey)
          if model?.hasGroup(named: name) == false {
            Button {
              model?.addGroup(name: name)
            } label: {
              Label {
                Text(verbatim: name)
              } icon: {
                Image(systemName: "plus")
              }
            }
          }
        }
        TextField(text: $groupName, prompt: Text(verbatim: t("onboarding.group.new"))) {
          Text(verbatim: t("onboarding.group.new"))
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .onSubmit(addGroup)
        Button(t("onboarding.group.add"), action: addGroup)
          .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    } header: {
      Text(verbatim: t("onboarding.groups"))
    } footer: {
      Text(verbatim: t("onboarding.groups.footer"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func addGroup() {
    guard model?.addGroup(name: groupName) != nil else { return }
    groupName = ""
  }

  private var mainSection: some View {
    Section {
      Picker(
        selection: Binding(get: { model?.mainId }, set: { model?.mainId = $0 })
      ) {
        ForEach(model?.accounts ?? []) { account in
          Text(verbatim: account.name.isEmpty ? t("onboarding.account.unnamed") : account.name)
            .tag(UUID?.some(account.id))
        }
      } label: {
        Text(verbatim: t("onboarding.main.account"))
      }
      Picker(
        selection: Binding(
          get: { model?.defaultCurrency ?? environment.defaultCurrency },
          set: { model?.defaultCurrency = $0 })
      ) {
        ForEach(defaultCurrencyOptions, id: \.self) { currency in
          Text(verbatim: currency.code).tag(currency)
        }
      } label: {
        Text(verbatim: t("onboarding.defaultCurrency"))
      }
    } header: {
      Text(verbatim: t("onboarding.main"))
    } footer: {
      Text(verbatim: t("onboarding.main.footer"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var defaultCurrencyOptions: [CurrencyCode] {
    guard let model else { return [environment.defaultCurrency] }
    var result: [CurrencyCode] = []
    for currency in [model.defaultCurrency] + model.enabled + model.heldCurrencies
    where !result.contains(currency) {
      result.append(currency)
    }
    return result
  }

  // MARK: The answers

  private var footer: some View {
    HStack(spacing: 12) {
      if readFailed {
        Label {
          Text(verbatim: t("onboarding.failure.read"))
        } icon: {
          Image(systemName: "exclamationmark.octagon")
        }
        .foregroundStyle(.red)
        Button(environment.language("action.retry")) {
          Task { @MainActor in await read() }
        }
      } else if let failureKey {
        Label {
          Text(verbatim: t(failureKey))
        } icon: {
          Image(systemName: "exclamationmark.octagon")
        }
        .foregroundStyle(.red)
      } else if let model, let issue = model.issues.first {
        Label {
          Text(verbatim: model.message(for: issue, language: environment.language))
        } icon: {
          Image(systemName: "info.circle")
        }
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button(t("onboarding.later"), action: later)
        .keyboardShortcut(.cancelAction)
        .disabled(isWriting)
      Button(t("onboarding.done"), action: finish)
        .buttonStyle(.borderedProminent)
        .disabled(
          isWriting || readFailed || model?.hasExpected != true || model?.issues.isEmpty == false)
    }
    .appFont(.callout)
    .padding(16)
  }

  /// Everything is read again at the moment of the count. The balances expected: what moved
  /// while the sheet was open is in them. The accounts: Settings stays usable meanwhile, and
  /// an account archived or merged there is not written back live — the list is shown again
  /// first.
  private func finish() {
    guard !isWriting else { return }
    isWriting = true
    failureKey = nil
    Task { @MainActor in
      defer { isWriting = false }
      let at = Date()
      guard let expected = await AccountSetupExpectations.load(from: environment, at: at) else {
        readFailed = true
        return
      }
      model?.setExpected(expected)
      switch model?.rebase(on: environment) {
      case .none:
        readFailed = true
        return
      case .some(true):
        failureKey = "onboarding.failure.changed"
        return
      case .some(false):
        break
      }
      guard let plan = model?.plan(at: at) else { return }
      switch AccountSetupWrites.finish(plan, environment: environment, store: store) {
      case .written: dismiss()
      case .failed: failureKey = "onboarding.failure.write"
      }
    }
  }

  /// Put off once, the setup is not put off again: the sheet opened from the card only closes.
  private func later() {
    guard !isWriting else { return }
    if environment.accountSetup == .later {
      dismiss()
      return
    }
    if AccountSetupWrites.postpone(environment: environment, store: store) {
      dismiss()
    } else {
      failureKey = "onboarding.failure.write"
    }
  }

  // MARK: Bindings by id

  /// A field of an account found by its id each time: an account taken away while its row is
  /// still on screen reads as the fallback instead of an index out of range.
  private func accountBinding<Value>(
    _ id: UUID, _ path: WritableKeyPath<AccountSetupModel.Account, Value>, _ fallback: Value
  ) -> Binding<Value> {
    Binding(
      get: { model?.accounts.first { $0.id == id }?[keyPath: path] ?? fallback },
      set: { value in
        guard let index = model?.accounts.firstIndex(where: { $0.id == id }) else { return }
        model?.accounts[index][keyPath: path] = value
      })
  }

  private func groupBinding<Value>(
    _ id: UUID, _ path: WritableKeyPath<AccountSetupModel.Group, Value>, _ fallback: Value
  ) -> Binding<Value> {
    Binding(
      get: { model?.groups.first { $0.id == id }?[keyPath: path] ?? fallback },
      set: { value in
        guard let index = model?.groups.firstIndex(where: { $0.id == id }) else { return }
        model?.groups[index][keyPath: path] = value
      })
  }
}
