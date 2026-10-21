import AppCore
import AppDatabase
import SwiftUI

/// «Запланировать досрочку…» of a loan: the day and the sum of an early repayment the owner plans,
/// and how many days before it the bank wants the application. Not money: a reminder to file it
/// («Стоит посмотреть», from the day the application is due) and a step of the ladder. «Убрать
/// план» takes it away. One write, one step of ⌘Z.
struct PrepaySheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let debt: Debt

  @State private var day = Date()
  @State private var amount: AmountE4 = .zero
  @State private var notice = DebtReminders.defaultNoticeDays
  @State private var loaded = false
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("prepay.sheet.title", table: "Debts", debt.name))
        .appFont(.headline)
      Form {
        DatePicker(t("prepay.day"), selection: $day, displayedComponents: .date)
        LabeledContent(t("form.amount")) {
          HStack {
            AmountField(amount: $amount)
            Text(verbatim: debt.currency.code).foregroundStyle(.secondary)
          }
        }
        Stepper(value: $notice, in: 0...90) {
          Text(verbatim: environment.format("wizard.notice", table: "Debts", String(notice)))
        }
        Text(
          verbatim: environment.format(
            "prepay.fileBy", table: "Debts",
            environment.dates.longDay(
              Self.fileBy(environment.calendar.day(of: day), notice: notice)))
        )
        .appFont(.caption).foregroundStyle(.secondary)
        Text(verbatim: t(debt.prepayAnyDay ? "prepay.anyDay" : "prepay.paymentDayOnly"))
          .appFont(.caption).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      if failed {
        Text(verbatim: environment.language("form.notSaved", table: "Planning"))
          .appFont(.caption).foregroundStyle(.red)
      }
      HStack {
        if debt.plannedPrepay != nil {
          Button(t("prepay.remove"), role: .destructive) { save(nil) }
        }
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(t("form.save")) {
          save(PlannedPrepay(day: environment.calendar.day(of: day), amountE4: amount))
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(amount.raw <= 0 || dependencies == nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 440)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      notice = debt.prepayNoticeDays ?? DebtReminders.defaultNoticeDays
      if let planned = debt.plannedPrepay {
        day = environment.calendar.noon(of: planned.day)
        amount = planned.amountE4
      }
    }
  }

  /// The day the application is filed by.
  static func fileBy(_ day: DateOnly, notice: Int) -> DateOnly { day.adding(days: -max(0, notice)) }

  private func save(_ planned: PlannedPrepay?) {
    guard let dependencies else { return }
    let notice = self.notice == DebtReminders.defaultNoticeDays ? nil : self.notice
    if DebtActions(dependencies).planPrepay(debt, planned, noticeDays: notice) {
      dismiss()
    } else {
      failed = true
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// «Вписать платёж из приложения банка…»: what a due and the ones after it ask, as the bank's app
/// says — it holds over the sum worked out until the next step of either kind (a later early
/// repayment works the sum out again). An empty sum takes a typed one away. One step of ⌘Z.
struct InstalmentEditSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let debt: Debt

  @State private var index = 0
  @State private var amount: AmountE4 = .zero
  @State private var loaded = false
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("typed.title", table: "Debts", debt.name)).appFont(
        .headline)
      Form {
        Picker(t("typed.from"), selection: $index) {
          ForEach(choices, id: \.index) { choice in
            Text(
              verbatim: environment.dates.longDay(choice.day) + " — "
                + environment.money.exact(choice.amount, currency: debt.currency)
            )
            .tag(choice.index)
          }
        }
        LabeledContent(t("typed.amount")) {
          HStack {
            AmountField(amount: $amount)
            Text(verbatim: debt.currency.code).foregroundStyle(.secondary)
          }
        }
        Text(verbatim: t("typed.hint"))
          .appFont(.caption).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      if failed {
        Text(verbatim: environment.language("form.notSaved", table: "Planning"))
          .appFont(.caption).foregroundStyle(.red)
      }
      HStack {
        if typedHere {
          Button(t("typed.remove"), role: .destructive) { save(nil) }
        }
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(t("form.save")) { save(amount) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(amount.raw <= 0 || dependencies == nil || choices.isEmpty)
      }
    }
    .padding(20)
    .sheetFrame(width: 460)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      if let first = choices.first {
        index = first.index
        amount = first.amount
      }
    }
    .onChange(of: index) {
      amount = choices.first { $0.index == index }?.amount ?? amount
    }
  }

  private var dues: DebtDueState? {
    compute.snapshot?.planning.debts.iOwe.first { $0.debt.id == debt.id }?.dues.knowing(debt)
  }

  /// The unpaid dues ahead, by index, with what each asks.
  private var choices: [(index: Int, day: DateOnly, amount: AmountE4)] {
    guard let dues, let first = dues.firstUnpaidIndex else { return [] }
    return (first..<(first + 24)).map { ($0, dues.due($0), dues.amount(ofDue: $0)) }
      .filter { $0.amount.raw > 0 }
  }

  private var typedHere: Bool {
    (compute.snapshot?.dataset.debtInstalments ?? []).contains {
      $0.debtId == debt.id && $0.fromIndex == index
    }
  }

  private func save(_ amount: AmountE4?) {
    guard let dependencies else { return }
    if DebtActions(dependencies).typeInstalment(debt, fromIndex: index, amount: amount) {
      dismiss()
    } else {
      failed = true
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// «Списать…» a pledge that did not come back: what is left of it is spent in the category
/// chosen — «Не помню» first in the list, no other preset —, and the pledge closes. One write,
/// one step of ⌘Z.
struct PledgeWriteOffSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let debt: Debt

  @State private var categoryId: UUID?
  @State private var day = Date()
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("pledge.writeOff.title", table: "Debts", debt.name))
        .appFont(.headline)
      Form {
        Picker(t("wizard.category"), selection: $categoryId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(categories, id: \.id) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
        .accessibilityIdentifier("debts.pledge.category")
        DatePicker(t("form.date"), selection: $day, displayedComponents: .date)
        Text(verbatim: t("pledge.writeOff.hint"))
          .appFont(.caption).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      if failed {
        Text(verbatim: environment.language("form.notSaved", table: "Planning"))
          .appFont(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(t("pledge.writeOff")) { save() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(categoryId == nil || dependencies == nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 440)
  }

  /// The live expense categories, «Не помню» first, then by their path.
  private var categories: [(id: UUID, name: String)] {
    let all = compute.snapshot?.dataset.categories ?? []
    let names = Dictionary(all.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let live = all.filter {
      $0.kind == .expense && !$0.archived
        && ($0.systemRole == nil || $0.systemRole == .unknown)
    }
    let unknown = live.filter { $0.systemRole == .unknown }.map { ($0.id, $0.name) }
    let rest = live.filter { $0.systemRole == nil }.map { category in
      let parent = category.parentId.flatMap { names[$0] }
      return (category.id, parent.map { "\($0) › \(category.name)" } ?? category.name)
    }.sorted { $0.1 < $1.1 }
    return (unknown + rest).map { (id: $0.0, name: $0.1) }
  }

  private func save() {
    guard let dependencies, let categoryId else { return }
    if DebtActions(dependencies).writeOffPledge(
      debt, categoryId: categoryId, on: environment.calendar.day(of: day))
    {
      dismiss()
    } else {
      failed = true
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
