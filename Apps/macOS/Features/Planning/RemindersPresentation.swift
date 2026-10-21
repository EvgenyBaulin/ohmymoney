import AppCore
import Foundation
import SwiftUI

/// What the main window shows of the reminders sheet when the reminders of the day are counted:
/// the daily reminders once a day, and — at every launch, once — the due dates passed and
/// unpaid, which are money the free sum counts as not yet gone until the owner says what
/// happened to them. The words of the decision, apart from the window, so a test can hold it.
struct RemindersPresentation: Equatable {
  /// The daily reminders the sheet lists; empty when only the overdue section is asked.
  var daily: [Reminder]
  /// The sheet opens with «Просроченные платежи» on top.
  var asksOverdue: Bool

  /// The sheet to show, or `nil` for none.
  ///
  /// * `daily` are shown when there are any and they were not shown today (`shownToday`);
  /// * `overdue` are asked about when there are any and they were not asked this launch
  ///   (`askedThisLaunch`), whatever the daily ones did — a reminder put off hides no overdue
  ///   due date;
  /// * `suppressed` — the launch said «no reminders» — shows nothing at all;
  /// * `locked` — the app is locked: nothing is decided, marked shown or asked until it is
  ///   unlocked, so no sheet stands over the cover (`PrivacyLock.lets`).
  static func decide(
    daily: [Reminder], overdue: [OverdueDue], shownToday: Bool, askedThisLaunch: Bool,
    suppressed: Bool = false, locked: Bool = false
  ) -> RemindersPresentation? {
    guard !suppressed, !locked else { return nil }
    let showsDaily = !daily.isEmpty && !shownToday
    let asks = !overdue.isEmpty && !askedThisLaunch
    guard showsDaily || asks else { return nil }
    return RemindersPresentation(daily: showsDaily ? daily : [], asksOverdue: asks)
  }

  /// Whether the day's reminders are marked shown by this sheet.
  var marksDailyShown: Bool { !daily.isEmpty }
}

// MARK: - The questions after the reminders

/// A question the main window asks by itself once a launch, after the reminders of the day:
/// the debts made before the new terms of debts came, one by one, then — once ever — whether
/// to count the tax of self-employment.
enum LaunchQuestion: Identifiable, Equatable {
  case debtReview([DebtReviewItem])
  case selfEmployment

  var id: String {
    switch self {
    case .debtReview: "debtReview"
    case .selfEmployment: "selfEmployment"
    }
  }
}

extension RemindersPresentation {
  /// The next question to ask, or `nil` for none.
  ///
  /// * `waits` — another question of the window is on screen or still to come (the setup of
  ///   the accounts, a report after a crash, the reminders): one question at a time;
  /// * `locked` — nothing is asked over the cover of the locked app, and nothing is counted
  ///   as asked: it comes after the unlock;
  /// * `suppressed` — the launch said «no reminders»; `dataSet` — a set of synthetic data never
  ///   asks: its debts are not the owner's;
  /// * the old debts first, while some are left to review and they were not asked this launch
  ///   («Позже» asks again next time); then the offer of self-employment, once.
  static func nextQuestion(
    debtReview: [DebtReviewItem], offersSelfEmployment: Bool, asked: Set<String>,
    waits: Bool, locked: Bool, suppressed: Bool = false, dataSet: Bool = false
  ) -> LaunchQuestion? {
    guard !waits, !locked, !suppressed, !dataSet else { return nil }
    if !debtReview.isEmpty, !asked.contains(LaunchQuestion.debtReview([]).id) {
      return .debtReview(debtReview)
    }
    if offersSelfEmployment, !asked.contains(LaunchQuestion.selfEmployment.id) {
      return .selfEmployment
    }
    return nil
  }
}

/// The one offer to count the tax of self-employment: made while it is off and was never
/// offered, once an income was written in a category whose name — or the name of a category
/// above it — speaks of self-employment («самозанятость», «ГПХ», «self-employed»).
enum SelfEmploymentOffer {
  /// The words of a name that mean self-employment, lower case.
  static let words = ["самозан", "гпх", "self-employ", "self employ"]

  static func isSelfEmployedName(_ name: String) -> Bool {
    let folded = name.lowercased()
    return words.contains { folded.contains($0) }
  }

  /// Whether a category or one above it is named as self-employment.
  static func isSelfEmployed(_ categoryId: UUID?, tree: CategoryTree) -> Bool {
    var current = tree.category(categoryId)
    var seen: Set<UUID> = []
    while let category = current, seen.insert(category.id).inserted {
      if isSelfEmployedName(category.name) { return true }
      current = tree.category(category.parentId)
    }
    return false
  }

  static func offers(dataset: Dataset, tree: CategoryTree) -> Bool {
    let settings = dataset.selfEmployment
    guard !settings.enabled, !settings.offered else { return false }
    return dataset.entries.contains { entry in
      entry.transaction.kind == .income && !entry.transaction.isDeleted
        && entry.parts.contains { isSelfEmployed($0.categoryId, tree: tree) }
    }
  }
}

/// The sheets of `LaunchQuestion`, on the root of the main window: shown one at a time, never
/// over the cover of the locked app (`PrivacyLock.presenting`), each once a launch.
struct LaunchQuestionSheets: ViewModifier {
  let deps: AppDependencies
  /// Another question of the window is on screen or still to come.
  let waits: Bool
  @State private var shown: LaunchQuestion?
  /// What was asked this launch, kept for every window of it.
  @MainActor static var asked: Set<String> = []

  func body(content: Content) -> some View {
    content
      .sheet(item: deps.environment.lock.presenting($shown)) { question in
        switch question {
        case .debtReview(let items):
          DebtReviewSheet(items: items).appDependencies(deps)
        case .selfEmployment:
          SelfEmploymentOfferSheet().appDependencies(deps)
        }
      }
      .onChange(of: deps.compute.generation, initial: true) { _, _ in ask() }
      .onChange(of: waits) { _, _ in ask() }
      .onChange(of: deps.environment.lock.isCovered) { _, _ in ask() }
  }

  private func ask() {
    guard shown == nil, !AppEnvironment.isTestHost, let snapshot = deps.compute.snapshot else {
      return
    }
    guard
      let question = RemindersPresentation.nextQuestion(
        debtReview: snapshot.planning.debtReview,
        offersSelfEmployment: SelfEmploymentOffer.offers(
          dataset: snapshot.dataset, tree: snapshot.ledger.tree),
        asked: Self.asked, waits: waits, locked: deps.environment.lock.isCovered,
        suppressed: LaunchOptions.current.suppressesReminders, dataSet: AppPaths.dataSet != nil)
    else { return }
    Self.asked.insert(question.id)
    if question == .selfEmployment { SelfEmploymentOfferSheet.markOffered(deps.environment) }
    shown = question
  }
}

extension View {
  /// The questions of `LaunchQuestion`, after those the window asks first (`waits`).
  func launchQuestions(_ deps: AppDependencies, waits: Bool) -> some View {
    modifier(LaunchQuestionSheets(deps: deps, waits: waits))
  }
}
