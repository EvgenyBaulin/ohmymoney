import AppCore
import Foundation

/// What one block of the screen shows while the pipeline works on it. The views turn the case
/// into «Считается, ожидайте», a message with «Повторить», «Мало данных» or «Появится в …»;
/// only `ready` carries a value.
enum BlockState<Value: Sendable>: Sendable {
  case calculating
  case ready(Value, at: Date)
  /// A localization key: the message never carries amounts, descriptions or names, because
  /// the same words reach the log.
  case failed(messageKey: String)
  case notEnoughData
  /// A block whose calculation arrives with a later version, which `stage` names.
  case plannedFor(stage: String)

  /// The case without its value: what tests compare and what a view switches on when it
  /// does not need the value.
  var phase: BlockPhase {
    switch self {
    case .calculating: .calculating
    case .ready: .ready
    case .failed: .failed
    case .notEnoughData: .notEnoughData
    case .plannedFor: .plannedFor
    }
  }

  var value: Value? {
    guard case .ready(let value, _) = self else { return nil }
    return value
  }

  var readyAt: Date? {
    guard case .ready(_, let at) = self else { return nil }
    return at
  }

  /// The state of a block made from this one's value: `ready` goes through `transform`,
  /// which may also find there is not enough to show; every other state stays as it is. A
  /// card of Overview reads its part of the data step this way — «Хорошие и плохие» turns
  /// into «Мало данных» while the month has no spending.
  func flatMap<Other: Sendable>(
    _ transform: (Value, Date) -> BlockState<Other>
  ) -> BlockState<Other> {
    switch self {
    case .ready(let value, let at): transform(value, at)
    case .calculating: .calculating
    case .failed(let key): .failed(messageKey: key)
    case .notEnoughData: .notEnoughData
    case .plannedFor(let stage): .plannedFor(stage: stage)
    }
  }

  /// The same state for a list that waits for its first data: every case but `ready`, which
  /// a waiting list never is.
  var waiting: BlockState<Never>? {
    switch self {
    case .ready: nil
    case .calculating: .calculating
    case .failed(let key): .failed(messageKey: key)
    case .notEnoughData: .notEnoughData
    case .plannedFor(let stage): .plannedFor(stage: stage)
    }
  }
}

/// A `BlockState` without its value, the same type whatever the block holds.
enum BlockPhase: Hashable, Sendable {
  case calculating, ready, failed, notEnoughData, plannedFor
}

/// The steps of the app's pipeline. Rates and data start together; every other step waits
/// for the data, and the advice for the forecast as well.
enum ComputeStep {
  static let rates: StepID = "rates"
  static let data: StepID = "data"
  static let owed: StepID = "owed"
  static let forecast: StepID = "forecast"
  static let model: StepID = "model"
  static let anomalies: StepID = "anomalies"
  static let advice: StepID = "advice"
  static let reminders: StepID = "reminders"

  /// In their fixed order, from the rates to the reminders.
  static let all: [StepID] = [rates, data, owed, model, forecast, anomalies, advice, reminders]

  /// What each step waits for. The pipeline gets the same graph (`ComputeSources.steps`).
  /// The advice needs the remainder of the month the forecast counts («можно отложить»).
  static let dependencies: [StepID: [StepID]] = [
    owed: [data], forecast: [data], advice: [data, forecast], reminders: [data],
    model: [data], anomalies: [data],
  ]

  /// The version each placeholder arrives with, by step. Nothing is a placeholder any more:
  /// the model and the anomalies were the last two, and both are real now.
  static let stubs: [StepID: String] = [:]

  /// The step and everything that depends on it: what «Повторить» reruns.
  static func scope(of root: StepID) -> Set<StepID> {
    var scope: Set<StepID> = [root]
    var changed = true
    while changed {
      changed = false
      for (step, needs) in dependencies where !scope.contains(step) {
        if needs.contains(where: scope.contains) {
          scope.insert(step)
          changed = true
        }
      }
    }
    return scope
  }

  /// The message of a failed step. Keys only: the words are the app's.
  static func failureKey(_ step: StepID) -> String {
    switch step {
    case rates: "compute.failed.rates"
    case data: "compute.failed.data"
    case owed: "compute.failed.owed"
    case forecast: "compute.failed.forecast"
    case model: "compute.failed.model"
    case anomalies: "compute.failed.anomalies"
    case advice: "compute.failed.advice"
    case reminders: "compute.failed.reminders"
    default: "compute.failed.step"
    }
  }

  static let skippedKey = "compute.skipped"
}

/// Faults the Debug menu injects so the owner can see the placeholders of the pipeline with
/// his own eyes: every step slowed down to three seconds, or a chosen step failing.
/// Inert in a release build — nothing there sets it.
struct PipelineFaults: Hashable, Sendable {
  var slowsDown = false
  var failing: Set<StepID> = []

  static let delay: Duration = .seconds(3)
}

/// The error an injected failure throws. Its description names the step, nothing more.
struct InjectedFault: Error, CustomStringConvertible {
  let step: StepID
  var description: String { "injected failure of \(step)" }
}
