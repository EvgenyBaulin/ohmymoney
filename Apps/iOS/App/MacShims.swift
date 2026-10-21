import AppCore
import Foundation
import SwiftUI

/// The Mac's main window is a scene of its own and stays out of the iPhone target; the sections
/// it chooses between (`MainWindowSection.swift`) are shared, and this is the name they hang on.
enum MainWindow {}

// Styles and commands the shared screens use that exist on macOS only. Each has the nearest
// thing a touch screen has, so the screens are written once.

extension PrimitiveButtonStyle where Self == BorderlessButtonStyle {
  /// A text link on the Mac; a plain borderless button here.
  static var link: BorderlessButtonStyle { .borderless }
}

extension PickerStyle where Self == InlinePickerStyle {
  /// Radio buttons on the Mac; an inline list with a checkmark here.
  static var radioGroup: InlinePickerStyle { .inline }
}

extension ToggleStyle where Self == SwitchToggleStyle {
  /// A checkbox on the Mac; a switch here.
  static var checkbox: SwitchToggleStyle { .switch }
}

extension View {
  /// Esc on a keyboard; a touch screen has the sheet's own dismissal instead.
  func onExitCommand(perform action: (() -> Void)?) -> some View { self }
}

extension View {
  /// The Delete key of a keyboard; swipe actions and the selection bar delete on a touch screen.
  func onDeleteCommand(perform action: (() -> Void)?) -> some View { self }
}

/// A relaunch in place needs a helper process, which iOS has none of; the screens that offer it
/// (a restored copy, a language switch) stage their work and the owner reopens the app.
enum AppRestart {
  static func relaunch() {}
  static func relaunch(into dataSet: AppPaths.DataSet?) {}
}

/// The Mac's progress panel for an archive; the iPhone screen shows its own progress.
@MainActor
final class ArchiveProgressPanel {
  private(set) static var isShowing = false
  static func show(_ words: String) -> ArchiveProgressPanel { ArchiveProgressPanel() }
  func close() {}
}

/// Two panes side by side with a draggable divider on the Mac; a row on a wide screen and a
/// column on a narrow one here (a phone, an iPad in a slim window).
struct HSplitView<Content: View>: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @ViewBuilder let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    if sizeClass == .compact {
      ScrollView { VStack(spacing: 0) { content } }
    } else {
      HStack(spacing: 0) { content }
    }
  }
}
