import AppCore
import AppDatabase
import SwiftUI

/// «Каникулы или реструктуризация…» of a debt I owe: the first and the last day of a pause of the
/// payments, and which of the two it is. A due that falls in those days is not owed and every later
/// one moves on by as many months, so the sheet says where the last payment goes. The app records
/// what the bank agreed to — it never refuses a pause — and does not work out the new sums: what
/// the bank charges after the pause is typed from its own app («Вписать платёж…»). «Убрать
/// паузу» takes it away. One write, one step of ⌘Z.
struct DebtPauseSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let debt: Debt
  /// The dues of the debt as they stand, to preview where the last one goes.
  let dues: DebtDueState

  @State private var from = Date()
  @State private var to = Date()
  @State private var kind: DebtPauseKind = .holiday
  @State private var loaded = false
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: environment.format("pause.sheet.title", table: "Debts", debt.name))
        .appFont(.title2.bold())
        .accessibilityAddTraits(.isHeader)
      Form {
        Picker(t("pause.kind"), selection: $kind) {
          ForEach(DebtPauseKind.allCases, id: \.self) { kind in
            Text(verbatim: Self.kindName(kind, environment)).tag(kind)
          }
        }
        .accessibilityIdentifier("debts.pause.kind")
        DatePicker(t("pause.from"), selection: $from, displayedComponents: .date)
        DatePicker(t("pause.to"), selection: $to, displayedComponents: .date)
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      DebtInfoBlock(title: t("wizard.how"), lines: infoLines)
      if failed {
        Text(verbatim: environment.language("form.notSaved", table: "Planning"))
          .appFont(.caption).foregroundStyle(.red)
      }
      Button {
        save(candidate)
      } label: {
        Text(verbatim: t("form.save")).frame(maxWidth: .infinity)
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!candidate.isValid || dependencies == nil)
      HStack {
        if debt.pause != nil {
          Button(t("pause.remove"), role: .destructive) { save(nil) }
        }
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 460)
    .themedWindowBackground()
    .onAppear {
      guard !loaded else { return }
      loaded = true
      let today = environment.today
      from = environment.calendar.noon(of: debt.pause?.from ?? today)
      to = environment.calendar.noon(
        of: debt.pause?.to ?? DebtPauseText.monthsAfter(today, 3))
      kind = debt.pause?.kind ?? .holiday
    }
  }

  /// The pause as typed.
  private var candidate: DebtPause {
    DebtPause(
      from: environment.calendar.day(of: from), to: environment.calendar.day(of: to), kind: kind)
  }

  /// What the pause does, and what is wrong with it, in words.
  private var infoLines: [String] {
    var lines = [t("pause.hint")]
    if !candidate.isValid {
      lines.append(t("pause.endsBeforeStart"))
    } else if let text = DebtPauseText.shift(
      dues: dues.knowing(debt), pause: candidate, currency: debt.currency, environment)
    {
      lines.append(text)
    }
    return lines
  }

  private func save(_ pause: DebtPause?) {
    guard let dependencies else { return }
    if DebtActions(dependencies).setPause(debt, pause) {
      dismiss()
    } else {
      failed = true
    }
  }

  static func kindName(_ kind: DebtPauseKind, _ environment: AppEnvironment) -> String {
    environment.language("pause.kind.\(kind.rawValue)", table: "Debts")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// The words of a pause on the card of a debt and in its sheet.
@MainActor
enum DebtPauseText {
  /// «Кредитные каникулы: с 1 февраля 2027 по 31 марта 2027».
  static func card(_ pause: DebtPause, _ environment: AppEnvironment) -> String {
    environment.format(
      "pause.card", table: "Debts", DebtPauseSheet.kindName(pause.kind, environment),
      environment.dates.longDay(pause.from), environment.dates.longDay(pause.to))
  }

  /// «Последний платёж сдвинется с 10 мая 2027 на 10 июля 2027 (пропущено платежей — 2)»; `nil`
  /// when no due falls in the pause or the end of the debt is not known.
  static func shift(
    dues: DebtDueState, pause: DebtPause, currency: CurrencyCode, _ environment: AppEnvironment
  ) -> String? {
    var preview = dues
    preview.pause = pause
    guard let shift = DebtPauseRules.termShift(of: preview), shift.skippedDues > 0 else {
      return nil
    }
    return environment.format(
      "pause.termShift", table: "Debts", environment.dates.longDay(shift.lastDueBefore),
      environment.dates.longDay(shift.lastDueAfter), String(shift.skippedDues))
  }

  /// The same day `months` later, the 28th at most so every month has it.
  static func monthsAfter(_ day: DateOnly, _ months: Int) -> DateOnly {
    let month = day.monthKey.adding(months: months)
    return DateOnly(year: month.year, month: month.month, day: min(day.day, 28))
  }
}
