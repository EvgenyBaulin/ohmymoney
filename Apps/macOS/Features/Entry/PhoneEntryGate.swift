import Observation
import SwiftUI

/// What happens around the entry line of the phone and the tablet. There the line is not on
/// screen by default: a round «+» shows it, and the keyboard comes only with it.
enum PhoneEntryEvent: Equatable, Sendable {
  /// The owner tapped the round «+».
  case plusTapped
  /// A new entry was asked for by a key (⌘N on a hardware keyboard) or by the palette.
  case newEntryRequested
  /// An operation was written.
  case saved
  /// Esc on a hardware keyboard, with no panel left to close.
  case escaped
  /// A tap on the screen outside the line.
  case tappedOutside
  /// A section was switched to, or the first one was shown at launch.
  case tabChanged(PhoneTab)
}

/// The visible state of the line and the one rule of the keyboard: it is asked for only by an
/// event that is an act of the owner on the line (`focusesLine`), never by a screen appearing.
struct PhoneEntryState: Equatable, Sendable {
  /// The section on screen.
  private(set) var tab: PhoneTab = .overview
  /// The section whose line is on screen, if any. One line at a time.
  private(set) var shownOn: PhoneTab?

  init(tab: PhoneTab = .overview) { self.tab = tab }

  /// «Ещё» holds lists and settings: it has no entry line.
  static func hostsEntry(_ tab: PhoneTab) -> Bool { tab != .more }

  var isShown: Bool { shownOn != nil }

  /// Whether the line of this section is on screen.
  func shows(lineOf host: PhoneTab) -> Bool { shownOn == host }

  /// The round «+»: on a section that has a line, until the line is up.
  var showsPlus: Bool { Self.hostsEntry(tab) && !isShown }

  /// The keyboard goes to the line when this event comes — and for no other.
  static func focusesLine(_ event: PhoneEntryEvent) -> Bool {
    switch event {
    case .plusTapped, .newEntryRequested: true
    case .saved, .escaped, .tappedOutside, .tabChanged: false
    }
  }

  /// Applies the event; true when the line should take the keyboard now.
  @discardableResult
  mutating func apply(_ event: PhoneEntryEvent) -> Bool {
    switch event {
    case .plusTapped, .newEntryRequested:
      guard Self.hostsEntry(tab) else { return false }
      shownOn = tab
      return true
    case .saved, .escaped, .tappedOutside:
      shownOn = nil
    case .tabChanged(let next):
      tab = next
      shownOn = nil
    }
    return false
  }
}

/// The state above, observed by the screens, with the animation of the line's coming and going.
@MainActor
@Observable
final class PhoneEntryGate {
  private(set) var state = PhoneEntryState()

  init() {}

  var isShown: Bool { state.isShown }
  var showsPlus: Bool { state.showsPlus }

  /// Returns whether the line should take the keyboard.
  @discardableResult
  func send(_ event: PhoneEntryEvent) -> Bool {
    var focus = false
    withAnimation(.snappy) { focus = state.apply(event) }
    return focus
  }
}

/// What an entry bar needs to be the bar of the phone: the gate, and the section it stands in.
@MainActor
struct PhoneEntryAccess {
  let gate: PhoneEntryGate
  let tab: PhoneTab

  var isShown: Bool { gate.state.shows(lineOf: tab) }
}

extension EnvironmentValues {
  /// The gate of the phone's line, set by the root of the phone; `nil` on the Mac, where the
  /// line is always on screen.
  @Entry var phoneEntryGate: PhoneEntryGate?
}
