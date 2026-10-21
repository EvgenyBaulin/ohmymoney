import AppKit
import Observation

extension TextEditingUndo {
  /// What Undo and Redo of the menu can reach in the key window: the typing of the field the
  /// cursor is in, and whether that window is a sheet or a popover (`undoTarget`).
  struct State: Equatable, Sendable {
    var isEditingText = false
    var fieldCanUndo = false
    var fieldCanRedo = false
    var inSheet = false

    /// The key window as it is now. A sheet is a window attached to another (`sheetParent`),
    /// a popover a child window (`parent`).
    @MainActor static func current() -> State {
      let window = NSApp.keyWindow
      let editor = window?.firstResponder as? NSTextView
      return State(
        isEditingText: editor != nil,
        fieldCanUndo: editor?.undoManager?.canUndo ?? false,
        fieldCanRedo: editor?.undoManager?.canRedo ?? false,
        inSheet: window?.sheetParent != nil || window?.parent != nil
          || window?.attachedSheet != nil)
    }

    /// What ⌘Z takes back, by the one rule of `TextEditingUndo.undoTarget`.
    @MainActor func undoTarget(storeCanUndo: Bool) -> UndoTarget {
      TextEditingUndo.undoTarget(
        isEditingText: isEditingText, fieldCanUndo: fieldCanUndo, storeCanUndo: storeCanUndo,
        inSheet: inSheet)
    }

    /// Whether ⌘⇧Z has typing to put back.
    var canRedo: Bool { isEditingText && fieldCanRedo }
  }
}

/// Lets the Undo and Redo items follow the field being typed in.
///
/// SwiftUI draws the commands again only when something they observe changes. The store's
/// stack is observed; the key window's first responder and its undo manager belong to AppKit
/// and are not, so the items kept whatever they were at the last redraw: with nothing in the
/// store to undo, typing begun in the entry line afterwards could not be taken back by ⌘Z,
/// and ⌘⇧Z stayed off after it had been.
///
/// The watch reads the key window again at every moment that can change what the items
/// reach — a field begins, changes or ends editing, a window becomes or stops being key, an
/// undo manager undoes, redoes or closes a group of typing — and the commands observe
/// `state`, which moves only when the answer does, so a keystroke redraws nothing.
@MainActor
@Observable
final class TextEditingWatch {
  static let shared = TextEditingWatch()

  private(set) var state: TextEditingUndo.State

  /// Where the state is read from: the key window; a test hands in a field of its own.
  @ObservationIgnored var read: @MainActor () -> TextEditingUndo.State
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []

  /// The moments that can change what Undo and Redo reach.
  static let moments: [Notification.Name] = [
    NSText.didBeginEditingNotification, NSText.didChangeNotification,
    NSText.didEndEditingNotification,
    NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
    .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup,
  ]

  init(
    center: NotificationCenter = .default,
    read: @escaping @MainActor () -> TextEditingUndo.State = { .current() }
  ) {
    self.read = read
    self.state = read()
    observers = Self.moments.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
    }
  }

  /// Reads the key window again; observers hear of it only when the answer changed.
  func refresh() {
    let now = read()
    if now != state { state = now }
  }
}
