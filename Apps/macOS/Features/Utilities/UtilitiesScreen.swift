import AppCore
import SwiftUI

/// The words of «Коммуналка», from the Utilities catalog.
enum UtilitiesText {
  static let table = "Utilities"

  @MainActor
  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  /// «м³», «кВт·ч», «Гкал» for the units the app knows; anything else as the owner typed it.
  @MainActor
  static func unit(_ unit: String, _ environment: AppEnvironment) -> String {
    switch unit {
    case "m3", "kwh", "gcal", "unit": t("utilities.unit.\(unit)", environment)
    default: unit
    }
  }

  /// «123.456 м³»: a quantity with up to four digits after the point, never rounded away.
  @MainActor
  static func quantity(_ value: AmountE4, unit: String, _ environment: AppEnvironment) -> String {
    environment.money.number(value.decimal) + "\u{00A0}" + Self.unit(unit, environment)
  }

  /// «+1.5 м³» or «−3 м³»: the change against an earlier month; the minus is U+2212.
  @MainActor
  static func change(_ value: AmountE4, unit: String, _ environment: AppEnvironment) -> String {
    let sign = value.isNegative ? "\u{2212}" : "+"
    return sign + quantity(value.magnitude, unit: unit, environment)
  }
}

/// «Коммуналка»: the meters of the home with what each used this month against the month before
/// and the same month a year ago, the readings that are due, and the bills of the providers. A
/// meter may name the payment of «Планирование» that pays for it.
struct UtilitiesScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.layoutIdiom) private var idiom
  @State private var editingMeter: UtilityMeter?
  @State private var addsMeter = false
  @State private var readingFor: UtilityMeter?
  @State private var editingBill: UtilityBill?
  @State private var addsBill = false

  private func t(_ key: String) -> String { UtilitiesText.t(key, environment) }

  private var book: UtilityBook { compute.snapshot?.dataset.utilities ?? UtilityBook() }
  private var month: MonthKey { environment.today.monthKey }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(verbatim: t("utilities.title")).appFont(.title2.weight(.semibold))
        Spacer()
        Button {
          dismiss()
        } label: {
          Text(verbatim: environment.language("action.close"))
            // A finger needs 44 pt; the Mac keeps the button as it was.
            .frame(minHeight: LayoutIdiom.resolved(idiom) == .mac ? 0 : 44)
            .contentShape(.rect)
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding(16)
      Form {
        dueSection
        metersSection
        billsSection
      }
      .formStyle(.grouped)
    }
    .sheetFrame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 680)
    .sheet(isPresented: $addsMeter) {
      UtilityMeterForm(meter: nil).handingOver(dependencies)
    }
    .sheet(item: $editingMeter) { meter in
      UtilityMeterForm(meter: meter).handingOver(dependencies)
    }
    .sheet(item: $readingFor) { meter in
      UtilityReadingForm(meter: meter).handingOver(dependencies)
    }
    .sheet(isPresented: $addsBill) {
      UtilityBillForm(bill: nil).handingOver(dependencies)
    }
    .sheet(item: $editingBill) { bill in
      UtilityBillForm(bill: bill).handingOver(dependencies)
    }
    .accessibilityIdentifier("utilities.screen")
  }

  // MARK: Due readings

  @ViewBuilder
  private var dueSection: some View {
    let due = UtilityReminder.due(book, today: environment.today)
    if !due.isEmpty {
      Section {
        ForEach(due) { meter in
          HStack {
            Label {
              Text(verbatim: meter.name)
            } icon: {
              Image(systemName: "bell.badge")
            }
            Spacer()
            if let window = UtilityReminder.window(of: meter, containing: environment.today) {
              Text(
                verbatim: environment.format(
                  "utilities.due.until", table: UtilitiesText.table,
                  environment.dates.dayMonth(window.end))
              )
              .secondaryInk()
            }
            Button(t("utilities.reading.add")) { readingFor = meter }
          }
          .accessibilityIdentifier("utilities.due.\(meter.id.uuidString)")
        }
      } header: {
        Text(verbatim: t("utilities.due")).settingsHeaderStyle()
      }
    }
  }

  // MARK: Meters

  private var metersSection: some View {
    Section {
      let meters = book.meters.filter { !$0.archived }
      if meters.isEmpty {
        Text(verbatim: t("utilities.meters.empty")).secondaryInk()
      }
      ForEach(meters) { meter in
        meterRow(meter)
      }
      Button(t("utilities.meter.add")) { addsMeter = true }
        .accessibilityIdentifier("utilities.meter.add")
    } header: {
      Text(verbatim: t("utilities.meters")).settingsHeaderStyle()
    }
  }

  private func meterRow(_ meter: UtilityMeter) -> some View {
    let readings = UtilityUsage.ordered(book.readings, of: meter)
    let comparison = UtilityUsage.compare(meter, readings: readings, month: month)
    let shown =
      comparison.current
      ?? UtilityUsage.compare(
        meter, readings: readings, month: month.previous
      ).current
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: Self.symbol(meter.kind)).secondaryInk()
        Text(verbatim: meter.name).appFont(.body.weight(.medium))
        Spacer()
        Button(t("utilities.reading.add")) { readingFor = meter }
        Button {
          editingMeter = meter
        } label: {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(verbatim: environment.language("action.edit")))
      }
      if let last = readings.last {
        Text(
          verbatim: environment.format(
            "utilities.reading.last", table: UtilitiesText.table,
            UtilitiesText.quantity(last.valueE4, unit: meter.unit, environment),
            environment.dates.dayMonth(last.day))
        )
        .appFont(.callout).secondaryInk()
      }
      if let shown {
        Text(verbatim: usageLine(meter, shown, comparison: comparison))
          .appFont(.callout).monospacedDigit()
      }
      if !UtilityUsage.decreases(of: meter, readings: readings).isEmpty {
        Label {
          Text(verbatim: t("utilities.reading.decreased"))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .appFont(.callout).foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 2)
    .accessibilityIdentifier("utilities.meter.\(meter.id.uuidString)")
  }

  /// «Ноябрь: 9 м³ · 450 ₽ · к октябрю +1 м³ · к ноябрю 2025 −3 м³».
  private func usageLine(
    _ meter: UtilityMeter, _ shown: UtilityUsage.Month, comparison: UtilityUsage.Comparison
  ) -> String {
    var parts = [
      environment.dates.monthTitle(shown.month) + ": "
        + UtilitiesText.quantity(shown.quantityE4, unit: meter.unit, environment)
    ]
    if let cost = shown.costE4 {
      parts.append(environment.money.rounded(cost, currency: meter.currency))
    }
    let base =
      shown.month == comparison.month
      ? comparison
      : UtilityUsage.compare(meter, readings: book.readings, month: shown.month)
    if let before = base.previousMonth {
      parts.append(
        environment.format(
          "utilities.vs.month", table: UtilitiesText.table,
          UtilitiesText.change(shown.quantityE4 - before.quantityE4, unit: meter.unit, environment)
        ))
    }
    if let yearAgo = base.previousYear {
      parts.append(
        environment.format(
          "utilities.vs.year", table: UtilitiesText.table,
          UtilitiesText.change(shown.quantityE4 - yearAgo.quantityE4, unit: meter.unit, environment)
        ))
    }
    return parts.joined(separator: " · ")
  }

  static func symbol(_ kind: UtilityKind) -> String {
    switch kind {
    case .coldWater, .hotWater: "drop"
    case .electricity: "bolt"
    case .gas: "flame"
    case .heat: "thermometer.medium"
    case .other: "gauge.with.dots.needle.33percent"
    }
  }

  // MARK: Bills

  private var billsSection: some View {
    Section {
      let bills = book.bills.sorted { ($0.period, $0.provider) > ($1.period, $1.provider) }
      if bills.isEmpty {
        Text(verbatim: t("utilities.bills.empty")).secondaryInk()
      }
      ForEach(bills) { bill in
        Button {
          editingBill = bill
        } label: {
          billRow(bill)
        }
        .buttonStyle(.plain)
      }
      Button(t("utilities.bill.add")) { addsBill = true }
        .accessibilityIdentifier("utilities.bill.add")
    } header: {
      Text(verbatim: t("utilities.bills")).settingsHeaderStyle()
    } footer: {
      Text(verbatim: t("utilities.bills.footer"))
        .appFont(.callout).secondaryInk()
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func billRow(_ bill: UtilityBill) -> some View {
    let comparison = UtilityBills.compare(book.bills, provider: bill.provider, month: bill.period)
    var notes: [String] = []
    if let current = comparison.current, let before = comparison.previousMonth {
      notes.append(
        environment.format(
          "utilities.vs.month", table: UtilitiesText.table,
          environment.money.signedRounded(current - before, currency: bill.currency)))
    }
    if let current = comparison.current, let yearAgo = comparison.previousYear {
      notes.append(
        environment.format(
          "utilities.vs.year", table: UtilitiesText.table,
          environment.money.signedRounded(current - yearAgo, currency: bill.currency)))
    }
    return VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(verbatim: bill.provider)
        Spacer()
        Text(verbatim: environment.money.exact(bill.totalE4, currency: bill.currency))
          .monospacedDigit()
      }
      Text(
        verbatim: ([environment.dates.monthTitle(bill.period)] + notes).joined(separator: " · ")
      )
      .appFont(.callout).secondaryInk()
    }
    .contentShape(Rectangle())
  }
}
