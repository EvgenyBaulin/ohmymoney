import AppCore
import Foundation
import SwiftUI

/// «Такая же операция уже записана»: asked before a new operation that repeats one written a
/// moment ago is written again. «Добавить» writes it, «Не добавлять» leaves the line as it was.
struct RepeatQuestion: Identifiable {
  let entry: TransactionEntry
  var id: UUID { entry.id }

  /// The amount, what it was called, and when it was written.
  @MainActor func message(_ environment: AppEnvironment) -> String {
    let written = entry.transaction
    let money = environment.money.exact(written.amountE4, currency: written.currency)
    let note = written.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return environment.language.format(
      "entry.repeat.message", table: "Entry", note.isEmpty ? money : "\(money) · \(note)",
      environment.dates.time(written.createdAt))
  }
}

/// «Запись или план?»: asked once before an operation dated after today is written. «Записать
/// как есть» writes it on its date, the other button makes a plan of it instead (`OperationAhead`).
struct AheadQuestion: Identifiable {
  let plan: OperationAhead.Plan
  let day: DateOnly
  var id: String { "\(plan)-\(day.iso)" }

  @MainActor func title(_ environment: AppEnvironment) -> String {
    environment.language.format("entry.ahead.title", table: "Entry", environment.dates.longDay(day))
  }

  /// The key of the button that makes the plan.
  var planKey: String {
    plan == .payment ? "entry.ahead.planPayment" : "entry.ahead.planIncome"
  }
}

/// «Выйдет за лимит карты на X»: asked once before spending that takes a credit card past its
/// limit is written. The bank may charge a fee, but the owner can record it all the same.
struct OverLimitQuestion: Identifiable, Equatable {
  let over: AmountE4
  let currency: CurrencyCode
  var id: String { "\(over.raw)-\(currency.code)" }

  @MainActor func title(_ environment: AppEnvironment) -> String {
    environment.language.format(
      "entry.overLimit.title", table: "Entry", environment.money.exact(over, currency: currency))
  }
}

/// «После этого остаток станет X — ниже Y»: asked once before spending that takes an account
/// below the balance its bank asks to keep is written. The bank may take back a rate for the
/// month, but the owner can record it all the same.
struct MinBalanceQuestion: Identifiable, Equatable {
  let warning: MinBalanceWarning
  var id: String { "\(warning.afterE4.raw)-\(warning.minimumE4.raw)" }

  @MainActor func title(_ environment: AppEnvironment) -> String {
    environment.language.format(
      "entry.minBalance.title", table: "Entry",
      environment.money.rounded(warning.afterE4, currency: warning.currency),
      environment.money.rounded(warning.minimumE4, currency: warning.currency))
  }
}

/// «Подождать?»: asked once before a purchase above the owner's share of the free sum is
/// written, with the pause switched on in «Покупки». «Записать» writes it, «Отмена» leaves it.
struct PauseQuestion: Identifiable, Equatable {
  let amountRubE4: AmountE4
  /// The purchase in percent of the free sum; `nil` when there is none to compare with.
  let sharePercent: Decimal?
  var id: String { "\(amountRubE4.raw)" }

  @MainActor func message(_ environment: AppEnvironment) -> String {
    let money = environment.money.rounded(amountRubE4)
    guard let sharePercent else {
      return PurchaseHookText.f("purchase.pause.messageNoShare", environment, money)
    }
    return PurchaseHookText.f(
      "purchase.pause.message", environment, money, NumberText.plain(sharePercent))
  }
}

/// «Сколько проехали с прошлой заправки?»: asked once after the words of a fill-up, to know the
/// mileage. `previous` is the fill-up before, if there is one: the answer is the kilometres since
/// it; without one the answer is the mileage on the dashboard.
struct MileageQuestion: Identifiable, Equatable {
  let previous: FuelFill?
  var id: String { previous?.transactionId.uuidString ?? "first" }
}

/// The questions asked before a new operation is written, in the order they are asked: a date
/// after today, a card past its limit, an account below the balance its bank asks to keep, a
/// repeat of the last minutes, a pause before a big purchase, the mileage of a fill-up. The line at the bottom and the form at the side both save through
/// `EntryBar.commit`, which asks this and nothing else for these four, so the two can not drift
/// apart. A saved operation being edited is asked only the two about money, and only when the
/// edit makes the card's limit or the kept balance worse than the saved operation did
/// (`TransactionEditorModel.save`, which asks this too); the date and the repeat are for a new
/// operation (the models answer `nil` for an edit).
@MainActor
enum EntrySaveQuestions {
  /// Which question it is, for logs and tests.
  enum Kind: String, CaseIterable {
    case ahead, overLimit, minBalance, repeated, pause, mileage
  }

  enum Question {
    case ahead(AheadQuestion)
    case overLimit(OverLimitQuestion)
    case minBalance(MinBalanceQuestion)
    case repeated(RepeatQuestion)
    case pause(PauseQuestion)
    case mileage(MileageQuestion)

    var kind: Kind {
      switch self {
      case .ahead: .ahead
      case .overLimit: .overLimit
      case .minBalance: .minBalance
      case .repeated: .repeated
      case .pause: .pause
      case .mileage: .mileage
      }
    }
  }

  /// What the screens know about the money: the credit cards today and the balances with the
  /// conditions of the banks. Empty while nothing was read: no limit and no minimum is known.
  struct Money {
    var cards: [UUID: CreditCardNow] = [:]
    var balances: (accounts: AccountsSnapshot, bank: BankData)?
    /// The settings of the purchases, the free sum now and the rubles per unit of a currency: what
    /// the pause compares with. The pause is off by default, so nothing is asked without them.
    var purchase = PurchaseSettings()
    var freeRubE4: AmountE4?
    var rubPerUnit: [CurrencyCode: Decimal] = [:]
    /// The latest fill-up recorded, to count the mileage from.
    var lastFill: FuelFill?

    init(cards: [UUID: CreditCardNow] = [:], balances: (AccountsSnapshot, BankData)? = nil) {
      self.cards = cards
      self.balances = balances.map { (accounts: $0.0, bank: $0.1) }
    }

    init(_ snapshot: DataSnapshot?) {
      self.init(
        cards: snapshot?.planning.creditCards ?? [:],
        balances: snapshot.map { ($0.planning.accounts, $0.dataset.bankData) })
      guard let snapshot else { return }
      purchase = snapshot.dataset.purchaseSettings
      freeRubE4 = snapshot.planning.freeMoney.main
      rubPerUnit = snapshot.planning.rubPerUnit
      // Only when the question can be asked: the fill-ups are read from every operation.
      if purchase.fuelAskMileage {
        lastFill = FuelEconomy.fills(
          entries: snapshot.dataset.entries, calendar: snapshot.ledger.calendar
        ).max { ($0.day, $0.odometerKm) < ($1.day, $1.odometerKm) }
      }
    }
  }

  /// The first question the operation as it stands has to answer, or `nil` when it can be
  /// written.
  static func next(
    for model: EntryDraftModel, environment: AppEnvironment, money: Money, now: Date
  ) -> Question? {
    if let plan = model.planAhead(today: environment.today) {
      return .ahead(
        AheadQuestion(plan: plan, day: environment.calendar.day(of: model.draft.occurredAt)))
    }
    if let warning = model.creditLimitWarning(cards: money.cards) {
      return .overLimit(OverLimitQuestion(over: warning.over, currency: warning.currency))
    }
    if let known = money.balances,
      let warning = model.minBalanceWarning(accounts: known.accounts, bank: known.bank)
    {
      return .minBalance(MinBalanceQuestion(warning: warning))
    }
    if let same = model.repeatedOperation(now: now) {
      return .repeated(RepeatQuestion(entry: same))
    }
    if let pause = model.pauseQuestion(money: money) { return .pause(pause) }
    if let mileage = model.mileageQuestion(money: money) { return .mileage(mileage) }
    return nil
  }
}

/// «Выйдет за лимит карты» and «Остаток станет ниже минимума» over the editor of a saved
/// operation (window, inspector and form alike): «Записать всё равно» calls `answered`, which
/// saves again; «Отмена» leaves the edit as typed.
private struct EditSaveQuestionDialog: ViewModifier {
  @Dependency(\.environment) private var environment
  @Binding var question: EntrySaveQuestions.Question?
  let answered: () -> Void

  private var title: String {
    switch question {
    case .overLimit(let over): over.title(environment)
    case .minBalance(let minimum): minimum.title(environment)
    case .ahead, .repeated, .pause, .mileage, nil: ""
    }
  }

  /// The two questions about money; the pause and the mileage have dialogs of their own.
  private var isMoneyQuestion: Bool {
    switch question {
    case .overLimit, .minBalance: true
    case .ahead, .repeated, .pause, .mileage, nil: false
    }
  }

  private var prefix: String {
    if case .minBalance = question { return "entry.minBalance" }
    return "entry.overLimit"
  }

  func body(content: Content) -> some View {
    content.confirmationDialog(
      title,
      isPresented: Binding(
        get: { isMoneyQuestion }, set: { if !$0 && isMoneyQuestion { question = nil } }),
      titleVisibility: .visible
    ) {
      Button(environment.language("\(prefix).record", table: "Entry")) { answered() }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: {
      Text(verbatim: environment.language("\(prefix).message", table: "Entry"))
    }
  }
}

extension View {
  func editSaveQuestions(
    _ question: Binding<EntrySaveQuestions.Question?>, answered: @escaping () -> Void
  ) -> some View {
    modifier(EditSaveQuestionDialog(question: question, answered: answered))
  }
}

/// «Сверх платежа X — уменьшить срок, платёж или это платёж вперёд?»: asked before a payment of a
/// loan above what its due asks for is written (`DebtPrepayment`). The answer given for the debt
/// the last time comes first, «Это платёж вперёд» too.
struct PrepayQuestion: Identifiable, Equatable {
  let excess: AmountE4
  let currency: CurrencyCode
  let suggested: PrepayChoice
  var id: String { "\(excess.raw)-\(suggested.rawValue)" }

  @MainActor func title(_ environment: AppEnvironment) -> String {
    environment.language.format(
      "entry.prepay.title", table: "Entry", environment.money.exact(excess, currency: currency))
  }

  /// The three answers, the suggested one first.
  var choices: [PrepayChoice] {
    [suggested] + PrepayChoice.allCases.filter { $0 != suggested }
  }

  static func key(of choice: PrepayChoice) -> String {
    switch choice {
    case .term: "entry.prepay.term"
    case .payment: "entry.prepay.payment"
    case .forward: "entry.prepay.forward"
    }
  }
}

/// A refund of a thing bought in instalments, waiting for `InstalmentReturnSheet` to write it.
struct InstalmentReturnRequest: Identifiable {
  let refund: TransactionEntry
  let debt: Debt
  var id: UUID { refund.id }
}

/// What the line says under itself once an operation is written: an offer to allocate an income
/// in «Заработок» (`Allocation.offers`), or — after «смз» with self-employment off and never
/// offered — the one offer to count its tax.
enum EntryAfterSaving {
  @MainActor static func notice(
    for entry: TransactionEntry, saidSelfEmployed: Bool, tree: CategoryTree,
    selfEmployment: SelfEmploymentSettings, allocation: AllocationSettings,
    money: MoneyFormatter
  ) -> EntryLineMessage? {
    guard entry.transaction.kind == .income else { return nil }
    if saidSelfEmployed, !selfEmployment.enabled, !selfEmployment.offered {
      return .offerSelfEmployment
    }
    guard Allocation.offers(entry: entry, tree: tree, settings: allocation) else { return nil }
    return .allocate(
      entry.id, money.rounded(entry.transaction.amountE4, currency: entry.transaction.currency))
  }
}
