import AppCore
import Foundation
import Observation

/// The guide's memory on this Mac (`GuideProgress`, `UserDefaults` — never the database, never
/// the archive) and what it is showing now: the cards of the first launch or of «Что нового», the
/// tutorial's tasks, the place it points at step by step. Nothing leaves the device; the journal gets ids
/// and counts.
@MainActor @Observable
final class GuideStore {
  /// The one store of the app. A test may put a store of its own here — one on a set of
  /// defaults of its own, in the tutorial — to watch what the views report, and put the app's
  /// back after.
  static var shared = GuideStore()

  /// The key of the memory. The Debug build has a domain of its own, so its guide is its own.
  static let progressKey = "guide.progress"
  /// What the tutorial's set held when it was made: the tasks count what came after.
  static let baselineKey = "guide.tutorial.baseline"
  /// «Начать заново» asks the next launch to make the tutorial's set anew.
  static let restartKey = "guide.tutorial.restart"

  @ObservationIgnored private let defaults: UserDefaults

  private(set) var progress: GuideProgress
  /// The cards on screen: the first launch's, a version's «Что нового», or none.
  var cards: GuideScenario?
  /// The place the guide points at now, one step at a time: the window darkened around it, the
  /// words beside it. Nil when it points at nothing.
  private(set) var walk: GuideWalkthrough?
  /// The places each root of the main window shows now, by the root: a step whose place is in
  /// none of them gets its words in the middle, and the window is not closed to clicks.
  private(set) var placesShown: [String: Set<String>] = [:]
  /// The cards «Показать, где» put aside, and the card it was on: they come back when the walk
  /// ends.
  @ObservationIgnored private var cardsAside: (scenario: GuideScenario, index: Int)?
  /// The card the next cards open on.
  @ObservationIgnored private var cardToOpen: (scenario: String, index: Int)?

  /// «Показать, куда нажимать» is on: the places of the window, one after another.
  var showsWhereToClick: Bool {
    get { walk?.source == .whereToClick }
    set {
      if newValue {
        start(.whereToClick())
      } else if showsWhereToClick {
        endWalk()
      }
    }
  }

  /// The task whose places the guide points at.
  var framedTask: String? {
    get {
      if case .task(let id) = walk?.source { return id }
      return nil
    }
    set {
      if let newValue {
        start(
          GuideCatalog.tutorial.tasks.first { $0.id == newValue }.flatMap(
            GuideWalkthrough.init(task:)))
      } else if framedTask != nil {
        endWalk()
      }
    }
  }

  init(
    defaults: UserDefaults = AppEnvironment.isTestHost ? GuideStore.testDefaults : .standard,
    tutorial: Bool? = nil
  ) {
    self.defaults = defaults
    tutorialOverride = tutorial
    if let data = defaults.data(forKey: Self.progressKey),
      let stored = try? JSONDecoder().decode(GuideProgress.self, from: data)
    {
      progress = stored
      hasMemory = true
    } else {
      progress = GuideProgress()
      hasMemory = false
    }
  }

  /// The test host never reads or writes the owner's guide.
  static let testDefaults = UserDefaults(suiteName: "ohmymoney.tests.guide") ?? .standard

  /// Whether the memory was there when the app started: without it the start decides whether
  /// this Mac is new to the app (`begin(databaseInUse:)`).
  @ObservationIgnored private var hasMemory: Bool

  /// Whether the tutorial is on, when the store was told so instead of reading the launch: a
  /// test runs on no set, and asks for the tutorial this way.
  @ObservationIgnored private let tutorialOverride: Bool?

  /// The tutorial is on: the app runs on its set.
  var isTutorial: Bool { tutorialOverride ?? (AppPaths.dataSet == .learn) }

  private func save() {
    guard let data = try? JSONEncoder().encode(progress) else { return }
    defaults.set(data, forKey: Self.progressKey)
  }

  // MARK: Cards

  /// At the start of the main window: the first launch's cards on a new database, else a
  /// version's «Что нового» once, else nothing. Never on a set of synthetic data — their windows
  /// say «SAMPLE» and are nobody's first launch — and never in the test host.
  func begin(
    databaseInUse: Bool, version: String, dataSet: AppPaths.DataSet?,
    isTestHost: Bool = AppEnvironment.isTestHost
  ) {
    guard !isTestHost, dataSet == nil, cards == nil else { return }
    if !hasMemory {
      progress = GuideProgress.starting(onADatabaseInUse: databaseInUse)
      hasMemory = true
      save()
    }
    if progress.firstLaunchDue() {
      cards = GuideCatalog.firstLaunch
      AppLog.info("guide.firstLaunchShown", .ui, "the cards of the first launch are shown")
      return
    }
    if let due = progress.whatsNewDue(current: version, catalog: GuideCatalog.whatsNew).last {
      cards = due
      AppLog.info(
        "guide.whatsNewShown", .ui, "the cards of what is new are shown",
        [LogPair("cards", .count(due.cards.count))])
    }
  }

  /// The cards were seen through or skipped: they do not come again for this version.
  func cardsDone(version: String, skipped: Bool) {
    guard let shown = cards else { return }
    if case .firstLaunch = shown.kind {
      progress.firstLaunchWasShown(in: version)
    } else {
      progress.whatsNewSeen = version
    }
    save()
    cards = nil
    AppLog.info(
      "guide.cardsClosed", .ui, "the cards of the guide were closed",
      [LogPair("skipped", .flag(skipped))])
  }

  /// «Справка → Знакомство с OhMyMoney» and «Справка → Что нового»: the cards again, on demand.
  func show(_ scenario: GuideScenario) {
    cards = scenario
  }

  /// «Показать, где» of a card: the cards step aside, the window darkens around the card's
  /// place, and when the walk ends the cards come back on the same card.
  func showOnScreen(card index: Int, of scenario: GuideScenario) {
    guard scenario.cards.indices.contains(index),
      let walk = GuideWalkthrough(card: scenario.cards[index])
    else { return }
    cardsAside = (scenario, index)
    cards = nil
    start(walk)
  }

  /// The card the cards of `scenario` open on: the one «Показать, где» left, once; else the
  /// first.
  func takeCardIndex(for scenario: GuideScenario) -> Int {
    defer { cardToOpen = nil }
    guard let open = cardToOpen, open.scenario == scenario.id,
      scenario.cards.indices.contains(open.index)
    else { return 0 }
    return open.index
  }

  // MARK: Pointing at places

  /// Points at the first step of `walk`; nil points at nothing.
  func start(_ walk: GuideWalkthrough?) {
    self.walk = walk
    guard let walk else { return }
    AppLog.info(
      "guide.walkStarted", .ui, "the guide points at the places of a walk",
      [
        LogPair("source", .token(Self.token(walk.source))),
        LogPair("steps", .count(walk.steps.count)),
      ])
  }

  /// «Далее»: the next step, or the end after the last.
  func next() {
    guard var walk else { return }
    switch walk.next() {
    case .moved: self.walk = walk
    case .finished, .ignored: endWalk()
    }
  }

  /// A click on the place `target` while the guide points at it: the control under it did its
  /// work, and the walk moves on when the step is a click.
  func clicked(_ target: String) {
    guard var walk else { return }
    switch walk.clicked(target) {
    case .moved: self.walk = walk
    case .finished: endWalk()
    case .ignored: break
    }
  }

  /// Esc, «Готово» or the last click: the window lit again, and the cards a card's «Показать,
  /// где» put aside come back.
  func endWalk() {
    guard let ended = walk else { return }
    walk = nil
    AppLog.info(
      "guide.walkEnded", .ui, "the guide points at nothing",
      [
        LogPair("source", .token(Self.token(ended.source))),
        LogPair("step", .count(ended.position.number)),
      ])
    if let aside = cardsAside {
      cardsAside = nil
      cardToOpen = (aside.scenario.id, aside.index)
      cards = aside.scenario
    }
  }

  /// The places a root of the main window shows now.
  func placesShown(_ ids: Set<String>, in root: String) {
    guard placesShown[root] != ids else { return }
    placesShown[root] = ids
  }

  /// Whether some root of the window shows the place.
  func isShown(_ target: String) -> Bool {
    placesShown.values.contains { $0.contains(target) }
  }

  private static func token(_ source: GuideWalkthrough.Source) -> String {
    switch source {
    case .task: "task"
    case .whereToClick: "whereToClick"
    case .card: "card"
    }
  }

  // MARK: Tips

  var tipsOff: Bool {
    get { progress.tipsOff }
    set {
      progress.tipsOff = newValue
      save()
    }
  }

  // MARK: Tutorial

  /// What the app did, while the tutorial is on: kept with the progress and checked at once.
  func report(_ event: String) {
    guard isTutorial, GuideEvent.all.contains(event), !progress.events.contains(event) else {
      return
    }
    progress.events.insert(event)
    save()
    AppLog.info(
      "guide.event", .ui, "the tutorial heard of an action", [LogPair("event", .token(event))])
  }

  /// The tasks found done by what the set now holds.
  func check(_ dataset: Dataset) {
    guard isTutorial else { return }
    let baseline = baseline(of: dataset)
    let fresh = progress.record(
      GuideFactsReader.facts(of: dataset, since: baseline), tasks: progress.tutorialTasks)
    guard !fresh.isEmpty else { return }
    save()
    if framedTask.map(fresh.contains) == true { endWalk() }
    AppLog.info(
      "guide.tasksDone", .ui, "tasks of the tutorial were found done",
      [
        LogPair("done", .count(progress.progress(of: progress.tutorialTasks).done)),
        LogPair("fresh", .count(fresh.count)),
      ])
  }

  /// The tasks and how many are done: «3 из 10». The tasks follow the starter set remembered.
  var tutorial: (tasks: [GuideTask], done: Int) {
    let tasks = progress.tutorialTasks
    return (tasks, progress.progress(of: tasks).done)
  }

  /// The starter set the owner applied, remembered for the tutorial's tasks — on this Mac, with
  /// the rest of the guide's memory. The last one applied is the one remembered.
  func remember(_ choice: StarterChoice) {
    progress.profile = GuideProfile(
      lifestyleNames: choice.lifestyles.map(\.rawValue), hasLoans: choice.hasLoans,
      hasSubscriptions: choice.hasSubscriptions, tracksCashback: choice.tracksCashback,
      wantsACushion: choice.wantsACushion)
    save()
    AppLog.info(
      "guide.starterRemembered", .ui, "the starter set was remembered for the tutorial",
      [LogPair("tasks", .count(progress.tutorialTasks.count))])
  }

  func isDone(_ task: GuideTask) -> Bool { progress.tasksDone.contains(task.id) }

  /// What the set held when the tutorial began: the first time the set is checked after it was
  /// made, it is what the set holds then.
  private func baseline(of dataset: Dataset) -> GuideBaseline {
    if let data = defaults.data(forKey: Self.baselineKey),
      let stored = try? JSONDecoder().decode(GuideBaseline.self, from: data)
    {
      return stored
    }
    let made = GuideBaseline(of: dataset, at: Date())
    if let data = try? JSONEncoder().encode(made) { defaults.set(data, forKey: Self.baselineKey) }
    return made
  }

  /// «Начать заново»: the tasks forgotten and the set made anew at the next launch.
  func restartTutorial() {
    progress.restartTutorial()
    save()
    defaults.removeObject(forKey: Self.baselineKey)
    defaults.set(true, forKey: Self.restartKey)
    AppLog.info("guide.tutorialRestarted", .ui, "the tutorial is begun anew")
  }

  /// Whether the launch makes the tutorial's set anew; asked once.
  func takeRestart() -> Bool {
    let asked = defaults.bool(forKey: Self.restartKey)
    defaults.removeObject(forKey: Self.restartKey)
    return asked
  }

  /// A freshly made set starts the count of the tasks again.
  func setWasMade() {
    defaults.removeObject(forKey: Self.baselineKey)
  }
}

/// What the tutorial's set held when the tutorial began. The debts, goals and cashback rules
/// came later: a baseline kept from before them has none, and they count from when it is read.
struct GuideBaseline: Codable, Hashable {
  var startedAt: Date
  var scheduled: Int
  var counts: Int
  var transfers: Int
  var debts: Int?
  var goals: Int?
  var cashbackRules: Int?

  init(of dataset: Dataset, at moment: Date) {
    startedAt = moment
    scheduled = dataset.planning.scheduled.count
    counts = dataset.planning.reconciliations.count
    transfers = dataset.transfers.count
    debts = dataset.debts.count
    goals = dataset.goals.count
    cashbackRules = dataset.cashbackRules.count
  }
}

/// The facts the tasks are checked against, read from the set.
enum GuideFactsReader {
  static func facts(of dataset: Dataset, since baseline: GuideBaseline) -> GuideFacts {
    var facts = GuideFacts()
    for entry in dataset.entries
    where !entry.transaction.isDeleted && entry.transaction.externalId == nil {
      let transaction = entry.transaction
      if transaction.createdAt > baseline.startedAt {
        let words = ([transaction.note] + entry.parts.map(\.note)).compactMap { $0 }
          .joined(separator: " ")
        facts.operations.append(
          GuideOperation(
            text: words, amountE4: transaction.amountE4.raw, currency: transaction.currency,
            kind: transaction.kind,
            forSomebodyElse: entry.parts.contains { $0.reimbursable || $0.forPersonId != nil }
              || transaction.debtId != nil))
      } else if transaction.updatedAt > baseline.startedAt,
        entry.parts.contains(where: { $0.categorySource == .manual })
      {
        facts.events.insert(GuideEvent.categoryChanged)
      }
    }
    facts.scheduledPaymentsAdded = max(0, dataset.planning.scheduled.count - baseline.scheduled)
    facts.countsMade = max(0, dataset.planning.reconciliations.count - baseline.counts)
    facts.transfersAdded = max(0, dataset.transfers.count - baseline.transfers)
    facts.debtsAdded = max(0, dataset.debts.count - (baseline.debts ?? dataset.debts.count))
    facts.goalsAdded = max(0, dataset.goals.count - (baseline.goals ?? dataset.goals.count))
    facts.cashbackRulesAdded = max(
      0, dataset.cashbackRules.count - (baseline.cashbackRules ?? dataset.cashbackRules.count))
    return facts
  }
}
