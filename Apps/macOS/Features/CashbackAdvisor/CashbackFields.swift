import AppCore
import SwiftUI

/// «Не больше … ₽ в месяц»: the ceiling of a cashback rule or of a whole account. Empty — no
/// ceiling; what does not read is said by the sheet that holds the field.
struct CashbackCapField: View {
  @Dependency(\.environment) private var environment
  @Binding var text: String
  /// `cashback.cap.rule` or `cashback.cap.account` of the catalog `SyncHistory`.
  let labelKey: String

  var body: some View {
    HStack {
      Text(verbatim: environment.language(labelKey, table: "SyncHistory"))
        .foregroundStyle(.secondary)
      Spacer()
      TextField(text: $text) {
        Text(verbatim: environment.language("cashback.cap.none", table: "SyncHistory"))
      }
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .monospacedDigit()
      .frame(width: 100)
      Text(verbatim: environment.language("cashback.cap.perMonth", table: "SyncHistory"))
        .foregroundStyle(.secondary)
    }
    .appFont(.caption)
    .accessibilityIdentifier(labelKey)
  }
}

/// The day the bank opens the month's choice of categories: none, or a day of the month (31 —
/// the last day of any month). The reminder to choose comes on that day.
struct CashbackChoiceDayPicker: View {
  @Dependency(\.environment) private var environment
  @Binding var day: Int?

  var body: some View {
    Picker(selection: $day) {
      Text(verbatim: environment.language("cashback.choiceDay.none", table: "SyncHistory"))
        .tag(Int?.none)
      ForEach(1...30, id: \.self) { value in
        Text(
          verbatim: environment.format("cashback.choiceDay.day", table: "SyncHistory", value)
        )
        .tag(Int?.some(value))
      }
      Text(verbatim: environment.language("cashback.choiceDay.last", table: "SyncHistory"))
        .tag(Int?.some(31))
    } label: {
      Text(verbatim: environment.language("cashback.choiceDay", table: "SyncHistory"))
    }
    .accessibilityIdentifier("cashback.choiceDay")
  }
}
