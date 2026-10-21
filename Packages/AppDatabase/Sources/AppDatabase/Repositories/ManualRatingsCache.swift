import AppCore
import Foundation
import GRDB
import Synchronization

/// The cache behind `TransactionRepository.manualQualityHistory()`.
///
/// Rule 2 of the qualities is worked out from every operation I rated by hand, and the ↓
/// panel asks for it at every change of a picker; a bulk change asks for it too. Read each
/// time, it read every hand-rated operation with its parts on the main thread — more with
/// every rating. It is read once and kept until a write reaches `transactions` or
/// `transaction_parts`, whoever makes it: the store, the entry line, a reimbursement, another
/// repository on the same database. A write is seen through a `DatabaseRegionObservation`,
/// which GRDB calls inside the commit, before the writing call returns.
///
/// The observation starts with the first read, not when the repository is made: a repository
/// is made for a single insert too. Its callback only takes the lock for a moment — it runs
/// on the writer's queue inside the commit, and the app writes from the main thread.
final class ManualRatingsCache: Sendable {
  private struct State: ~Copyable {
    var history: ManualQualityHistory?
    /// Grows with every write the observation sees. A history read while it moved may be the
    /// one from before the write, and is not kept.
    var version = 0
    var observation: AnyDatabaseCancellable?
    var reads = 0
  }

  private let state = Mutex(State())

  /// How many times the history was read from the database. The tests count it.
  var reads: Int { state.withLock { $0.reads } }

  func history(
    in writer: any DatabaseWriter, read: () throws -> ManualQualityHistory
  ) throws -> ManualQualityHistory {
    observe(writer)
    let (cached, version) = state.withLock { ($0.history, $0.version) }
    if let cached { return cached }
    let history = try read()
    state.withLock { state in
      state.reads += 1
      if state.version == version { state.history = history }
    }
    return history
  }

  private func observe(_ writer: any DatabaseWriter) {
    guard state.withLock({ $0.observation == nil }) else { return }
    let observation = DatabaseRegionObservation(
      tracking: Table("transactions"), Table("transaction_parts"))
    let cancellable = observation.start(
      in: writer,
      // An observation that failed sees no more writes: nothing is kept past it, and the
      // next read starts a new one.
      onError: { [weak self] _ in self?.forget(stopObserving: true) },
      onChange: { [weak self] _ in self?.forget(stopObserving: false) })
    let spare: AnyDatabaseCancellable? = state.withLock { state in
      guard state.observation == nil else { return cancellable }
      state.observation = cancellable
      return nil
    }
    // Two first reads at once: one observation is enough.
    spare?.cancel()
  }

  private func forget(stopObserving: Bool) {
    let stopped: AnyDatabaseCancellable? = state.withLock { state in
      state.version += 1
      state.history = nil
      guard stopObserving else { return nil }
      defer { state.observation = nil }
      return state.observation
    }
    stopped?.cancel()
  }
}
