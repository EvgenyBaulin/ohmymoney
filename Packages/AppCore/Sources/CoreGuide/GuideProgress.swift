import Foundation

/// What the app tells the guide happened: tokens, as in the log — no amounts, no names.
public enum GuideEvent {
  /// The category of a saved operation was changed by hand.
  public static let categoryChanged = "category.changed"
  /// The search of «Операции» was used.
  public static let searched = "transactions.searched"
  /// «Свободная сумма» of Planning was on the screen.
  public static let freeToSpendSeen = "planning.freeToSpend.seen"
  /// «Операции» of the sidebar was opened. The value is the one it had when the screen was
  /// called «Траты»: progress kept on this Mac already holds it.
  public static let operationsOpened = "spending.opened"
  /// The tile «График валюты» was on the screen.
  public static let currencyChartSeen = "overview.currencyChart.seen"
  /// A transfer was written from the entry line («перевод 5000 сбер т-банк»).
  public static let transferFromLine = "entry.transferFromLine"

  public static let all: Set<String> = [
    categoryChanged, searched, freeToSpendSeen, operationsOpened, currencyChartSeen,
    transferFromLine,
  ]
}

/// The guide's memory on this device: never in the database, never in the archive, never sent
/// anywhere. Codable, so the app keeps it as one value in its settings.
public struct GuideProgress: Hashable, Sendable, Codable {
  /// The cards of the first launch were shown — or skipped, which counts the same.
  public var firstLaunchShown: Bool
  /// The last version whose «Что нового» was shown; nil before the first.
  public var whatsNewSeen: String?
  /// Tasks of the tutorial found done.
  public var tasksDone: Set<String>
  /// Events the app reported while the tutorial was on.
  public var events: Set<String>
  /// «Больше не показывать подсказки».
  public var tipsOff: Bool
  /// What the owner told the starter set last, for the tasks of the tutorial; nil before he
  /// applied one. A memory written before the set was remembered reads as nil.
  public var profile: GuideProfile?

  public init(
    firstLaunchShown: Bool = false, whatsNewSeen: String? = nil, tasksDone: Set<String> = [],
    events: Set<String> = [], tipsOff: Bool = false, profile: GuideProfile? = nil
  ) {
    self.firstLaunchShown = firstLaunchShown
    self.whatsNewSeen = whatsNewSeen
    self.tasksDone = tasksDone
    self.events = events
    self.tipsOff = tipsOff
    self.profile = profile
  }

  /// The tasks of the tutorial for the starter set remembered.
  public var tutorialTasks: [GuideTask] { GuideCatalog.tutorialTasks(for: profile) }

  /// The memory of a device that has none yet. A database already in use means the app was
  /// there before the guide (1.3 or older): its owner gets «Что нового» from 1.4 on, not the
  /// first-launch cards. An empty one is a first launch.
  public static func starting(onADatabaseInUse inUse: Bool) -> GuideProgress {
    inUse ? GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.3") : GuideProgress()
  }

  /// The first-launch cards were shown in `version`: its «Что нового» is not due after them.
  public mutating func firstLaunchWasShown(in version: String) {
    firstLaunchShown = true
    whatsNewSeen = version
  }

  /// Marks every task the facts show done. Done stays done: a task is never taken back.
  /// Returns the ids found done just now.
  @discardableResult
  public mutating func record(_ facts: GuideFacts, tasks: [GuideTask]) -> [String] {
    var merged = facts
    merged.events.formUnion(events)
    var fresh: [String] = []
    for task in tasks where !tasksDone.contains(task.id) && task.done.isMet(by: merged) {
      tasksDone.insert(task.id)
      fresh.append(task.id)
    }
    return fresh
  }

  /// «3 из 8».
  public func progress(of tasks: [GuideTask]) -> (done: Int, total: Int) {
    (tasks.filter { tasksDone.contains($0.id) }.count, tasks.count)
  }

  /// «Начать заново»: the tasks and their events go, the rest — the starter set too — stays.
  public mutating func restartTutorial() {
    tasksDone = []
    events = []
  }

  /// Whether the first-launch cards are due: once, on a new database of a new install.
  public func firstLaunchDue() -> Bool { !firstLaunchShown }

  /// The «Что нового» due after an update to `current`: every scenario of a version above the
  /// one seen last, up to `current`, oldest first. Nothing on a fresh install — the first
  /// launch tells the whole story there — and nothing twice.
  public func whatsNewDue(current: String, catalog: [GuideScenario]) -> [GuideScenario] {
    guard let now = GuideVersion(current) else { return [] }
    guard firstLaunchShown, let seenText = whatsNewSeen else { return [] }
    let seen = GuideVersion(seenText) ?? GuideVersion(major: 0, minor: 0)
    return catalog.compactMap { scenario -> (GuideVersion, GuideScenario)? in
      guard case .whatsNew(let version) = scenario.kind, version > seen, version <= now else {
        return nil
      }
      return (version, scenario)
    }
    .sorted { $0.0 < $1.0 }
    .map(\.1)
  }
}
