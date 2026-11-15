import AppCore
import AppDatabase
import SwiftUI

/// A meter, new or edited: its name, what it counts and in what, the tariff, the days the
/// provider takes readings on, the provider and the payment of «Планирование» that pays for it.
/// Deleting it takes its readings with it, one step of ⌘Z.
struct UtilityMeterForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let meter: UtilityMeter?

  @State private var name = ""
  @State private var kind: UtilityKind = .coldWater
  @State private var unit = UtilityKind.coldWater.defaultUnit
  @State private var tariff: AmountE4 = .zero
  @State private var reminds = false
  @State private var submitFrom = 20
  @State private var submitTo = 25
  @State private var provider = ""
  @State private var paymentId: UUID?
  @State private var loaded = false

  private func t(_ key: String) -> String { UtilitiesText.t(key, environment) }

  private var payments: [ScheduledPayment] {
    (compute.snapshot?.dataset.planning.scheduled ?? []).filter(\.active)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(meter == nil ? "utilities.meter.new" : "utilities.meter.edit"))
        .appFont(.headline)
      Form {
        TextField(text: $name) { Text(verbatim: t("utilities.meter.name")) }
        Picker(t("utilities.meter.kind"), selection: $kind) {
          ForEach(UtilityKind.allCases, id: \.self) { kind in
            Text(verbatim: t("utilities.kind.\(kind.rawValue)")).tag(kind)
          }
        }
        .onChange(of: kind) { _, new in unit = new.defaultUnit }
        TextField(text: $unit) { Text(verbatim: t("utilities.meter.unit")) }
        LabeledContent(t("utilities.meter.tariff")) {
          AmountField(amount: $tariff, locale: environment.language.locale)
        }
        Toggle(t("utilities.meter.reminds"), isOn: $reminds)
        if reminds {
          Stepper(value: $submitFrom, in: 1...31) {
            Text(
              verbatim: environment.format(
                "utilities.meter.from", table: UtilitiesText.table, submitFrom))
          }
          Stepper(value: $submitTo, in: 1...31) {
            Text(
              verbatim: environment.format(
                "utilities.meter.to", table: UtilitiesText.table, submitTo))
          }
        }
        TextField(text: $provider) { Text(verbatim: t("utilities.meter.provider")) }
        Picker(t("utilities.meter.payment"), selection: $paymentId) {
          Text(verbatim: t("utilities.meter.payment.none")).tag(UUID?.none)
          ForEach(payments) { payment in
            Text(verbatim: payment.name).tag(UUID?.some(payment.id))
          }
        }
        if let meter {
          Button(environment.language("action.delete"), role: .destructive) {
            if apply(
              PlanningChange(
                delete: PlanningRowIDs(utilityMeters: [meter.id]), at: environment.now()))
            {
              dismiss()
            }
          }
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty
          && !unit.trimmingCharacters(in: .whitespaces).isEmpty
      ) {
        apply(PlanningChange(upsert: PlanningRows(utilityMeters: [made()]), at: environment.now()))
      }
    }
    .padding(20)
    .sheetFrame(width: 480, height: 560)
    .onAppear(perform: load)
  }

  private func made() -> UtilityMeter {
    var result = meter ?? UtilityMeter(name: "", kind: kind)
    result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    // An unknown word stays as stored unless the owner picked another kind.
    if meter?.kind != kind || meter == nil { result.kind = kind }
    result.unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    result.tariffE4 = tariff.isZero ? nil : tariff
    result.submitFrom = reminds ? submitFrom : nil
    result.submitTo = reminds ? submitTo : nil
    let typed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
    result.provider = typed.isEmpty ? nil : typed
    result.scheduledPaymentId = paymentId
    if meter == nil {
      result.sort = (compute.snapshot?.dataset.utilities.meters.map(\.sort).max() ?? -1) + 1
    }
    return result
  }

  private func apply(_ change: PlanningChange) -> Bool {
    guard let dependencies else { return false }
    return dependencies.store.apply(change)
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    guard let meter else { return }
    name = meter.name
    kind = meter.kind
    unit = meter.unit
    tariff = meter.tariffE4 ?? .zero
    reminds = meter.submitFrom != nil && meter.submitTo != nil
    submitFrom = meter.submitFrom ?? 20
    submitTo = meter.submitTo ?? 25
    provider = meter.provider ?? ""
    paymentId = meter.scheduledPaymentId
  }
}

/// A reading of a meter: the day, the value, whether the meter was replaced or went round, and
/// whether it is already passed to the provider. The tariff of the meter is written with it, so a
/// later change of the tariff leaves this month's cost as it was.
struct UtilityReadingForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let meter: UtilityMeter

  @State private var day = Date()
  @State private var value: AmountE4 = .zero
  @State private var restart = false
  @State private var submitted = false
  @State private var loaded = false

  private func t(_ key: String) -> String { UtilitiesText.t(key, environment) }

  private var last: UtilityReading? {
    UtilityUsage.ordered(compute.snapshot?.dataset.utilities.readings ?? [], of: meter).last
  }

  /// A value below the last one is a typo unless the meter was replaced.
  private var goesDown: Bool {
    guard let last, !restart else { return false }
    return value < last.valueE4
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: meter.name).appFont(.headline)
      Form {
        DatePicker(t("utilities.reading.day"), selection: $day, displayedComponents: .date)
        LabeledContent(
          environment.format(
            "utilities.reading.value", table: UtilitiesText.table,
            UtilitiesText.unit(meter.unit, environment))
        ) {
          AmountField(amount: $value, locale: environment.language.locale)
        }
        if let last {
          Text(
            verbatim: environment.format(
              "utilities.reading.last", table: UtilitiesText.table,
              UtilitiesText.quantity(last.valueE4, unit: meter.unit, environment),
              environment.dates.dayMonth(last.day))
          )
          .appFont(.callout).secondaryInk()
        }
        Toggle(isOn: $restart) {
          Text(verbatim: t("utilities.reading.restart"))
          Text(verbatim: t("utilities.reading.restart.hint"))
        }
        Toggle(t("utilities.reading.submitted"), isOn: $submitted)
        if goesDown {
          Label {
            Text(verbatim: t("utilities.reading.lower"))
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .foregroundStyle(.orange)
          .appFont(.callout)
        }
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: !value.isNegative) {
        guard let dependencies else { return false }
        let now = environment.now()
        let reading = UtilityReading(
          meterId: meter.id, day: environment.calendar.day(of: day), valueE4: value,
          restart: restart, tariffE4: meter.tariffE4, submittedAt: submitted ? now : nil,
          recordedAt: now)
        return dependencies.store.apply(
          PlanningChange(upsert: PlanningRows(utilityReadings: [reading]), at: now))
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 420)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      day = environment.now()
      value = last?.valueE4 ?? .zero
    }
  }
}

/// A bill of a provider for a month: who, which month, how much, by what day, and the payment of
/// «Планирование» it belongs to. Recognising a bill from a PDF or a photo fills the same form.
struct UtilityBillForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let bill: UtilityBill?

  @State private var provider = ""
  @State private var periodDay = Date()
  @State private var total: AmountE4 = .zero
  @State private var hasPayBy = false
  @State private var payBy = Date()
  @State private var paymentId: UUID?
  @State private var loaded = false

  private func t(_ key: String) -> String { UtilitiesText.t(key, environment) }

  private var payments: [ScheduledPayment] {
    (compute.snapshot?.dataset.planning.scheduled ?? []).filter(\.active)
  }

  private var providers: [String] {
    let book = compute.snapshot?.dataset.utilities ?? UtilityBook()
    return UtilityBills.providers(book.bills)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(bill == nil ? "utilities.bill.new" : "utilities.bill.edit"))
        .appFont(.headline)
      Form {
        TextField(text: $provider) { Text(verbatim: t("utilities.bill.provider")) }
        if !providers.isEmpty, bill == nil {
          Picker(t("utilities.bill.known"), selection: $provider) {
            Text(verbatim: "").tag("")
            ForEach(providers, id: \.self) { Text(verbatim: $0).tag($0) }
          }
        }
        DatePicker(t("utilities.bill.period"), selection: $periodDay, displayedComponents: .date)
        LabeledContent(t("utilities.bill.total")) {
          AmountField(amount: $total, locale: environment.language.locale)
        }
        Toggle(t("utilities.bill.hasPayBy"), isOn: $hasPayBy)
        if hasPayBy {
          DatePicker(t("utilities.bill.payBy"), selection: $payBy, displayedComponents: .date)
        }
        Picker(t("utilities.meter.payment"), selection: $paymentId) {
          Text(verbatim: t("utilities.meter.payment.none")).tag(UUID?.none)
          ForEach(payments) { payment in
            Text(verbatim: payment.name).tag(UUID?.some(payment.id))
          }
        }
        if let bill {
          Button(environment.language("action.delete"), role: .destructive) {
            guard let dependencies else { return }
            if dependencies.store.apply(
              PlanningChange(delete: PlanningRowIDs(utilityBills: [bill.id]), at: environment.now())
            ) {
              dismiss()
            }
          }
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: !provider.trimmingCharacters(in: .whitespaces).isEmpty && !total.isNegative
      ) {
        guard let dependencies else { return false }
        let now = environment.now()
        var made =
          bill
          ?? UtilityBill(
            provider: "", period: environment.today.monthKey, totalE4: .zero, recordedAt: now)
        made.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        made.period = environment.calendar.day(of: periodDay).monthKey
        made.totalE4 = total
        made.payBy = hasPayBy ? environment.calendar.day(of: payBy) : nil
        made.scheduledPaymentId = paymentId
        return dependencies.store.apply(
          PlanningChange(upsert: PlanningRows(utilityBills: [made]), at: now))
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 500)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      guard let bill else {
        periodDay = environment.now()
        return
      }
      provider = bill.provider
      periodDay = environment.calendar.noon(of: bill.period.firstDay)
      total = bill.totalE4
      hasPayBy = bill.payBy != nil
      payBy = bill.payBy.map { environment.calendar.noon(of: $0) } ?? environment.now()
      paymentId = bill.scheduledPaymentId
    }
  }
}
