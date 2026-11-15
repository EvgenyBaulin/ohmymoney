import AppCore
import AppDatabase
import SwiftUI

/// The words of «Вычеты за год» and of the fields that mark a deduction, in the language of the
/// moment; apart from the views so a test reads them in both languages.
@MainActor
enum DeductionsText {
  static let table = "Deductions"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func kind(_ kind: TaxDeductionKind?, _ environment: AppEnvironment) -> String {
    t("deductions.kind.\(kind?.rawValue ?? "none")", environment)
  }

  static func document(_ document: TaxDeductionDocument, _ environment: AppEnvironment) -> String {
    t("deductions.document.\(document.rawValue)", environment)
  }

  /// The title of a group; a child's group names the child when the parts named one.
  static func title(
    of key: TaxDeductionGroup.Key, people: [Person], _ environment: AppEnvironment
  ) -> String {
    switch key {
    case .social: return t("deductions.group.social", environment)
    case .medicalExpensive: return t("deductions.group.medicalExpensive", environment)
    case .child(let person):
      guard let name = people.first(where: { $0.id == person })?.name else {
        return t("deductions.group.childUnnamed", environment)
      }
      return environment.format("deductions.group.child", table: table, name)
    case .iis: return t("deductions.group.iis", environment)
    case .mortgageInterest: return t("deductions.group.mortgage", environment)
    }
  }

  /// The rate «до N ₽» is counted at, as a percentage in the language of the moment.
  static func percent(_ value: Decimal, _ environment: AppEnvironment) -> String {
    let basisPoints = (try? DecimalMath.int64(rounding: value * 100)) ?? 0
    return environment.money.percent(basisPoints: Int(basisPoints), fractionDigits: 0)
  }
}

/// «Вычеты за год»: what the marked spending, the transfers into an individual investment
/// account and the interest of a mortgage give back for a year, group by group up to its limit,
/// and the documents the tax office asks for. The figure is exact when the owner gives the
/// taxable income of the year and «до N ₽» without it — nothing is guessed from the operations.
struct TaxDeductionsSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var year = 0
  @State private var report: TaxDeductionYear?
  @State private var incomeText = ""
  @State private var income: AmountE4?

  private func t(_ key: String) -> String { DeductionsText.t(key, environment) }

  private var years: [Int] {
    let this = environment.today.year
    let first = TaxDeductionRules.builtIn.years.first?.year ?? this
    return Array((min(first, this)...this).reversed())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(verbatim: t("deductions.title")).appFont(.headline)
        Spacer()
        Picker(selection: $year) {
          ForEach(years, id: \.self) { Text(verbatim: String($0)).tag($0) }
        } label: {
          Text(verbatim: t("deductions.title"))
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("deductions.year")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let report {
            summary(report)
            incomeRow
            if report.isEmpty {
              Text(verbatim: t("deductions.empty"))
                .secondaryInk()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("deductions.empty")
            } else {
              ForEach(report.groups) { group in groupView(group) }
              documents(report)
            }
          } else {
            ProgressView()
          }
          Text(verbatim: t("deductions.hint"))
            .appFont(.caption)
            .secondaryInk()
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 560, height: 640)
    .task {
      if year == 0 { year = environment.today.year }
    }
    .task(id: TaskKey(year: year, income: income)) { await load() }
    .onChange(of: year) { readIncome() }
    .accessibilityIdentifier("deductions.sheet")
  }

  private struct TaskKey: Hashable {
    var year: Int
    var income: AmountE4?
  }

  private func load() async {
    guard year != 0, let snapshot = compute.snapshot else { return }
    if incomeText.isEmpty && income == nil { readIncome() }
    let chosen = year
    let given = income
    report = await Task.detached(priority: .userInitiated) {
      TaxDeductionReport.year(
        chosen, ledger: snapshot.ledger, rubPerUnit: snapshot.planning.rubPerUnit, income: given)
    }.value
  }

  // MARK: The figure

  @ViewBuilder
  private func summary(_ report: TaxDeductionYear) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let refund = report.refund {
        Text(
          verbatim: environment.format(
            report.isUpperBound ? "deductions.refund.upTo" : "deductions.refund",
            table: DeductionsText.table, environment.money.rounded(refund))
        )
        .appFont(.title3.monospacedDigit())
        .accessibilityIdentifier("deductions.refund")
        Text(
          verbatim: environment.format(
            "deductions.claimable", table: DeductionsText.table,
            environment.money.rounded(report.claimable))
        )
        .monospacedDigit()
        if report.isUpperBound, let rules = report.rules {
          Text(
            verbatim: environment.format(
              "deductions.refund.upToHint", table: DeductionsText.table,
              DeductionsText.percent(rules.basePercent, environment))
          )
          .appFont(.caption)
          .secondaryInk()
          .fixedSize(horizontal: false, vertical: true)
        } else if !report.isUpperBound {
          Text(verbatim: t("deductions.refund.exactHint"))
            .appFont(.caption)
            .secondaryInk()
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text(verbatim: t("deductions.noRules"))
          .secondaryInk()
          .accessibilityIdentifier("deductions.noRules")
      }
    }
  }

  // MARK: The income of the year

  private var incomeRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: t("deductions.income")).appFont(.caption).secondaryInk()
      HStack {
        TextField(
          text: $incomeText, prompt: Text(verbatim: t("deductions.income.prompt"))
        ) {
          Text(verbatim: t("deductions.income"))
        }
        .labelsHidden()
        .monospacedDigit()
        .onSubmit { saveIncome() }
        .accessibilityIdentifier("deductions.income")
        Button(t("deductions.income.save")) { saveIncome() }
          .disabled(TaxDeductionIncome.income(from: incomeText) == income)
        if income != nil {
          Button(t("deductions.income.clear")) {
            incomeText = ""
            saveIncome()
          }
        }
      }
    }
  }

  private func readIncome() {
    guard year != 0 else { return }
    let stored = (try? environment.settings?.string(TaxDeductionIncome.key(year))) ?? nil
    income = TaxDeductionIncome.income(from: stored)
    incomeText = income.map(TaxDeductionIncome.text) ?? ""
  }

  /// The income goes to the settings of the database, so it travels with the data; an empty
  /// field takes the key away.
  private func saveIncome() {
    guard year != 0 else { return }
    let key = TaxDeductionIncome.key(year)
    let trimmed = incomeText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      try? environment.settings?.remove(key)
      income = nil
    } else if let value = TaxDeductionIncome.income(from: trimmed) {
      try? environment.settings?.set(key, to: TaxDeductionIncome.text(value))
      income = value
      incomeText = TaxDeductionIncome.text(value)
    }
  }

  // MARK: The groups

  private func groupView(_ group: TaxDeductionGroup) -> some View {
    let people = compute.snapshot?.ledger.dataset.people ?? []
    return VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: DeductionsText.title(of: group.key, people: people, environment))
        .appFont(.subheadline.weight(.semibold))
      ForEach(TaxDeductionKind.allCases.filter { group.byKind[$0] != nil }, id: \.self) { kind in
        if group.byKind.count > 1 {
          HStack {
            Text(verbatim: DeductionsText.kind(kind, environment))
            Spacer()
            Text(verbatim: environment.money.rounded(group.byKind[kind] ?? .zero))
              .monospacedDigit()
          }
          .secondaryInk()
        }
      }
      HStack(spacing: 8) {
        Text(
          verbatim: environment.format(
            "deductions.group.spent", table: DeductionsText.table,
            environment.money.rounded(group.spent)))
        Text(
          verbatim: group.limit.map {
            environment.format(
              "deductions.group.limit", table: DeductionsText.table, environment.money.rounded($0))
          } ?? t("deductions.group.noLimit")
        )
        .secondaryInk()
        Spacer()
        Text(
          verbatim: environment.format(
            "deductions.group.claimable", table: DeductionsText.table,
            environment.money.rounded(group.claimable))
        )
        .appFont(.body.weight(.medium))
      }
      .monospacedDigit()
      if group.key == .mortgageInterest {
        Text(verbatim: t("deductions.group.mortgageNote"))
          .appFont(.caption)
          .secondaryInk()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: The documents

  private func documents(_ report: TaxDeductionYear) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: t("deductions.documents")).appFont(.subheadline.weight(.semibold))
      ForEach(
        TaxDeductionDocument.common + TaxDeductionDocument.needed(for: report.kinds), id: \.self
      ) { document in
        Label {
          Text(verbatim: DeductionsText.document(document, environment))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "doc.text")
        }
      }
    }
    .accessibilityIdentifier("deductions.documents")
  }
}
