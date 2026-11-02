import AppCore
import AppIntents
import Foundation

/// The actions of «Быстрые команды» on the phone. Off: they wait for the paid developer account
/// the App Store needs (Siri and the system's actions on the phone are switched on together
/// with it); the code and its tests are ready, and this switch is all that turns them on.
enum PhoneIntents {
  static let isEnabled = false
}

/// «Передать сообщение банка» on the phone: an automation of «Быстрые команды» on an incoming
/// SMS from a bank hands its text in. The phone offers, never writes at once: the operation
/// waits in «Запишу потом», where the owner writes it with one tap (the entry line on the
/// phone asks what the Mac's would). The text is read and forgotten; only the line is kept.
struct PhoneBankMessageIntent: AppIntent {
  static let title = LocalizedStringResource("intent.bankMessage.title", table: "AutoEntry")
  static let description = IntentDescription(
    LocalizedStringResource("intent.bankMessage.description", table: "AutoEntry"))
  static let openAppWhenRun = false
  static var isDiscoverable: Bool { PhoneIntents.isEnabled }

  @Parameter(title: LocalizedStringResource("intent.bankMessage.text", table: "AutoEntry"))
  var text: String

  struct Refusal: Error, CustomLocalizedStringResourceConvertible {
    let text: String
    var localizedStringResource: LocalizedStringResource {
      LocalizedStringResource(stringLiteral: text)
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    switch await PhoneAutoEntry.receive(text, dependencies: PhoneAutoEntry.waitForApp()) {
    case .done(let said):
      return .result(
        value: said, dialog: IntentDialog(LocalizedStringResource(stringLiteral: said)))
    case .refused(let said):
      throw Refusal(text: said)
    }
  }
}

/// What a text of a bank becomes on the phone.
@MainActor
enum PhoneAutoEntry {
  enum Outcome: Equatable {
    case done(String)
    case refused(String)
  }

  /// A launch by «Быстрые команды» opens the base a moment later: wait for the first figures.
  static func waitForApp() async -> AppDependencies? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while clock.now < deadline {
      if let dependencies = AppLaunch.startedDependencies,
        dependencies.compute.wholeSnapshot != nil
      {
        return dependencies
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return AppLaunch.startedDependencies
  }

  static func receive(
    _ text: String, dependencies: AppDependencies?, enabled: Bool = PhoneIntents.isEnabled
  ) -> Outcome {
    let language = dependencies?.environment.language ?? AppLanguage()
    func t(_ key: String) -> String { language(key, table: AutoEntryWords.table) }
    guard enabled else { return .refused(t("autoEntry.phoneOff")) }
    guard let dependencies, let snapshot = dependencies.compute.wholeSnapshot else {
      return .refused(t("autoEntry.notReady"))
    }
    let environment = dependencies.environment
    if environment.lock.isLocked { return .refused(t("autoEntry.locked")) }
    if environment.shield.isReadOnly { return .refused(t("autoEntry.readOnly")) }
    guard let reading = AutoEntryReading(text, environment: environment, snapshot: snapshot) else {
      return .refused(t("autoEntry.notBank"))
    }
    if reading.isInBooks || reading.isWaiting(environment: environment) {
      return .done(t("autoEntry.duplicate"))
    }
    guard reading.keepDraft(environment: environment, now: environment.now()) != nil else {
      return .refused(environment.language("entry.error.notSaved", table: "Entry"))
    }
    AppLog.info("autoEntry.phone", .db, "a text of a bank waits in the drafts")
    let words = AutoEntryWords(environment: environment)
    if reading.isHidden { return .done(words.t("autoEntry.proposed.hidden")) }
    return .done(
      words.f(
        "autoEntry.proposed",
        words.subject(
          name: reading.placeName, operation: reading.message.operation,
          money: reading.message.money, saysAmount: !environment.amounts.isHidingNow)))
  }
}
