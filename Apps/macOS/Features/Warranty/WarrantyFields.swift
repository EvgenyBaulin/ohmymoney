import AppCore
import SwiftUI

/// «Гарантия до», «Где лежит оригинал» and «Вернуть можно до»: the three optional fields of a
/// purchase, in the ↓ panel and in the editor of a saved operation. A date is picked on a small
/// calendar or by a quick choice counted from the day of the purchase («+2 года»); each field
/// can be taken back with «Убрать». Nothing here is required, and an empty field saves as none.
struct WarrantyFields: View {
  @Dependency(\.environment) private var environment
  @Binding var draft: TransactionDraft

  private func t(_ key: String) -> String { WarrantyText.t(key, environment) }

  /// The day the purchase was made: the quick choices count from it.
  private var purchaseDay: DateOnly { environment.calendar.day(of: draft.occurredAt) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      termField(
        title: "warranty.field.until", day: $draft.warrantyUntil,
        presets: WarrantyTerms.warrantyPresets, identifier: "entry.warranty.until")
      VStack(alignment: .leading, spacing: 4) {
        label("warranty.field.place")
        TextField(
          text: Binding($draft.warrantyWhere, replacingNilWith: ""),
          prompt: Text(verbatim: t("warranty.field.place.prompt"))
        ) {
          Text(verbatim: t("warranty.field.place"))
        }
        .labelsHidden()
        .accessibilityIdentifier("entry.warranty.place")
      }
      termField(
        title: "warranty.field.return", day: $draft.returnUntil,
        presets: WarrantyTerms.returnPresets, identifier: "entry.warranty.return")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("entry.warranty")
  }

  private func label(_ key: String) -> some View {
    Text(verbatim: t(key)).appFont(.caption).foregroundStyle(.secondary)
  }

  private func termField(
    title: String, day: Binding<DateOnly?>, presets: [TermReading], identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      label(title)
      FlowRow(spacing: 6, lineSpacing: 6) {
        ForEach(presets, id: \.self) { term in
          Button(WarrantyText.preset(term, environment)) {
            day.wrappedValue = WarrantyTerms.end(of: term, from: purchaseDay)
          }
          .accessibilityIdentifier("\(identifier).preset.\(term.count)\(term.unit.rawValue)")
        }
        if day.wrappedValue != nil {
          DatePicker(
            selection: Binding(
              get: { environment.calendar.startOfDay(day.wrappedValue ?? purchaseDay) },
              set: { day.wrappedValue = environment.calendar.day(of: $0) }),
            displayedComponents: .date
          ) {
            Text(verbatim: t(title))
          }
          .labelsHidden()
          .accessibilityIdentifier("\(identifier).date")
          Button(t("warranty.clear")) { day.wrappedValue = nil }
            .accessibilityIdentifier("\(identifier).clear")
        } else {
          Button(t("warranty.pick")) { day.wrappedValue = purchaseDay }
            .accessibilityIdentifier("\(identifier).pick")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }
}
