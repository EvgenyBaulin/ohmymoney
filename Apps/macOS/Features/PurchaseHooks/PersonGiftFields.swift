import AppCore
import SwiftUI

/// «День рождения» and «Бюджет на подарок» of a person (Settings → Справочники → Люди): the day
/// and the month, the year when the owner knows it, and what the owner is ready to spend on a
/// gift. The reminder a week before and the calendar of gifts read them.
struct PersonGiftFields: View {
  @Dependency(\.environment) private var environment
  @Binding var person: Person

  private func t(_ key: String) -> String { PurchaseHookText.t(key, environment) }

  var body: some View {
    Section {
      if let birthday = person.birthday {
        Picker(selection: day(birthday)) {
          ForEach(1...31, id: \.self) { Text(verbatim: "\($0)").tag($0) }
        } label: {
          Text(verbatim: t("person.birthday.day"))
        }
        .accessibilityIdentifier("person.birthday.day")
        Picker(selection: month(birthday)) {
          ForEach(1...12, id: \.self) { number in
            Text(verbatim: environment.dates.shortMonth(MonthKey(year: 2000, month: number))).tag(number)
          }
        } label: {
          Text(verbatim: t("person.birthday.month"))
        }
        .accessibilityIdentifier("person.birthday.month")
        BirthdayYearField(
          year: birthday.year, title: t("person.birthday.year"),
          prompt: t("person.birthday.yearPrompt")
        ) { year in changed(birthday, year: .some(year)) }
        Button(t("person.birthday.remove")) { person.birthday = nil }
          .accessibilityIdentifier("person.birthday.remove")
      } else {
        LabeledContent {
          Button(t("person.birthday.add")) {
            person.birthday = Birthday(month: environment.today.month, day: environment.today.day)
          }
          .accessibilityIdentifier("person.birthday.add")
        } label: {
          Text(verbatim: t("person.birthday"))
        }
      }
      LabeledContent {
        AmountField(
          amount: Binding(
            get: { person.giftBudgetE4 ?? .zero },
            set: { person.giftBudgetE4 = $0.raw > 0 ? $0 : nil })
        )
        .multilineTextAlignment(.trailing)
        .accessibilityIdentifier("person.giftBudget")
      } label: {
        Text(verbatim: t("person.giftBudget"))
      }
      Text(verbatim: t("person.giftBudget.hint"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Bindings

  /// A change of one part keeps the others; a part out of range is not written.
  private func changed(_ birthday: Birthday, month: Int? = nil, day: Int? = nil, year: Int?? = nil)
  {
    let updated = Birthday(
      month: month ?? birthday.month, day: day ?? birthday.day,
      year: year ?? birthday.year)
    if let updated { person.birthday = updated }
  }

  private func day(_ birthday: Birthday) -> Binding<Int> {
    Binding(get: { birthday.day }, set: { changed(birthday, day: $0) })
  }

  private func month(_ birthday: Birthday) -> Binding<Int> {
    Binding(get: { birthday.month }, set: { changed(birthday, month: $0) })
  }

  /// A year of birth that reads: four digits, from 1900 to the present.
  static func year(from digits: String) -> Int? {
    guard digits.count == 4, let year = Int(digits), (1900...2200).contains(year) else {
      return nil
    }
    return year
  }
}

/// The year of birth as text. Half-typed digits stay in the field; a year that reads (four
/// digits) or an empty field is handed on, anything else leaves the year as it was.
private struct BirthdayYearField: View {
  let year: Int?
  let title: String
  let prompt: String
  let changed: (Int?) -> Void
  @State private var text = ""

  var body: some View {
    TextField(text: $text, prompt: Text(verbatim: prompt)) {
      Text(verbatim: title)
    }
    .monospacedDigit()
    .accessibilityIdentifier("person.birthday.year")
    .onAppear { text = year.map(String.init) ?? "" }
    .onChange(of: text) { _, typed in
      let digits = typed.filter(\.isNumber)
      if digits.isEmpty {
        if year != nil { changed(nil) }
      } else if let value = PersonGiftFields.year(from: digits), value != year {
        changed(value)
      }
    }
  }
}
