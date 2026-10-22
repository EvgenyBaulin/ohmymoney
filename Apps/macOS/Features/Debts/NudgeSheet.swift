import AppCore
import AppDatabase
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

/// «Напомнить» a debtor: a polite text from the template — the owner's last edit, else the
/// standard one —, filled with the name, the sum, what for and the day it is due. The text is
/// edited here and copied; an edit becomes the template of the next reminder
/// (`NudgeText.template`, `debts.nudgeTemplate` in the database). No sharing: only the clipboard.
struct NudgeSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeSurfaces) private var surfaces
  let debt: Debt
  let balance: AmountE4

  @State private var text = ""
  @State private var made = ""
  @State private var loaded = false
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: environment.format("nudge.title", table: "Debts", values.name))
        .appFont(.title2.bold())
        .accessibilityAddTraits(.isHeader)
      TextEditor(text: $text)
        .appFont(.body)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: 110, maxHeight: 180)
        .background(surfaces.card, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(surfaces.cardBorder))
        .accessibilityIdentifier("debts.nudge.text")
      Text(verbatim: t("nudge.hint"))
        .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button {
        copy()
      } label: {
        Label(copied ? t("nudge.copied") : t("nudge.copy"), systemImage: copied ? "checkmark.circle" : "doc.on.doc")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .accessibilityIdentifier("debts.nudge.copy")
      Button {
        dismiss()
      } label: {
        Text(verbatim: t("nudge.done")).frame(maxWidth: .infinity)
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
    .padding(20)
    .sheetFrame(width: 460)
    .themedWindowBackground()
    .onAppear {
      guard !loaded else { return }
      loaded = true
      made = Self.text(
        template: template, values: values)
      text = made
    }
  }

  /// The values the template is filled with.
  private var values: NudgeText.Values {
    let person = compute.snapshot?.dataset.people.first { $0.id == debt.personId }?.name
    return NudgeText.Values(
      name: person ?? debt.name,
      amount: environment.money.exact(max(balance, .zero), currency: debt.currency),
      reason: debt.note ?? (person == nil ? nil : debt.name),
      day: debt.returnBy.map(environment.dates.longDay))
  }

  /// The template: the owner's own, else the standard one of the interface language.
  private var template: String {
    compute.snapshot?.dataset.debtSettings.nudgeTemplate ?? t("nudge.template")
  }

  /// `template` filled with `values`.
  static func text(template: String, values: NudgeText.Values) -> String {
    NudgeText.make(
      template: template, name: values.name, amount: values.amount, reason: values.reason,
      day: values.day)
  }

  private func copy() {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
    copied = true
    // An edit is how the owner wants it said: the next reminder starts from it.
    guard text != made, let dependencies else { return }
    var settings = compute.snapshot?.dataset.debtSettings ?? .standard
    settings.nudgeTemplate = NudgeText.template(fromEdited: text, values: values)
    if DebtActions(dependencies).saveSettings(settings) { made = text }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
