import AppCore
import SwiftUI

/// «Мелкая покупка — до»: the field of Settings → «Ввод» that says how small a small purchase is,
/// for the tile «Мелкие покупки» of Overview. Whole rubles; empty — not set, and the tile asks
/// for it. A setting, not an action: written at once to the table `settings`, no step of ⌘Z.
struct SmallPurchaseLimitField: View {
  @Dependency(\.environment) private var environment
  @State private var text = ""
  /// A write the database refused; the field shows what the database still has.
  @State private var refused = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent {
        HStack(spacing: 4) {
          TextField("", text: $text)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 100)
            .onSubmit(save)
            .accessibilityLabel(Text(verbatim: t("overview.small.field.title")))
            .accessibilityIdentifier("settings.entry.smallPurchaseLimit")
          Text(verbatim: environment.money.symbol(for: .rub))
            .foregroundStyle(.secondary)
        }
      } label: {
        Text(verbatim: t("overview.small.field.title"))
      }
      Text(verbatim: t("overview.small.field.hint"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear(perform: load)
    .onChange(of: OverviewFiguresStore.shared.smallLimit) { _, _ in load() }
    .refusedWriteAlert($refused, environment)
  }

  private func load() {
    text = Self.text(of: OverviewFiguresStore.shared.smallLimit)
  }

  private func save() {
    let whole = Self.whole(of: text)
    guard OverviewFiguresStore.shared.saveSmallLimit(whole, environment: environment) else {
      refused = true
      return
    }
    load()
  }

  /// The limit as the field shows it: whole rubles, empty for none.
  static func text(of limit: AmountE4?) -> String {
    limit.map { String($0.raw / AmountE4.unitsPerWhole) } ?? ""
  }

  /// The whole rubles a typed text says: spaces and thousands marks are ignored; `nil` for none
  /// or a text that is no whole number.
  static func whole(of text: String) -> Int64? {
    let digits = text.filter { $0.isNumber }
    guard digits == text.filter({ !$0.isWhitespace && $0 != "," && $0 != "\u{00A0}" }),
      let whole = Int64(digits), whole > 0
    else { return nil }
    return whole
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }
}
