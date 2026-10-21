import Foundation

/// The number of one full run. The caller creates it — the app does so synchronously on the
/// main thread, where ⌘R is pressed — and ids only grow. Two calls made in order on the
/// main thread can still reach the pipeline actor in the opposite order, so the pipeline
/// ignores an id that is not newer than the last one it accepted.
public struct RunID: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let rawValue: UInt64

  public init(_ rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public static let first = RunID(1)

  public var next: RunID { RunID(rawValue &+ 1) }

  public static func < (lhs: RunID, rhs: RunID) -> Bool { lhs.rawValue < rhs.rawValue }

  public var description: String { "run \(rawValue)" }
}

/// The name of one step: «rates», «data», «forecast». Plain strings, so the app names its
/// steps without the core knowing them.
public struct StepID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public var description: String { rawValue }
}

public enum PipelineError: Error, Equatable, Sendable {
  /// A step asked for the result of a step it does not depend on, or of one that gave a
  /// value of another type.
  case missingInput(StepID)
}

/// What a step receives: the run it belongs to and the results of the steps it depends on.
public struct PipelineInputs: Sendable {
  public let runID: RunID
  private let values: [StepID: any Sendable]

  public init(runID: RunID, values: [StepID: any Sendable] = [:]) {
    self.runID = runID
    self.values = values
  }

  public func value<T>(of step: StepID, as type: T.Type = T.self) throws -> T {
    guard let value = values[step] as? T else { throw PipelineError.missingInput(step) }
    return value
  }

  public var stepIDs: Set<StepID> { Set(values.keys) }
}

/// One node of the graph. A step without dependencies starts as soon as the run starts; a
/// step with dependencies starts as soon as all of them have succeeded, without waiting
/// for the steps it does not depend on.
public struct PipelineStep: Sendable {
  public let id: StepID
  public let dependsOn: [StepID]
  public let run: @Sendable (PipelineInputs) async throws -> any Sendable

  public init(
    _ id: StepID, dependsOn: [StepID] = [],
    run: @escaping @Sendable (PipelineInputs) async throws -> any Sendable
  ) {
    self.id = id
    self.dependsOn = dependsOn
    self.run = run
  }
}

/// Why a step failed, without the error value itself: errors are not all `Sendable`, and a
/// type name and a description are what the app shows and logs (never amounts or names —
/// the steps throw their own error types, whose descriptions carry none).
public struct StepFailure: Hashable, Sendable, CustomStringConvertible {
  public let type: String
  public let message: String

  public init(type: String, message: String) {
    self.type = type
    self.message = message
  }

  public init(_ error: any Error) {
    self.type = String(describing: Swift.type(of: error))
    self.message = String(describing: error)
  }

  public var description: String { type }
}

/// What happened to one step of one run.
public enum StepOutcome: Sendable {
  case running
  case succeeded(any Sendable)
  case failed(StepFailure)
  /// A step it depends on failed, was skipped or was cancelled, so it never started.
  case skipped(dependencyFailed: StepID)
  /// The run was cancelled — by a newer run or by `cancel()` — before the step finished.
  case cancelled

  public enum Kind: String, Hashable, Sendable {
    case running, succeeded, failed, skipped, cancelled
  }

  public var kind: Kind {
    switch self {
    case .running: .running
    case .succeeded: .succeeded
    case .failed: .failed
    case .skipped: .skipped
    case .cancelled: .cancelled
    }
  }

  /// `running` is the only outcome that is followed by another one for the same step.
  public var isFinal: Bool { kind != .running }

  public func value<T>(as type: T.Type = T.self) -> T? {
    guard case .succeeded(let value) = self else { return nil }
    return value as? T
  }
}

public struct PipelineEvent: Sendable, CustomStringConvertible {
  public let runID: RunID
  public let stepID: StepID
  public let outcome: StepOutcome
  public let at: Date

  public init(runID: RunID, stepID: StepID, outcome: StepOutcome, at: Date) {
    self.runID = runID
    self.stepID = stepID
    self.outcome = outcome
    self.at = at
  }

  public var description: String { "\(runID) \(stepID) \(outcome.kind.rawValue)" }
}
