import Foundation

/// The guide pointing at one place at a time: the window darkened around the element of the
/// current step, the words beside it, «Далее» or a click on the element for the next step, Esc
/// to leave. Only the order lives here; how the place is lit is the app's.
public struct GuideWalkthrough: Hashable, Sendable {
  /// What the steps came from.
  public enum Source: Hashable, Sendable {
    /// A task of the tutorial, by its id.
    case task(String)
    /// «Показать, куда нажимать».
    case whereToClick
    /// «Показать, где» of a card, by its id.
    case card(String)
  }

  /// What a move did.
  public enum Move: Hashable, Sendable {
    /// The next step is on.
    case moved
    /// That was the last step: the walk is over.
    case finished
    /// Nothing: the click was not on the place of the step, or the step is typed, not clicked.
    case ignored
  }

  public let source: Source
  public let steps: [GuideHint]
  public private(set) var index: Int

  /// Nil without steps: there is nothing to point at.
  public init?(_ source: Source, steps: [GuideHint]) {
    guard !steps.isEmpty else { return nil }
    self.source = source
    self.steps = steps
    index = 0
  }

  /// The walk of a task of the tutorial.
  public init?(task: GuideTask) {
    self.init(.task(task.id), steps: task.hints)
  }

  /// «Показать, куда нажимать»: every place of the main window, one after another.
  public static func whereToClick() -> GuideWalkthrough? {
    GuideWalkthrough(.whereToClick, steps: GuideCatalog.whereToClick)
  }

  /// «Показать, где» of a card: one step, the card's own words at its place. Nil for a card that
  /// points at nothing.
  public init?(card: GuideCard) {
    guard let target = card.target else { return nil }
    self.init(.card(card.id), steps: [GuideHint(target: target, text: card.title, why: card.body)])
  }

  public var current: GuideHint { steps[index] }
  public var isLast: Bool { index == steps.count - 1 }
  /// «Шаг 2 из 3», counted from one.
  public var position: (number: Int, total: Int) { (index + 1, steps.count) }

  /// «Далее»: the next step, or the end after the last.
  public mutating func next() -> Move {
    guard !isLast else { return .finished }
    index += 1
    return .moved
  }

  /// A click on the element `target`: the next step when it is the place of this one and the
  /// step is a click.
  public mutating func clicked(_ target: String) -> Move {
    guard target == current.target, current.advancesOnClick else { return .ignored }
    return next()
  }
}
