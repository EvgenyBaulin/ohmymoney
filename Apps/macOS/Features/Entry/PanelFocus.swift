import AppCore
import Foundation
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// A control of the ↓ panel that can hold the keyboard focus.
enum PanelFocus: Hashable, Sendable {
  case amount, category, subcategory, quality, forWhom, forPerson, place, event, account,
    charge, cashback, goal, debt, note, date, incomeMonth, expected, currency, rate
  /// The line of quick entry over the fields of the form at the side; no field of the order.
  case quick
  /// The fields of a transfer, shown in place of the fields of an operation while the kind
  /// «Перевод» is chosen, top to bottom; no field of the order.
  case transferFrom, transferSent, transferTo, transferReceived, transferFee, transferDate,
    transferNote

  /// A text field — or the date's own field — takes the focus whatever «Навигация с
  /// клавиатуры» says; a menu, only with it on.
  var isText: Bool {
    switch self {
    case .amount, .charge, .cashback, .note, .date, .rate, .quick, .transferSent,
      .transferReceived, .transferFee, .transferDate, .transferNote:
      true
    default: false
    }
  }
}

/// What the panel is asked to focus: a control, or the first or the last of the order.
enum PanelFocusRequest: Hashable, Sendable {
  case first
  case last
  case control(PanelFocus)
}

/// The order Tab walks the panel in: the fields in the owner's order (`EntryFieldOrder`), each
/// field's controls top to bottom — only those on screen, and only the text fields while macOS
/// keeps Tab to them.
enum PanelTabOrder {
  /// The controls of `field`, top to bottom.
  static func controls(of field: EntryField) -> [PanelFocus] {
    switch field {
    case .amount: [.amount]
    case .category: [.category, .subcategory]
    case .quality: [.quality]
    case .forWhom: [.forWhom, .forPerson]
    case .place: [.place]
    case .event: [.event]
    case .account: [.account, .charge]
    case .cashback: [.cashback]
    case .goal: [.goal]
    case .debt: [.debt]
    case .note: [.note]
    case .date: [.date]
    case .incomeMonth: [.incomeMonth, .expected]
    case .currency: [.currency, .rate]
    }
  }

  /// Every control Tab stops at, in the order: those `shown`, and with `fullKeyboardAccess` off
  /// only the text fields.
  static func stops(
    order: [EntryField], shown: Set<PanelFocus>, fullKeyboardAccess: Bool
  ) -> [PanelFocus] {
    order.flatMap(controls(of:)).filter { control in
      shown.contains(control) && (fullKeyboardAccess || control.isText)
    }
  }

  static func first(
    order: [EntryField], shown: Set<PanelFocus>, fullKeyboardAccess: Bool
  ) -> PanelFocus? {
    stops(order: order, shown: shown, fullKeyboardAccess: fullKeyboardAccess).first
  }

  static func last(
    order: [EntryField], shown: Set<PanelFocus>, fullKeyboardAccess: Bool
  ) -> PanelFocus? {
    stops(order: order, shown: shown, fullKeyboardAccess: fullKeyboardAccess).last
  }

  /// The control a request comes to: a control asked by name is taken when it is on screen and
  /// can hold the focus; otherwise nothing, and the mark next to it shows where to click.
  static func resolve(
    _ request: PanelFocusRequest, order: [EntryField], shown: Set<PanelFocus>,
    fullKeyboardAccess: Bool
  ) -> PanelFocus? {
    switch request {
    case .first: first(order: order, shown: shown, fullKeyboardAccess: fullKeyboardAccess)
    case .last: last(order: order, shown: shown, fullKeyboardAccess: fullKeyboardAccess)
    case .control(let control):
      shown.contains(control) && (fullKeyboardAccess || control.isText) ? control : nil
    }
  }

  /// The control a request comes to while the panel shows a transfer: its fields top to
  /// bottom, the first being the amount sent, the last the comment.
  static func resolveTransfer(
    _ request: PanelFocusRequest, shown: Set<PanelFocus>, fullKeyboardAccess: Bool
  ) -> PanelFocus? {
    let stops = transferControls.filter { shown.contains($0) && (fullKeyboardAccess || $0.isText) }
    switch request {
    case .first: return stops.first { $0 != .transferFrom } ?? stops.first
    case .last: return stops.last
    case .control(let control):
      return shown.contains(control) && (fullKeyboardAccess || control.isText) ? control : nil
    }
  }

  /// The controls of a transfer, top to bottom.
  static let transferControls: [PanelFocus] = [
    .transferFrom, .transferSent, .transferTo, .transferReceived, .transferFee, .transferDate,
    .transferNote,
  ]

  /// Shift-Tab, as the key of a key press reads it.
  static let backTab = KeyEquivalent("\u{19}")

  /// Whether macOS lets Tab stop at menus and buttons: «Навигация с клавиатуры» in System
  /// Settings → Keyboard.
  #if os(macOS)
    @MainActor static var fullKeyboardAccess: Bool { NSApp?.isFullKeyboardAccessEnabled ?? false }
  #else
    /// A touch screen has no Tab stops to lose.
    @MainActor static var fullKeyboardAccess: Bool { true }
  #endif
}
