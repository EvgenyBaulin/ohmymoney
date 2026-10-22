import AppCore
import Foundation

/// The snapshot of the folder as the owner is offered it.
struct SyncSnapshotOffer: Equatable {
  var madeAt: Date
  /// The device that wrote the snapshot (its identifier; the folder carries no name).
  var deviceId: String

  /// The first characters of the identifier, enough to tell two devices apart.
  var deviceLabel: String { String(deviceId.prefix(8)) }
}

/// Where «Загрузить данные из папки» stands. A plain value: the screens only draw it.
enum SyncBootstrapState: Equatable {
  case idle
  /// A snapshot is in the folder and this device holds none of the owner's books.
  case offered(SyncSnapshotOffer)
  case loading
  /// Staged: the next launch puts it in place.
  case staged
  case result(SyncCoordinator.BootstrapResult)
}

/// The words of the bootstrap, as keys of the `Sync` catalog.
enum SyncBootstrapText {
  /// What each answer of the coordinator says. `.staged` is the prompt to restart.
  static func messageKey(for result: SyncCoordinator.BootstrapResult) -> String {
    switch result {
    case .staged: "sync.bootstrap.staged"
    case .notConfigured: "sync.bootstrap.notConfigured"
    case .notEmpty: "sync.bootstrap.notEmpty"
    case .noSnapshot: "sync.bootstrap.noSnapshot"
    case .damaged: "sync.bootstrap.damaged"
    case .newerVersion: "sync.bootstrap.newerVersion"
    case .failed: "sync.bootstrap.failed"
    }
  }

  /// The key a state speaks with; `nil` for the states that draw something else (idle, the
  /// offer, the spinner).
  static func messageKey(for state: SyncBootstrapState) -> String? {
    switch state {
    case .idle, .offered, .loading: nil
    case .staged: messageKey(for: .staged)
    case .result(let result): messageKey(for: result)
    }
  }

  /// Whether the button that loads the snapshot is shown: an offer, or a try that can be made
  /// again (a damaged or failed one).
  static func offersLoad(_ state: SyncBootstrapState) -> Bool {
    switch state {
    case .offered: true
    case .result(let result): result == .failed || result == .damaged
    default: false
    }
  }

  /// Only a staged snapshot asks for the restart.
  static func asksRestart(_ state: SyncBootstrapState) -> Bool { state == .staged }

  /// Whether the section is drawn at all: nothing is said while the state is idle.
  static func isVisible(_ state: SyncBootstrapState) -> Bool { state != .idle }
}
