import AppCore
import SwiftUI

/// The reminders of the day and the overdue payments, as the sheet that shows them wants them.
struct PhoneReminders: Identifiable {
  let reminders: [Reminder]
  /// The sheet opens with the overdue due dates on top.
  var asksOverdue = false

  var id: Int {
    var hasher = Hasher()
    hasher.combine(reminders)
    hasher.combine(asksOverdue)
    return hasher.finalize()
  }
}

/// The questions the app raises by itself when the phone opens it, in the order of `LaunchGate`
/// — the same the Mac main window keeps: the setup of the accounts, the offer of a report after
/// a crash, the currencies the bank does not publish, the reminders and the overdue payments,
/// then the debts of an old version and the offer of self-employment. Every one is spent only
/// when it was answered; while the app is locked nothing is asked and what stands on screen goes
/// (`PrivacyLock.presenting`, fed by the cover of `AppLock`).
struct PhoneLaunch: ViewModifier {
  let deps: AppDependencies
  let router: PhoneRouter
  @State private var remindersShown: PhoneReminders?

  private var environment: AppEnvironment { deps.environment }
  private var compute: ComputeStore { deps.compute }
  private var guide: GuideStore { GuideStore.shared }

  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
  }

  /// The day the reminders were last shown, per data set: the owner's are never spent on the demo.
  private static var remindersShownKey: String {
    "reminders.shownOn" + (AppPaths.dataSet.map { ".\($0.rawValue)" } ?? "")
  }

  private var remindersDay: Date? {
    if case .ready(_, let at) = compute.states.reminders { return at }
    return nil
  }

  private var asksSetup: Bool { AccountSetupOffer.isUp(environment) }

  /// Where the questions stand now.
  var gate: LaunchGate {
    LaunchGate(
      covered: environment.lock.isCovered, asksSetup: asksSetup,
      offersProblemReport: environment.offersProblemReport,
      currenciesMissing: !environment.currenciesMissingAtBank.isEmpty,
      remindersShown: remindersShown != nil,
      remindersCalculating: compute.states.reminders.phase == .calculating)
  }

  func body(content: Content) -> some View {
    content
      // The cards of the first launch and of «Что нового»; never over the cover of the lock.
      .sheet(item: environment.lock.presenting(Bindable(guide).cards)) { scenario in
        GuideCardsView(scenario: scenario) { skipped in
          guide.cardsDone(version: Self.version, skipped: skipped)
        }
        .appDependencies(deps)
      }
      .onChange(of: environment.state, initial: true) { _, state in
        guard state == .ready else { return }
        guide.begin(
          databaseInUse: environment.accountSetup != nil, version: Self.version,
          dataSet: AppPaths.dataSet)
      }
      .sheet(item: environment.lock.presenting($remindersShown)) { shown in
        RemindersSheet(reminders: shown.reminders, asksOverdue: shown.asksOverdue) {
          router.open(section: $0)
        }
        .appDependencies(deps)
      }
      // After the reminders, one at a time: the debts made before 1.9, the offer of
      // self-employment.
      .launchQuestions(deps, waits: gate.questionsWait)
      .onChange(of: environment.showsOverdue) { _, _ in showOverdue() }
      .alert(
        environment.language("replacement.notApplied.title"),
        isPresented: Binding(
          get: {
            environment.lock.lets(
              AccountSetupOffer.lets(
                environment.replacementProblem == .notApplied, asksSetup: asksSetup))
          },
          set: { if !$0, !environment.lock.isCovered { environment.replacementProblem = nil } })
      ) {
        Button(environment.language("replacement.giveUp"), role: .destructive) {
          AppPaths.discardPendingReplacement()
        }
        Button(environment.language("action.ok")) {}
      } message: {
        Text(verbatim: environment.language("replacement.notApplied.message"))
      }
      .alert(
        environment.language("replacement.refused.title"),
        isPresented: Binding(
          get: {
            environment.lock.lets(
              AccountSetupOffer.lets(
                environment.replacementProblem == .refused, asksSetup: asksSetup))
          },
          set: { if !$0, !environment.lock.isCovered { environment.replacementProblem = nil } })
      ) {
        Button(environment.language("action.ok")) {}
      } message: {
        Text(verbatim: environment.language("replacement.refused.message"))
      }
      // «После импорта приложение просит заново выбрать папку для копий»: the folder is chosen
      // in «Ещё».
      .alert(
        environment.language("backups.afterImport.title", table: "Settings"),
        isPresented: Binding(
          get: {
            environment.lock.lets(
              AccountSetupOffer.lets(environment.asksForMirrorFolder, asksSetup: asksSetup))
          },
          set: { if !$0, !environment.lock.isCovered { environment.asksForMirrorFolder = false } })
      ) {
        Button(environment.language("settings.backups.choose", table: "Settings")) {
          router.open(PhoneRoute(tab: .more))
        }
        Button(environment.language("backups.afterImport.later", table: "Settings"), role: .cancel)
        {}
      } message: {
        Text(verbatim: environment.language("backups.afterImport.message", table: "Settings"))
      }
      .onChange(of: remindersDay) { _, _ in showRemindersOnce() }
      // What waited for the unlock is asked now.
      .onChange(of: environment.lock.isCovered) { _, covered in
        if !covered { showRemindersOnce() }
      }
      // The first question: the setup of the accounts, while it is due.
      .modifier(AccountSetupOffer(deps: deps))
      .onChange(of: asksSetup) { _, asks in
        if !asks { showRemindersOnce() }
      }
      .background {
        if AccountSetupOffer.letsReportOffer(environment, setupIsUp: asksSetup) {
          Color.clear.modifier(ProblemReportOffer(deps: deps))
        }
      }
      .onChange(of: environment.offersProblemReport) { _, offers in
        if !offers { showRemindersOnce() }
      }
      .modifier(CurrencyNotice(deps: deps, waits: gate.currencyNoticeWaits))
      .onChange(of: environment.currenciesMissingAtBank) { _, missing in
        if missing.isEmpty { showRemindersOnce() }
      }
  }

  /// The reminders of the day once a day, and the due dates passed and unpaid at every launch
  /// (`RemindersPresentation`).
  private func showRemindersOnce() {
    guard case .ready(let reminders, _) = compute.states.reminders,
      !AppEnvironment.isTestHost, remindersShown == nil, gate.allowsReminders
    else { return }
    let today = environment.today.iso
    let defaults = UserDefaults.standard
    let overdue = compute.snapshot?.planning.overdue ?? []
    guard
      let shown = RemindersPresentation.decide(
        daily: reminders, overdue: overdue,
        shownToday: defaults.string(forKey: Self.remindersShownKey) == today,
        askedThisLaunch: environment.overdueAskedThisLaunch,
        suppressed: LaunchOptions.current.suppressesReminders, locked: environment.lock.isCovered)
    else { return }
    if shown.marksDailyShown { defaults.set(today, forKey: Self.remindersShownKey) }
    if shown.asksOverdue {
      environment.overdueAskedThisLaunch = true
      AppLog.info(
        "reminders.overdue.asked", .ui, "the overdue due dates were asked about",
        [
          LogPair("scheduled", .count(overdue.filter { !$0.isDebt }.count)),
          LogPair("debts", .count(overdue.filter(\.isDebt).count)),
        ])
    }
    remindersShown = PhoneReminders(reminders: shown.daily, asksOverdue: shown.asksOverdue)
  }

  /// «Разобрать…» of the free sum: the overdue section alone, whatever was asked at launch.
  private func showOverdue() {
    guard environment.showsOverdue else { return }
    environment.showsOverdue = false
    guard remindersShown == nil else { return }
    remindersShown = PhoneReminders(reminders: [], asksOverdue: true)
  }
}
