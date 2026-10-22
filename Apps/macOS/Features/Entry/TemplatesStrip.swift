import AppCore
import AppDatabase
import SwiftUI

/// Chips under the entry line: operations I repeat often, plus the ones I pinned myself.
/// Tapping a chip fills the line, so the next step is still Enter.
struct TemplatesStrip: View {
  let model: TemplatesModel
  /// The currency a chip enters its amount in, as the entry line will read it
  /// (`Templates.currency(of:in:model:)`).
  let currencyOf: (Template) -> CurrencyCode
  @Dependency(\.environment) private var environment
  let onPick: (Template) -> Void

  /// A pin the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(model.templates.prefix(8), id: \.id) { template in
          Button {
            onPick(template)
            model.use(template)
          } label: {
            HStack(spacing: 4) {
              if template.pinned {
                Image(systemName: "pin.fill").appFont(.caption2)
              }
              Text(verbatim: title(for: template))
            }
          }
          .buttonStyle(.glass)
          .controlSize(.small)
          .contextMenu {
            Button(
              environment.language(
                template.pinned ? "templates.unpin" : "templates.pin", table: "Entry")
            ) {
              if !model.togglePin(template) { refused = true }
            }
            Button(environment.language("templates.archive", table: "Entry")) {
              if !model.archive(template) { refused = true }
            }
          }
        }
      }
      .padding(.horizontal, 2)
    }
    .scrollIndicators(.never)
    .frame(height: model.templates.isEmpty ? 0 : 34)
    .opacity(model.templates.isEmpty ? 0 : 1)
    .refusedWriteAlert($refused, environment)
  }

  /// The amount in the currency the chip enters it in.
  private func title(for template: Template) -> String {
    guard let amount = template.amountE4 else { return template.text }
    let currency = currencyOf(template)
    return "\(template.text) \(environment.money.rounded(amount, currency: currency))"
  }
}

extension Notification.Name {
  /// The templates were written: the chips and Settings → Шаблоны read them again. Neither
  /// learns it otherwise — a template is no operation, and writing one starts no recount.
  static let templatesChanged = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.templatesChanged")
}

/// The chips the strip shows, and every write that changes them. The entry line saves through
/// the same model the strip reads, so a chip appears with the first save of its words and a
/// count or an amount moves with the next one — the strip used to read the templates only when
/// it appeared, and the line wrote them behind its back. `EntryBar` also reads them again after
/// every change of the data (a restore, an archive brought in), and Settings → Шаблоны says
/// when it writes (`templatesChanged`).
///
/// A chip is a copy read some time ago: the template may have gone to the archive, been
/// renamed or deleted since. So a chip writes only what it changes — the count, the pin, the
/// archive flag — and never the whole row back.
@MainActor
@Observable
final class TemplatesModel {
  private(set) var templates: [Template] = []
  /// Puts the chips in the order of the owner's habits (time of day, day of the week); unset,
  /// they stay as the dictionary has them.
  @ObservationIgnored var ordering: (([Template]) -> [Template])?
  @ObservationIgnored private var references: ReferenceRepository?
  @ObservationIgnored private var observer: (any NSObjectProtocol)?

  /// The dictionaries of the window, handed over when the entry line appears.
  func attach(_ references: ReferenceRepository?) {
    self.references = references
    if observer == nil {
      observer = NotificationCenter.default.addObserver(
        forName: .templatesChanged, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.reload() }
      }
    }
    reload()
  }

  /// The chips: the templates in the archive are not among them.
  func reload() {
    let all = (try? references?.templates(includeArchived: false)) ?? []
    templates = ordering?(all) ?? all
  }

  /// An operation the line saved: remembered as a chip when a chip can say it again, and the
  /// strip shows it at once.
  func remember(_ draft: TransactionDraft, categories: [CoreKit.Category]) {
    Templates.remember(draft, categories: categories, in: references)
    changed()
  }

  /// A chip picked counts as one more use. Bookkeeping the owner did not ask for: a refused
  /// count goes to the journal only.
  func use(_ template: Template) {
    AppEnvironment.attempt("templates.count", on: references) {
      try $0.countTemplateUse(template.id)
    }
    changed()
  }

  /// Pins a chip or takes its pin off, and says whether the write landed: a refused pin is
  /// the owner's own choice lost, so the strip says so (`refusedWriteAlert`).
  @discardableResult
  func togglePin(_ template: Template) -> Bool {
    let written = AppEnvironment.attempt("templates.save", on: references) {
      try $0.setTemplate(template.id, pinned: !template.pinned)
    }
    changed()
    return written
  }

  /// Puts a chip away: it leaves the strip and stays in Settings → Шаблоны, where «Вернуть»
  /// brings it back. Says whether the write landed, as a pin does.
  @discardableResult
  func archive(_ template: Template) -> Bool {
    let written = AppEnvironment.attempt("templates.archive", on: references) {
      try $0.setTemplate(template.id, archived: true)
    }
    changed()
    return written
  }

  /// Reads the chips again, and tells Settings → Шаблоны, which may be open beside them.
  private func changed() {
    reload()
    NotificationCenter.default.post(name: .templatesChanged, object: nil)
  }
}

/// What a chip is made of and what it gives back. A chip puts a line into the entry line and
/// Enter saves what that line says, so the line says everything the template knows: «+» for an
/// income, the amount, the code of a currency other than the ruble. The templates table keeps
/// no kind, so an income is told by its category:
/// an operation filed under an income category is income, the panel keeps the two in step.
enum Templates {
  /// The line a chip puts into the entry line: «+ подарок 5000», «lunch 20.5 USD». The «+»
  /// stands apart — glued to the word it would stay in the description. The code of the
  /// currency is written whenever it is not `defaultCurrency`, the one the line reads an amount
  /// in when it names none: a ruble template says «RUB» once the default is the tenge.
  ///
  /// The amount goes after the description, unless the line would not read it back there: a
  /// description ending in a number the line refused («обед 100-250») would make one formula
  /// of the two by the space that groups thousands — «100-250 250» —, and the chip would enter
  /// no amount at all. Then the amount moves in front of the description, or between its
  /// words, to the first place where the line reads the same amount, currency and description
  /// again; a description of such numbers alone keeps the amount apart with its currency's
  /// code, written even when it is `defaultCurrency` — Enter reads the same currency either way.
  static func line(
    for template: Template, categories: [CoreKit.Category], defaultCurrency: CurrencyCode = .rub
  ) -> String {
    let plain = plainLine(for: template, categories: categories, defaultCurrency: defaultCurrency)
    // Only a description with a digit in it can take the amount into a formula.
    guard let units = template.amountE4, template.text.contains(where: \.isNumber) else {
      return plain
    }
    let sign = isIncome(template.categoryId, among: categories) ? ["+"] : []
    let note = template.text.split(separator: " ").map(String.init)
    let currency = template.currency ?? defaultCurrency
    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)
    let today = CalendarContext.utc.day(of: Date())
    func readsBack(_ line: String) -> Bool {
      let read = parser.parse(line, today: today)
      return read.amount == units.decimal && read.note == note.joined(separator: " ")
        && (read.currency ?? defaultCurrency) == currency && read.date == nil
        && read.dateProblem == nil
    }
    if readsBack(plain) { return plain }
    let number = FieldNumber.text(units)
    let named = currency == defaultCurrency ? [number] : [number, currency.code]
    for amount in [named, [number, currency.code]] {
      for cut in [0] + Array((1..<max(note.count, 1)).reversed()) {
        let line = (sign + note[..<cut] + amount + note[cut...]).joined(separator: " ")
        if readsBack(line) { return line }
      }
    }
    return plain
  }

  /// The chip's line with the amount after the description, the way it is written whenever the
  /// line reads it back: «+ подарок 5000», «lunch 20.5 USD».
  private static func plainLine(
    for template: Template, categories: [CoreKit.Category], defaultCurrency: CurrencyCode
  ) -> String {
    var words: [String] = []
    if isIncome(template.categoryId, among: categories) { words.append("+") }
    words.append(template.text)
    if let amount = template.amountE4 { words.append(FieldNumber.text(amount)) }
    if let currency = template.currency, currency != defaultCurrency {
      words.append(currency.code)
    }
    return words.joined(separator: " ")
  }

  /// The currency a chip enters its amount in, and so the one it shows it in: the template's
  /// own, or — when it names none, and `line(for:…)` writes no code — the currency the entry
  /// line reads an amount without a code in, `lineDefault`. The chip, Settings → Шаблоны and
  /// the line are handed the same one, so what a chip says is what Enter saves.
  static func currency(of template: Template, lineDefault: CurrencyCode = .rub) -> CurrencyCode {
    template.currency ?? lineDefault
  }

  /// The currency the entry line of the app reads an amount without a code in: the main
  /// currency of the live account whose screen is open — a new operation goes to that account
  /// and takes its currency —, otherwise «Валюта по умолчанию».
  @MainActor static func lineCurrency(in environment: AppEnvironment) -> CurrencyCode {
    let screen = environment.focusedAccountId.flatMap { id in
      ((try? environment.references?.paymentMethods()) ?? nil)?.first { $0.id == id }
    }
    return AccountRules.currencyForNewOperation(
      typed: nil, chosenAccount: screen, default: environment.defaultCurrency)
  }

  /// The line a chip of the app puts into its entry line, which reads an amount without a code
  /// in `lineCurrency(in:)`: a ruble chip says «RUB» once the default is the tenge, or on the
  /// screen of a tenge account, or it would save tenge.
  @MainActor static func line(
    for template: Template, categories: [CoreKit.Category], in environment: AppEnvironment
  ) -> String {
    line(for: template, categories: categories, in: environment, model: nil)
  }

  /// The same for the entry line whose panel is `model`. The chip names its currency whenever
  /// Enter would read its line without the code in another one — the panel's account or
  /// currency, the screen open now —, and only then.
  @MainActor static func line(
    for template: Template, categories: [CoreKit.Category], in environment: AppEnvironment,
    model: EntryDraftModel?
  ) -> String {
    let plain = plainLine(
      for: template, categories: categories, defaultCurrency: template.currency ?? .rub)
    return line(
      for: template, categories: categories,
      defaultCurrency: readCurrency(of: plain, in: environment, model: model))
  }

  /// The currency Enter saves `line` in when it names none: the panel's own answer, which
  /// follows the save (`EntryPreview.currency`).
  @MainActor static func readCurrency(
    of line: String, in environment: AppEnvironment, model: EntryDraftModel?
  ) -> CurrencyCode {
    let parsed = CoreLineInterpreter(
      vocabulary: environment.vocabulary, calendar: environment.calendar,
      catalog: environment.currencyCatalog
    ).interpret(line, today: environment.today, kind: model?.draft.kind)
    return EntryPreview.currency(of: parsed, model: model, in: environment)
  }

  /// The currency a chip of the app enters and shows its amount in: a template that names none
  /// is entered in the currency its line is read in — with the panel `model`, the one it gives.
  @MainActor static func currency(
    of template: Template, in environment: AppEnvironment, model: EntryDraftModel? = nil
  ) -> CurrencyCode {
    if let currency = template.currency { return currency }
    guard model != nil else { return lineCurrency(in: environment) }
    return readCurrency(
      of: plainLine(for: template, categories: [], defaultCurrency: .rub), in: environment,
      model: model)
  }

  /// Whether a chip can enter this operation again: only what its line can say. An expense,
  /// or an income filed under an income category — without a category an income would come
  /// back as an expense. A refund, money given back, a payment of a debt and a contribution to
  /// a goal need words the template does not keep (the kind, the debt, the goal), and their
  /// chip would enter a plain expense instead; they are not made chips.
  static func canRemember(_ draft: TransactionDraft, categories: [CoreKit.Category]) -> Bool {
    guard draft.debtId == nil, !draft.parts.contains(where: { $0.goalId != nil }) else {
      return false
    }
    switch draft.kind {
    case .expense: return true
    case .income: return isIncome(draft.parts.first?.categoryId, among: categories)
    case .refund, .reimbursement: return false
    }
  }

  /// Remembers what I enter, so the chips fill themselves from real usage. A template follows
  /// its last use: the amount, the currency, and the category unless the operation had none —
  /// but never a category of the other kind, which would turn the chip into an income (or out
  /// of one) the operation was not.
  static func remember(
    _ draft: TransactionDraft, categories: [CoreKit.Category], in references: ReferenceRepository?
  ) {
    guard let note = draft.note, !note.trimmingCharacters(in: .whitespaces).isEmpty,
      canRemember(draft, categories: categories)
    else { return }
    let categoryId = draft.parts.first?.categoryId
    // The operation itself is saved by then; a template refused goes to the journal only. A
    // list that could not be read writes nothing, rather than a second chip of the same text.
    // A template in the archive counts too, and stays there: it was put away on purpose, and
    // a second chip of its words would bring back what the owner took off the strip.
    AppEnvironment.attempt("templates.remember", on: references) { references in
      let existing = try references.templates()
      if var template = existing.first(where: {
        $0.text.caseInsensitiveCompare(note) == .orderedSame
      }) {
        let keepsItsCategory =
          isIncome(template.categoryId, among: categories) == (draft.kind == .income)
        template.useCount += 1
        template.amountE4 = draft.amount
        template.currency = draft.currency
        template.categoryId = categoryId ?? (keepsItsCategory ? template.categoryId : nil)
        try references.save(template)
      } else {
        try references.save(
          Template(
            text: note, categoryId: categoryId, amountE4: draft.amount, currency: draft.currency,
            useCount: 1))
      }
    }
  }

  private static func isIncome(_ categoryId: UUID?, among categories: [CoreKit.Category]) -> Bool {
    guard let categoryId else { return false }
    return categories.first { $0.id == categoryId }?.kind == .income
  }
}
