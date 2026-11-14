import SwiftUI

/// An amount field whose text does not read (a formula left half typed, a number too large)
/// keeps the amount it had before, so the form would save a sum other than the one on the screen.
/// The field says so with a red outline, and tells the sheet around it through this preference;
/// the save buttons of the form stay off until every amount field reads.
struct UnreadableAmountKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct UnreadableAmountEnvironmentKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Some amount field of the sheet holds text that does not read.
  var hasUnreadableAmount: Bool {
    get { self[UnreadableAmountEnvironmentKey.self] }
    set { self[UnreadableAmountEnvironmentKey.self] = newValue }
  }
}

/// Collects what the amount fields below say and hands it to the buttons of the same sheet.
private struct UnreadableAmountScope: ViewModifier {
  @State private var unreadable = false

  func body(content: Content) -> some View {
    content
      .onPreferenceChange(UnreadableAmountKey.self) { value in
        Task { @MainActor in unreadable = value }
      }
      .environment(\.hasUnreadableAmount, unreadable)
  }
}

extension View {
  /// Every sheet is such a scope (`sheetFrame`): a field below tells, the buttons below listen.
  func unreadableAmountScope() -> some View { modifier(UnreadableAmountScope()) }

  /// The main button of a sheet that has buttons of its own: off while an amount field of the
  /// sheet holds text that does not read.
  func disablesOnUnreadableAmount() -> some View { modifier(DisablesOnUnreadableAmount()) }
}

private struct DisablesOnUnreadableAmount: ViewModifier {
  @Environment(\.hasUnreadableAmount) private var hasUnreadableAmount

  func body(content: Content) -> some View {
    content.disabled(hasUnreadableAmount)
  }
}

/// What the main button of a form is allowed to do about an amount that does not read.
enum UnreadableAmountRule {
  static func isEnabled(formAllows: Bool, hasUnreadableAmount: Bool) -> Bool {
    formAllows && !hasUnreadableAmount
  }
}
