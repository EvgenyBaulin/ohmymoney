import Foundation

/// What the app does that changes data. In read-only mode none of these is allowed; looking,
/// searching and exporting a report are not here, so they stay allowed.
public enum ReadOnlyAction: String, Hashable, Sendable, CaseIterable {
  /// Adding an operation, a transfer, a reconciliation or any new record.
  case write
  /// Changing a record that exists.
  case edit
  case delete
  /// ⌘Z and its repeat.
  case undo
  /// Loading a statement, a receipt, a CSV, an archive.
  case importData
  /// Putting a backup in place of the database.
  case restore
  /// Moving the data between devices: the exchange files and the archive of the move.
  case moveData
}

/// The mode «Только просмотр»: the data can be looked at and nothing can change. It is switched
/// on freely and switched off only after the owner proves who they are with Touch ID or the
/// password of the Mac.
public struct ReadOnlyMode: Hashable, Sendable {
  public private(set) var isOn: Bool

  public init(isOn: Bool = false) {
    self.isOn = isOn
  }

  /// Whether the action may run now.
  public func allows(_ action: ReadOnlyAction) -> Bool {
    !isOn
  }

  /// The actions that are refused now, in the order of `ReadOnlyAction.allCases`.
  public var forbidden: [ReadOnlyAction] {
    isOn ? ReadOnlyAction.allCases : []
  }

  public func turnedOn() -> ReadOnlyMode { ReadOnlyMode(isOn: true) }

  /// The mode after the owner asked to leave it. `unlockedByAuthentication` is `true` only
  /// when the system confirmed Touch ID or the password of the Mac for this very request; a
  /// request without it changes nothing.
  public func leaving(unlockedByAuthentication: Bool) -> ReadOnlyMode {
    guard isOn else { return self }
    return unlockedByAuthentication ? ReadOnlyMode(isOn: false) : self
  }
}
