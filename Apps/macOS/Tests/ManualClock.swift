import Foundation

@testable import OhMyMoney

/// A clock whose limit passes when the test says so (`AppQuit.Clock`).
@MainActor
final class ManualClock {
  private var pending: [@MainActor () -> Void] = []

  var clock: AppQuit.Clock {
    { [self] _, fire in pending.append(fire) }
  }

  /// Every limit armed so far passes now.
  func fire() {
    let due = pending
    pending = []
    for fire in due { fire() }
  }
}

/// A stop that waits until the test lets it go.
@MainActor
final class Gate {
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var isOpen = false

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  func open() {
    isOpen = true
    let resumed = waiting
    waiting = []
    for continuation in resumed { continuation.resume() }
  }
}
