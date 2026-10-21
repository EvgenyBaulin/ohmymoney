import AppCore
import AppDatabase
import SwiftUI

/// «Налог» of an income category, while the owner is self-employed: none, the two rates of the
/// tax on professional income (from individuals, from organisations — as the reference says
/// now), another rate typed by hand (the simplified tax, a contract with income tax) or, for a
/// subcategory, what the category above says.
enum TaxChoice: Hashable {
  /// A subcategory follows its category.
  case inherit
  /// No tax. On a subcategory it is said in so many words — a rate of zero —, so a taxed
  /// category above does not tax it.
  case none
  /// The tax on professional income at this rate.
  case npd(Decimal)
  /// Another rate, without the deduction and the 100-ruble rule.
  case other(Decimal)
}

enum CategoryTax {
  /// The choices of the menu of `category`, in order; «Другая…» is the menu's own item.
  static func choices(
    for category: CoreKit.Category, reference: NPDReference
  ) -> [TaxChoice] {
    var choices: [TaxChoice] = category.parentId == nil ? [] : [.inherit]
    choices.append(.none)
    choices.append(.npd(reference.individualsRate))
    if reference.organizationsRate != reference.individualsRate {
      choices.append(.npd(reference.organizationsRate))
    }
    return choices
  }

  /// What the menu shows as chosen for what is stored.
  static func choice(of category: CoreKit.Category) -> TaxChoice {
    guard let tax = category.tax else { return category.parentId == nil ? .none : .inherit }
    if tax.rate <= 0 { return .none }
    return tax.npd ? .npd(tax.rate) : .other(tax.rate)
  }

  /// What is stored for a choice: nothing for «как у категории» and for «нет» at the top, a
  /// rate of zero for «нет» on a subcategory.
  static func value(of choice: TaxChoice, for category: CoreKit.Category) -> IncomeTax? {
    switch choice {
    case .inherit: nil
    case .none: category.parentId == nil ? nil : IncomeTax(rate: 0)
    case .npd(let rate): IncomeTax(rate: rate, npd: true)
    case .other(let rate): IncomeTax(rate: rate)
    }
  }

  /// Whether the category can carry a tax: an income category of the owner's — a system one
  /// («Доплаты», «Сверка») never does.
  static func isFixed(_ category: CoreKit.Category, in tree: CategoryTree) -> Bool {
    category.kind != .income || tree.systemRole(of: category.id) != nil
  }

  /// The new tax of a category as one step of ⌘Z; `nil` when it is what is stored already or
  /// the category cannot carry one.
  static func change(
    _ category: CoreKit.Category, to choice: TaxChoice, tree: CategoryTree, at now: Date
  ) -> PlanningChange? {
    guard !isFixed(category, in: tree) else { return nil }
    let value = value(of: choice, for: category)
    guard value != category.tax else { return nil }
    var updated = category
    updated.tax = value
    return PlanningChange(upsert: PlanningRows(categories: [updated]), at: now)
  }

  /// A rate typed into «Другая…»: above zero, no more than a hundred.
  static func rate(_ text: String) -> Decimal? {
    SelfEmploymentSettingsForm.percent(text)
  }

  /// The words of a choice: «Нет», «Как у категории», «4 % НПД», «6 %».
  @MainActor
  static func title(_ choice: TaxChoice, _ environment: AppEnvironment) -> String {
    switch choice {
    case .inherit: environment.language("categories.tax.inherit", table: "Settings")
    case .none: environment.language("categories.tax.none", table: "Settings")
    case .npd(let rate):
      environment.format(
        "categories.tax.npd", table: "Settings", environment.money.number(rate))
    case .other(let rate):
      environment.format(
        "categories.tax.rate", table: "Settings", environment.money.number(rate))
    }
  }

  /// The mark of a row with a tax that counts for it, its own or its category's; `nil` for none.
  @MainActor
  static func mark(_ id: UUID, tree: CategoryTree, _ environment: AppEnvironment) -> String? {
    guard let tax = tree.tax(of: id), tax.rate > 0 else { return nil }
    return title(tax.npd ? .npd(tax.rate) : .other(tax.rate), environment)
  }
}

/// «Другая…» of the menu of a tax: a rate typed by hand. A sheet over the settings.
struct OtherTaxSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  let category: CoreKit.Category
  /// Writes the rate; false — the database refused.
  let save: (Decimal) -> Bool
  @State private var text: String
  @State private var failed = false

  init(category: CoreKit.Category, save: @escaping (Decimal) -> Bool) {
    self.category = category
    self.save = save
    let rate = category.tax.flatMap { $0.rate > 0 ? $0.rate : nil }
    _text = State(initialValue: rate.map { "\($0)" } ?? "")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        verbatim: environment.format("categories.tax.otherTitle", table: "Settings", category.name)
      )
      .appFont(.headline)
      Form {
        TextField(text: $text, prompt: Text(verbatim: "6")) {
          Text(verbatim: t("categories.tax.otherRate"))
        }
        .accessibilityIdentifier("categories.tax.otherRate")
        .onSubmit(commit)
      }
      .formStyle(.grouped)
      Text(
        verbatim: t(
          rate == nil && !text.isEmpty
            ? "settings.selfEmployed.refusal.percent" : "categories.tax.otherHint")
      )
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if failed {
        Text(verbatim: t("settings.write.refused"))
          .appFont(.callout)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: commit)
          .keyboardShortcut(.defaultAction)
          .disabled(rate == nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 380)
  }

  private var rate: Decimal? { CategoryTax.rate(text) }

  private func commit() {
    guard let rate else { return }
    if save(rate) { dismiss() } else { failed = true }
  }
}
