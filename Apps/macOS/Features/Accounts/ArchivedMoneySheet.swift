import AppCore
import SwiftUI

/// The rows of the question «На какой счёт зачислить N с «X»?»: one per currency an archived
/// account would be left with money in, or taken below zero, each with the live accounts that
/// hold the currency and the one chosen. Nothing here is written.
struct ArchivedMoneyForm: Sendable {
  struct Row: Identifiable, Sendable {
    let leftover: ArchivedLeftover
    /// The live accounts that hold the currency, in menu order; empty when none does.
    let counterparts: [PaymentMethod]
    /// The moment of the latest count of each counterpart in the row's currency: the transfer
    /// goes after it, never inside the window of that count (`ArchivedMoney.settlingTransfer`).
    var counterpartCounts: [UUID: Date] = [:]
    var chosen: UUID?
    var id: BalanceKey { leftover.key }
  }

  var rows: [Row]

  /// The main account is chosen where it holds the currency, else the first that does.
  /// `balances` give the latest count of each counterpart; without them none is known.
  init(
    check: ArchivedMoneyCheck, accounts: [PaymentMethod], locale: Locale,
    balances: AccountBalances? = nil
  ) {
    rows = check.leftovers.map { leftover in
      let counterparts = ArchivedMoney.counterparts(
        for: leftover.key, accounts: accounts, locale: locale)
      let main = counterparts.first(where: \.isDefault) ?? counterparts.first
      var counts: [UUID: Date] = [:]
      if let balances {
        for account in counterparts {
          counts[account.id] = ArchivedMoney.counterpartCount(
            account.id, for: leftover.key, balances: balances)
        }
      }
      return Row(
        leftover: leftover, counterparts: counterparts, counterpartCounts: counts,
        chosen: main?.id)
    }
  }

  /// Every row has a live account to move its money to or from.
  var canConfirm: Bool { !rows.isEmpty && rows.allSatisfy { $0.chosen != nil } }

  /// The transfers that bring every archived key back to zero (`settlingTransfers`): what a
  /// change leaves, a second after the key's last movement — or after the latest count of the
  /// chosen account, when that is later; a whole balance, now — and, for money typed ahead on a
  /// key, the rest dated with its latest movement.
  func transfers(now: Date, note: String?) -> [Transfer] {
    rows.flatMap { row in
      row.chosen.map {
        ArchivedMoney.settlingTransfers(
          row.leftover, counterpart: $0, counterpartCountedAt: row.counterpartCounts[$0],
          now: now, note: note)
      } ?? []
    }
  }

  /// The transfers the answer of the row will write, told one by one.
  func legs(of row: Row, now: Date) -> [SettlingLeg] {
    guard let chosen = row.chosen else { return [] }
    let transfers = ArchivedMoney.settlingTransfers(
      row.leftover, counterpart: chosen, counterpartCountedAt: row.counterpartCounts[chosen],
      now: now, note: nil)
    return ArchivedMoney.legs(of: transfers, archived: row.leftover.key.accountId, now: now)
  }

  /// The amounts the question is worked out on, per key: a write checks the books still hold
  /// them.
  var shown: [BalanceKey: AmountE4] {
    Dictionary(rows.map { ($0.leftover.key, $0.leftover.amount) }, uniquingKeysWith: { a, _ in a })
  }

  /// What each key held now when the question was worked out, where it knows: checked too.
  var shownNow: [BalanceKey: AmountE4] {
    Dictionary(
      rows.compactMap { row in row.leftover.heldNow.map { (row.leftover.key, $0) } },
      uniquingKeysWith: { a, _ in a })
  }
}

/// What the question says of the transfers it will write: one line for each, with its day, its
/// amount and the two accounts. What a change of an archived account's past leaves goes right
/// after its last movement, and the line names that day rather than «now». A settling can be
/// two transfers — what the account holds now goes
/// now, and what is typed ahead of today on it goes back and forth on its own day —, and the
/// second must not be a surprise: «И 30 сентября — перевод 30,000 ₽ с «Сбер» обратно на
/// «Наличные», чтобы покрыть записанное вперёд.»
@MainActor
enum ArchivedLegText {
  /// The key of the Accounts table that words `leg`; `following` is a leg after the first.
  static func key(for leg: SettlingLeg, following: Bool) -> String {
    switch (leg.when, leg.returnsToArchived) {
    case (.earlier, _): "archived.leftover.leg.earlier"
    case (.now, _): "archived.leftover.leg.now"
    case (.later, true): following ? "archived.leftover.leg.back.and" : "archived.leftover.leg.back"
    case (.later, false):
      following ? "archived.leftover.leg.later.and" : "archived.leftover.leg.later"
    }
  }

  /// A line for every leg, in order. `name` gives the name of an account by its id.
  static func lines(
    _ legs: [SettlingLeg], name: (UUID) -> String, _ environment: AppEnvironment
  ) -> [String] {
    legs.enumerated().map { index, leg in
      let amount = environment.money.exact(leg.amount, currency: leg.currency)
      let key = key(for: leg, following: index > 0)
      if leg.when == .now {
        return environment.format(
          key, table: AccountText.table, amount, name(leg.from), name(leg.to))
      }
      // A day in the past can be of another year: it says its year.
      let legDay = environment.calendar.day(of: leg.at)
      let day =
        leg.when == .earlier
        ? environment.dates.longDay(legDay) : environment.dates.dayAndMonth(legDay)
      return environment.format(
        key, table: AccountText.table, day, amount, name(leg.from), name(leg.to))
    }
  }
}

/// «На какой счёт зачислить 1,000 ₽ с «Наличные»?» — an account in the archive stays at zero:
/// what a change would leave on it goes to a live account of the same currency, and what it
/// would take below zero comes from one, by a transfer dated a second after the account's last
/// movement once the change is made — or now, for an account archived with money. The change and
/// its transfers are one step of ⌘Z.
///
/// Three ways in: a change of its past (an edit, a deletion) hands in what it would leave and
/// takes the transfers back (`init(check:accountName:confirm:cancel:)`); «В архив» on an
/// account with money asks where each currency goes and archives it with them
/// (`init(archiving:newMain:finish:)`); and an account the archive took with money before 1.2
/// is emptied the same way (`init(leftoversOf:finish:)`). A system form, no glass.
struct ArchivedMoneySheet: View {
  enum Purpose {
    case change(ArchivedMoneyCheck, confirm: ([Transfer]) -> Void)
    case archiving(PaymentMethod, newMain: UUID?)
    case leftovers(PaymentMethod)
  }

  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss

  let purpose: Purpose
  let cancel: (() -> Void)?
  /// Called once the sheet is done with, for the ways in that write themselves: whether it
  /// wrote. Without it the sheet dismisses itself.
  let finish: ((Bool) -> Void)?

  @State private var form: ArchivedMoneyForm?
  @State private var books: AccountBooks?
  @State private var refusal: AccountRefusal?
  @State private var failed = false
  @State private var isSaving = false

  /// A change of the past of an archived account: `check` is what it would leave there.
  init(
    check: ArchivedMoneyCheck, confirm: @escaping ([Transfer]) -> Void,
    cancel: @escaping () -> Void
  ) {
    purpose = .change(check, confirm: confirm)
    self.cancel = cancel
    finish = nil
  }

  /// «В архив» on an account that still holds money.
  init(archiving account: PaymentMethod, newMain: UUID?, finish: @escaping (Bool) -> Void) {
    purpose = .archiving(account, newMain: newMain)
    cancel = nil
    self.finish = finish
  }

  /// An account already in the archive that still holds money: what it holds is moved to live
  /// accounts in one step of ⌘Z.
  init(leftoversOf account: PaymentMethod, finish: ((Bool) -> Void)? = nil) {
    purpose = .leftovers(account)
    cancel = nil
    self.finish = finish
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let archived = archivedAccount, case .archiving = purpose {
        Text(
          verbatim: environment.format(
            "archived.archive.title", table: AccountText.table, archived.name)
        )
        .appFont(.headline)
      }
      if let form {
        Form {
          ForEach(Array(form.rows.enumerated()), id: \.element.id) { index, row in
            rowView(row, index: index)
          }
        }
        .formStyle(.grouped)
      } else {
        ProgressView()
          .controlSize(.small)
      }
      if let refusal {
        AccountRefusalNote(refusal: refusal)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel, action: close)
          .keyboardShortcut(.cancelAction)
        Button(t(confirmKey), action: confirm)
          .keyboardShortcut(.defaultAction)
          .disabled(!(form?.canConfirm ?? false) || isSaving || store.isWritingInBackground)
      }
    }
    .padding(20)
    .sheetFrame(width: 480)
    .task { await load() }
    .refusedWriteAlert($failed, environment)
  }

  @ViewBuilder
  private func rowView(_ row: ArchivedMoneyForm.Row, index: Int) -> some View {
    let name = accountName(row.leftover.key.accountId)
    let amount = environment.money.exact(
      row.leftover.shownAmount.magnitude, currency: row.leftover.key.currency)
    Section {
      if row.counterparts.isEmpty {
        Label {
          Text(
            verbatim: environment.format(
              "archived.leftover.noCounterpart", table: AccountText.table,
              row.leftover.key.currency.code, name)
          )
          .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
      } else {
        Picker(
          selection: Binding(
            get: { form?.rows[index].chosen },
            set: { form?.rows[index].chosen = $0 })
        ) {
          ForEach(row.counterparts, id: \.id) { account in
            Text(verbatim: account.name).tag(UUID?.some(account.id))
          }
        } label: {
          Text(verbatim: t("transfer.sheet.account"))
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(
          verbatim: environment.format(
            "archived.leftover.message", table: AccountText.table, name)
        )
        // Every transfer it will write, with its day: not one of them is a surprise.
        ForEach(
          ArchivedLegText.lines(
            form?.legs(of: row, now: environment.now()) ?? [], name: accountName, environment),
          id: \.self
        ) { line in
          Text(verbatim: line)
            .monospacedDigit()
        }
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } header: {
      Text(
        verbatim: environment.format(
          row.leftover.shownAmount.raw > 0
            ? "archived.leftover.plusTitle" : "archived.leftover.minusTitle",
          table: AccountText.table, amount, name)
      )
      .monospacedDigit()
    }
  }

  private var confirmKey: String {
    if case .archiving = purpose { return "archived.archive.confirm" }
    return "archived.leftover.confirm"
  }

  private var archivedAccount: PaymentMethod? {
    switch purpose {
    case .change: nil
    case .archiving(let account, _), .leftovers(let account): account
    }
  }

  private func accountName(_ id: UUID) -> String {
    let all = books?.dataset.paymentMethods ?? actions.all
    return all.first { $0.id == id }?.name ?? ""
  }

  // MARK: Reading and writing

  private func load() async {
    switch purpose {
    case .change(let check, _):
      // The books give the latest count of every account the money may go to: the transfer
      // is dated after it. Without them the change is still answered, by the last movement.
      let books = await actions.books()
      self.books = books
      form = ArchivedMoneyForm(
        check: check, accounts: books?.dataset.paymentMethods ?? actions.all,
        locale: environment.language.locale, balances: books?.balances)
    case .archiving(let account, _), .leftovers(let account):
      guard let books = await actions.books() else {
        failed = true
        return
      }
      self.books = books
      form = ArchivedMoneyForm(
        check: ArchivedMoney.balancesToMove(of: account, balances: books.balances),
        accounts: books.dataset.paymentMethods, locale: environment.language.locale,
        balances: books.balances)
    }
  }

  private func confirm() {
    guard let form, form.canConfirm, !isSaving else { return }
    let transfers = form.transfers(now: environment.now(), note: t("archived.leftover.note"))
    switch purpose {
    case .change(_, let confirm):
      confirm(transfers)
    case .archiving(let account, let newMain):
      write(form) { books in
        actions.archive(
          account.id, newMain: newMain, books: books, settling: transfers, expecting: form.shown,
          expectingNow: form.shownNow)
      }
    case .leftovers(let account):
      write(form) { books in
        actions.settleLeftovers(
          of: account, books: books, settling: transfers, expecting: form.shown,
          expectingNow: form.shownNow)
      }
    }
  }

  /// Writes with the books read again at this moment: money that moved since the question was
  /// shown is said, and the question shown again with what is there now.
  private func write(
    _ form: ArchivedMoneyForm, _ action: @escaping (AccountBooks) -> AccountActionOutcome
  ) {
    isSaving = true
    Task {
      defer { isSaving = false }
      guard let books = await actions.books() else {
        failed = true
        return
      }
      switch action(books) {
      case .done:
        done(true)
      case .refused(let reason):
        refusal = reason
        if case .balanceChanged = reason { await load() }
      case .failed:
        // The write itself found other money than was shown: say so, and show what is there.
        let before = form
        await load()
        if let now = self.form,
          let key = Self.changed(now.shown, before.shown)
            ?? Self.changed(now.shownNow, before.shownNow)
        {
          refusal = .balanceChanged(key)
        } else {
          failed = true
        }
      }
    }
  }

  /// The first key whose amount differs between the two.
  private static func changed(
    _ now: [BalanceKey: AmountE4], _ before: [BalanceKey: AmountE4]
  ) -> BalanceKey? {
    Set(now.keys).union(before.keys).sorted().first { now[$0] != before[$0] }
  }

  private func close() {
    if let cancel {
      cancel()
    } else {
      done(false)
    }
  }

  private func done(_ wrote: Bool) {
    if let finish {
      finish(wrote)
    } else {
      dismiss()
    }
  }
}
