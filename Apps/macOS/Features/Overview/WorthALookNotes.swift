import AppCore
import SwiftUI

/// The lines of «Стоит посмотреть» that came with the credits, the allocation of income and
/// self-employment (`WorthALook.notes`): reminders of debts and credit cards, the tax of a month
/// due, the salary not come, an income to allocate, what is left of the month, the limit of
/// self-employment, and the hint about burnout. Each line says what it is about in words and a
/// symbol, never in colour alone, with the one action that settles it.
enum WorthALookNoteText {
  static let table = "Overview"

  /// The words of a line. `debts` and `accounts` give the names of what a reminder is about.
  @MainActor
  static func text(
    _ note: WorthALookNote, debts: [UUID: String], accounts: [UUID: String],
    currencies: [UUID: CurrencyCode] = [:], warrantyNames: [UUID: String] = [:],
    _ environment: AppEnvironment
  ) -> String {
    let money = environment.money
    let day = { (day: DateOnly) in environment.dates.dayAndMonth(day) }
    func f(_ key: String, _ arguments: CVarArg...) -> String {
      String(
        format: environment.language(key, table: table), locale: environment.language.locale,
        arguments: arguments)
    }
    switch note {
    case .debt(let reminder):
      switch reminder {
      case .prepayNotice(let debtId, let fileBy, let prepayOn, let amount):
        return f(
          "look.prepay", debts[debtId] ?? "—", day(prepayOn), money.rounded(amount), day(fileBy))
      case .pledgeDue(let debtId, let returnBy, let overdue):
        return f(
          overdue ? "look.pledgeOverdue" : "look.pledgeDue", debts[debtId] ?? "—", day(returnBy))
      case .insuranceCooling(_, let debtId, let until):
        return f("look.insurance", debts[debtId] ?? "—", day(until))
      case .creditHistory:
        return environment.language("look.creditHistory", table: table)
      case .cardPayBy(let accountId, let due, let full, let minimum):
        let line = f("look.cardPayBy", accounts[accountId] ?? "—", money.rounded(full), day(due))
        guard let minimum else { return line }
        return line + " · " + f("look.cardPayBy.minimum", money.rounded(minimum))
      case .cardGraceMissed(let accountId, let statementDay, let estimate):
        return f(
          "look.cardGrace", accounts[accountId] ?? "—", day(statementDay), money.rounded(estimate))
      case .cardOverLimit(let accountId, let over):
        return f(
          "look.cardOverLimit", accounts[accountId] ?? "—",
          money.rounded(over, currency: currencies[accountId] ?? .rub))
      }
    case .npdDue(let month):
      return f(
        month.state == .overdue ? "look.npdOverdue" : "look.npdDue",
        PlanningText.monthInSentence(month.month, environment), money.rounded(month.toPayE4),
        day(month.due))
    case .salaryLate(let half):
      return f("look.salaryLate", day(half.nextIncomeDay))
    case .allocate(_, let left, let currency):
      return f("look.allocate", money.rounded(left, currency: currency))
    case .monthRest(let offer):
      return f(
        "look.monthRest", PlanningText.monthInSentence(offer.month, environment),
        money.rounded(offer.amountE4))
    case .npdLimit(let year):
      return year.exceeded
        ? f("look.npdLimitExceeded", money.rounded(year.incomeRub), money.rounded(year.limitRub))
        : f("look.npdLimit", money.rounded(year.leftRub), money.percent(basisPoints: year.shareBp))
    case .burnout(let signal):
      return environment.format(
        "look.burnout", table: table, counts: signal.lastWeekCount, signal.usualCount)
    case .databaseProblems(let count):
      return environment.format("look.databaseProblems", table: table, counts: count)
    case .bank(let bankNote): return bankText(bankNote, accounts: accounts, environment)
    case .depositEnds(let advice):
      return DepositText.endsLine(advice, accounts: accounts, environment)
    case .warranty(let reminder):
      return WarrantyText.note(reminder, names: warrantyNames, environment)
    case .lowCopySpace(let free):
      return f(
        "look.lowCopySpace", ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
    }
  }

  /// The symbol of a line: what it is about, told by its form.
  static func symbol(_ note: WorthALookNote) -> String {
    switch note {
    case .debt(let reminder):
      switch reminder {
      case .prepayNotice: "doc.text"
      case .pledgeDue(_, _, let overdue): overdue ? "exclamationmark.circle" : "key"
      case .insuranceCooling: "umbrella"
      case .creditHistory: "person.text.rectangle"
      case .cardPayBy: "creditcard"
      case .cardGraceMissed: "exclamationmark.triangle"
      case .cardOverLimit: "exclamationmark.octagon"
      }
    case .npdDue(let month): month.state == .overdue ? "exclamationmark.circle" : "doc.text"
    case .salaryLate: "questionmark.circle"
    case .allocate: "square.split.2x1"
    case .monthRest: "tray.and.arrow.down"
    case .npdLimit: "exclamationmark.triangle"
    case .burnout: "cup.and.saucer"
    case .lowCopySpace: "externaldrive.badge.exclamationmark"
    case .bank(let bankNote): bankSymbol(bankNote)
    case .depositEnds: "calendar.badge.clock"
    case .databaseProblems: "stethoscope"
    case .warranty(let reminder): WarrantyText.symbol(reminder)
    }
  }

  /// A line that cannot wait and is drawn red — its symbol and words say the same.
  static func isAlarm(_ note: WorthALookNote) -> Bool {
    if case .debt(.cardOverLimit) = note { return true }
    if case .bank(let bankNote) = note { return bankNote.isAlarm }
    return false
  }

  /// The actions a line offers, in their order.
  enum Action: String, Hashable, CaseIterable {
    /// «Готово»: the reminder is put away on this Mac.
    case done
    /// «Не напоминать» of the credit history.
    case stopCreditHistory
    case openDebts
    case openAccount
    case pay
    case openPlanning
    case allocate
    case decline
    case putAway
    /// «Не показывать» of the hint about burnout.
    case hideBurnout
    /// Opens the settings, where the copies are.
    case openSettings
    /// Opens the showcase of deposits.
    case openDeposits
    /// Opens the list of warranties and return terms.
    case openWarranty
    /// Opens the screen of a bank.
    case openBank
    /// Opens the list of forgotten money.
    case openForgotten
    /// Opens the list of what is paid with a card that ends.
    case rebind

    var key: String { "look.action.\(rawValue)" }
  }

  static func actions(_ note: WorthALookNote) -> [Action] {
    switch note {
    case .debt(let reminder):
      switch reminder {
      case .creditHistory: [.done, .stopCreditHistory]
      case .prepayNotice, .pledgeDue, .insuranceCooling: [.openDebts, .done]
      case .cardPayBy, .cardGraceMissed: [.openAccount, .done]
      // Not put away: it stays until the excess is paid in.
      case .cardOverLimit: [.openAccount]
      }
    case .npdDue: [.pay]
    case .salaryLate: [.openPlanning]
    case .allocate: [.allocate, .decline]
    case .monthRest: [.putAway, .decline]
    case .npdLimit: [.openPlanning]
    case .burnout: [.hideBurnout]
    case .lowCopySpace, .databaseProblems: [.openSettings]
    case .bank(let bankNote): bankActions(bankNote)
    case .depositEnds: [.openDeposits]
    case .warranty: [.openWarranty, .done]
    }
  }

  /// Every key the lines use, so a test finds each in both languages.
  static let keys =
    [
      "look.prepay", "look.pledgeDue", "look.pledgeOverdue", "look.insurance",
      "look.creditHistory", "look.cardPayBy", "look.cardPayBy.minimum", "look.cardGrace",
      "look.cardOverLimit",
      "look.npdDue", "look.npdOverdue", "look.salaryLate", "look.allocate", "look.monthRest",
      "look.npdLimit", "look.npdLimitExceeded", "look.burnout", "look.lowCopySpace",
      "look.databaseProblems",
    ] + WarrantyText.noteKeys + bankKeys + Action.allCases.map(\.key)
}

extension WorthALookNoteText {
  /// The keys of the lines about the banks.
  static let bankKeys = [
    "look.bank.limitNear", "look.bank.limitOver", "look.bank.minBelow", "look.bank.cardEnds",
    "look.bank.cardEnded", "look.bank.cardAttached", "look.bank.forgotten",
    "look.bank.forgottenAmount", "look.bank.insurance",
  ]

  /// The words of a line about the conditions of a bank. `accounts` names accounts and cards by id.
  @MainActor
  static func bankText(
    _ note: BankNote, accounts: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    let money = environment.money
    func f(_ key: String, _ arguments: CVarArg...) -> String {
      String(
        format: environment.language(key, table: table), locale: environment.language.locale,
        arguments: arguments)
    }
    switch note {
    case .limitNear(let accountId, let kind, let left, let currency):
      return f(
        "look.bank.limitNear", accounts[accountId] ?? "—", BankText.kindName(kind, environment),
        money.rounded(left, currency: currency))
    case .limitExceeded(let accountId, let kind, let over, let currency):
      return f(
        "look.bank.limitOver", accounts[accountId] ?? "—", BankText.kindName(kind, environment),
        money.rounded(over, currency: currency))
    case .minBalanceBelow(let accountId, let balance, let minimum, let currency):
      return f(
        "look.bank.minBelow", accounts[accountId] ?? "—",
        money.rounded(balance, currency: currency), money.rounded(minimum, currency: currency))
    case .cardExpiry(_, let cardId, let month, let expired, let count):
      let base = f(
        expired ? "look.bank.cardEnded" : "look.bank.cardEnds", accounts[cardId] ?? "—",
        environment.dates.monthTitle(month))
      return count > 0 ? base + " " + f("look.bank.cardAttached", "\(count)") : base
    case .forgotten(let count, let balance, _):
      let base = environment.format("look.bank.forgotten", table: table, counts: count)
      return balance.raw > 0
        ? base + " " + f("look.bank.forgottenAmount", money.rounded(balance)) : base
    case .insuranceOver(_, let name, let total, let limit):
      return f("look.bank.insurance", name, money.rounded(total), money.rounded(limit))
    }
  }

  static func bankSymbol(_ note: BankNote) -> String {
    switch note {
    case .limitNear: "gauge.with.dots.needle.67percent"
    case .limitExceeded: "exclamationmark.octagon"
    case .minBalanceBelow: "arrow.down.to.line"
    case .cardExpiry: "creditcard.trianglebadge.exclamationmark"
    case .forgotten: "zzz"
    case .insuranceOver: "exclamationmark.shield"
    }
  }

  static func bankActions(_ note: BankNote) -> [Action] {
    switch note {
    case .limitNear, .limitExceeded, .minBalanceBelow: [.openAccount]
    case .cardExpiry(_, _, _, _, let count):
      count > 0 ? [.rebind, .openAccount, .done] : [.openAccount, .done]
    case .forgotten: [.openForgotten, .done]
    case .insuranceOver: [.openBank, .done]
    }
  }

  /// The bank a line is about: the one of its account, or of the bank itself.
  @MainActor
  static func bankId(of note: BankNote, _ snapshot: DataSnapshot) -> UUID? {
    func bank(ofAccount id: UUID) -> UUID? {
      snapshot.dataset.paymentMethods.first { $0.id == id }.map(BankLimits.bankKey)
    }
    switch note {
    case .insuranceOver(let bankId, _, _, _): return bankId
    case .limitNear(let id, _, _, _), .limitExceeded(let id, _, _, _),
      .minBalanceBelow(let id, _, _, _), .cardExpiry(let id, _, _, _, _):
      return bank(ofAccount: id)
    case .forgotten: return nil
    }
  }
}

/// When the hint about burnout shows: on (`insights.burnout.enabled`), and once a week — the
/// week it was shown in is kept (`insights.burnout.lastShown`), and the line stays for the rest
/// of the launch it first showed in. A habit of this Mac, never carried by the archive.
@MainActor
enum BurnoutShowing {
  static let enabledKey = "insights.burnout.enabled"
  static let lastShownKey = "insights.burnout.lastShown"
  /// The week the hint was first shown in this launch.
  static var shownThisLaunch: String?

  static func enabled(_ defaults: UserDefaults) -> Bool {
    defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
  }

  /// The week `WorthALook.notes` is told the hint was last shown in: none while it is shown in
  /// this launch, so it does not go away the moment it is marked.
  static func lastShownWeek(_ defaults: UserDefaults, today: DateOnly) -> String? {
    let week = Burnout.weekKey(today)
    if shownThisLaunch == week { return nil }
    return defaults.string(forKey: lastShownKey)
  }

  /// The hint is on screen: its week is kept, once.
  static func shown(_ defaults: UserDefaults, today: DateOnly) {
    let week = Burnout.weekKey(today)
    guard shownThisLaunch != week else { return }
    shownThisLaunch = week
    defaults.set(week, forKey: lastShownKey)
    AppLog.info("insights.burnout.shown", .ui, "the hint about burnout was shown", [])
  }

  /// «Не показывать»: off on this Mac; «Настройки → Планирование» turns it on again.
  static func turnOff(_ defaults: UserDefaults) {
    defaults.set(false, forKey: enabledKey)
    shownThisLaunch = nil
  }
}

extension WorthALook {
  /// The lines of 1.9 as the card shows them, with what this Mac remembers of the hint about
  /// burnout.
  @MainActor
  static func notes(
    of snapshot: DataSnapshot, defaults: UserDefaults = .standard
  )
    -> [WorthALookNote]
  {
    notes(
      planning: snapshot.planning, ledger: snapshot.ledger, today: snapshot.today,
      burnout: snapshot.burnout, burnoutEnabled: BurnoutShowing.enabled(defaults),
      burnoutLastShownWeek: BurnoutShowing.lastShownWeek(defaults, today: snapshot.today),
      copyFreeBytes: AppEnvironment.isTestHost
        ? nil : BackupService.freeBytes(on: AppPaths.backupsDirectory),
      lowCopySpaceBytes: BackupSpace.lowThresholdBytes,
      databaseProblems: AppEnvironment.isTestHost
        ? 0 : IntegrityCheckService.storedProblems(in: .standard),
      depositEnds: DepositText.advice(for: snapshot),
      warranty: WarrantyReminders.list(
        WarrantyList.items(from: snapshot.dataset.entries), today: snapshot.today,
        dismissed: DebtReminderMarks.read(from: defaults).dismissed))
  }
}

/// What a line of «Стоит посмотреть» opens.
enum WorthALookSheet: Identifiable {
  case allocate(AllocationRequest)
  case monthRest(MonthRestOffer)
  case pay(NPDMonth)
  case showcase
  case forgotten
  case rebind(UUID)
  case warranty

  var id: String {
    switch self {
    case .warranty: "warranty"
    case .showcase: "showcase"
    case .forgotten: "forgotten"
    case .rebind(let id): "rebind:\(id)"
    case .allocate(let request): "allocate:\(request.incomeId)"
    case .monthRest(let offer): "monthRest:\(offer.month.iso)"
    case .pay(let month): "pay:\(month.month.iso)"
    }
  }
}

/// One line of 1.9 on the card, with its actions.
struct WorthALookNoteRow: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif
  let note: WorthALookNote
  let snapshot: DataSnapshot
  /// The line was settled here: the card hides it until the data is read again.
  let settled: (String) -> Void
  let open: (WorthALookSheet) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label {
        Text(
          verbatim: WorthALookNoteText.text(
            note, debts: names(snapshot.dataset.debts.map { ($0.id, $0.name) }),
            accounts: names(
              snapshot.dataset.paymentMethods.map { ($0.id, $0.name) }
                + snapshot.dataset.cards.map { ($0.id, $0.name) }),
            currencies: Dictionary(
              snapshot.dataset.paymentMethods.map { ($0.id, $0.mainCurrency) },
              uniquingKeysWith: { first, _ in first }),
            warrantyNames: untitledWarranty, environment)
        )
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: WorthALookNoteText.symbol(note))
      }
      .appFont(.callout)
      .foregroundStyle(
        WorthALookNoteText.isAlarm(note) ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
      HStack(spacing: 8) {
        ForEach(WorthALookNoteText.actions(note), id: \.self) { action in
          Button(environment.language(action.key, table: WorthALookNoteText.table)) {
            perform(action)
          }
          .accessibilityIdentifier("look.\(action.rawValue)")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("look.note")
    .onAppear {
      if case .burnout = note { BurnoutShowing.shown(.standard, today: snapshot.today) }
    }
  }

  /// The name of a purchase without a note, for a line about its warranty: «Покупка 29 октября».
  private var untitledWarranty: [UUID: String] {
    guard case .warranty(let reminder) = note, reminder.titleIsMissing,
      let entry = snapshot.dataset.entries.first(where: { $0.id == reminder.transactionId })
    else { return [:] }
    return [
      reminder.transactionId: WarrantyText.name(
        nil, occurredAt: entry.transaction.occurredAt, environment)
    ]
  }

  private func names(_ pairs: [(UUID, String)]) -> [UUID: String] {
    Dictionary(pairs, uniquingKeysWith: { first, _ in first })
  }

  private func perform(_ action: WorthALookNoteText.Action) {
    switch action {
    case .done:
      if case .warranty(let reminder) = note {
        DebtReminderMarks.dismiss(reminder.id, in: .standard)
        settle()
        return
      }
      if case .bank(let bankNote) = note {
        DebtReminderMarks.dismiss(bankNote.id, in: .standard)
        settle()
        return
      }
      guard case .debt(let reminder) = note else { return }
      if case .creditHistory(let half) = reminder {
        DebtReminderMarks.creditHistoryDone(half, in: .standard)
      } else {
        DebtReminderMarks.dismiss(reminder.id, in: .standard)
      }
      settle()
    case .stopCreditHistory:
      UserDefaults.standard.set(false, forKey: DebtReminderMarks.creditHistoryEnabledKey)
      settle()
    case .openDebts:
      NotificationCenter.default.post(
        name: .selectSection, object: MainWindow.Section.debts.shortcutIndex)
    case .openAccount:
      if case .bank(let bankNote) = note {
        switch bankNote {
        case .limitNear(let id, _, _, _), .limitExceeded(let id, _, _, _),
          .minBalanceBelow(let id, _, _, _), .cardExpiry(let id, _, _, _, _):
          NotificationCenter.default.post(
            name: .openSidebarItem, object: SidebarItem.account(id))
        default: break
        }
        return
      }
      guard case .debt(let reminder) = note else { return }
      switch reminder {
      case .cardPayBy(let accountId, _, _, _), .cardGraceMissed(let accountId, _, _),
        .cardOverLimit(let accountId, _):
        NotificationCenter.default.post(
          name: .openSidebarItem, object: SidebarItem.account(accountId))
      default: break
      }
    case .pay:
      if case .npdDue(let month) = note { open(.pay(month)) }
    case .openPlanning:
      NotificationCenter.default.post(
        name: .selectSection, object: MainWindow.Section.planning.shortcutIndex)
    case .allocate:
      if case .allocate(let incomeId, _, _) = note {
        open(.allocate(AllocationRequest(incomeId: incomeId)))
      }
    case .putAway:
      if case .monthRest(let offer) = note { open(.monthRest(offer)) }
    case .decline:
      guard let dependencies else { return }
      let actions = AllocationActions(dependencies)
      switch note {
      case .allocate(let incomeId, _, _): if actions.decline(incomeId) { settled(note.id) }
      case .monthRest(let offer): if actions.decline(offer) { settled(note.id) }
      default: break
      }
    case .hideBurnout:
      BurnoutShowing.turnOff(.standard)
      settled(note.id)
    case .openBank:
      guard case .bank(let bankNote) = note,
        let bankId = WorthALookNoteText.bankId(of: bankNote, snapshot)
      else { return }
      NotificationCenter.default.post(name: .openSidebarItem, object: SidebarItem.bank(bankId))
    case .openForgotten:
      open(.forgotten)
    case .rebind:
      if case .bank(.cardExpiry(_, let cardId, _, _, _)) = note { open(.rebind(cardId)) }
    case .openDeposits:
      open(.showcase)
    case .openWarranty:
      open(.warranty)
    case .openSettings:
      #if os(macOS)
        openSettings()
      #else
        NotificationCenter.default.post(name: .openAppScreen, object: AppScreen.settings)
      #endif
    }
  }

  /// A mark of this Mac changed: the line goes now, and the data is read again for the rest.
  private func settle() {
    settled(note.id)
    compute.refreshLight()
  }
}
