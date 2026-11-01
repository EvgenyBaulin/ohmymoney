import Foundation

/// «Скрыть суммы» under a Focus filter of the system: a Focus that asks for it (say «Работа»)
/// hides the amounts while it is on, and leaving it puts them back — but only if the Focus was
/// what hid them. Amounts the owner had hidden by hand before the Focus began stay hidden after
/// it ends. The filter switches nothing else.
public struct FocusAmounts: Hashable, Sendable, Codable {
  /// The Focus is the reason the amounts are hidden now: they were shown when it began.
  public private(set) var focusHid: Bool

  public init(focusHid: Bool = false) {
    self.focusHid = focusHid
  }

  /// What a Focus filter turning on or off does. `focusHides` — what the filter of the Focus
  /// now asks (`false` also when the Focus ended); `hiddenNow` — whether the amounts are
  /// hidden right now. Returns whether they should be hidden.
  public mutating func apply(focusHides: Bool, hiddenNow: Bool) -> Bool {
    if focusHides {
      if !hiddenNow { focusHid = true }
      return true
    }
    defer { focusHid = false }
    return focusHid ? false : hiddenNow
  }

  /// The owner showed the amounts by hand while the Focus hid them: the Focus no longer owns
  /// the switch, and its end changes nothing.
  public mutating func ownerChanged() {
    focusHid = false
  }
}
