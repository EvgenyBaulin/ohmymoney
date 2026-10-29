import AppCore
import AppDatabase
import SwiftUI

/// «Витрина вкладов»: the deposits banks publish, sorted by rate, narrowed by the term, the
/// amount and a top-up, with the day each rate was read — grey and «могла измениться» past 30
/// days — and the owner's own offers beside them. Not advice, and it says so.
struct DepositShowcaseSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @State private var termChoice: Int = 0
  @State private var amount: AmountE4 = .zero
  @State private var requiresTopup = false
  @State private var own: [DepositOffer] = []
  @State private var editing: DepositOfferEditor.Target?
  @State private var parserOn = false
  @State private var fetched: [DepositShowcaseEntry] = []
  @State private var indicator: CentralBankIndicator?
  @State private var fetchFailed = false
  @State private var settingLoaded = false

  /// The terms offered by the filter, in months; 0 is «любой».
  static let terms = [0, 1, 3, 6, 12, 24, 36]

  private func t(_ key: String) -> String { DepositText.t(key, environment) }

  var filter: DepositFilter {
    DepositFilter(
      termMonths: termChoice == 0 ? nil : termChoice, amountE4: amount.raw > 0 ? amount : nil,
      requiresTopup: requiresTopup)
  }

  var body: some View {
    let today = environment.today
    let shownFetched = parserOn ? fetched : []
    let entries = DepositShowcase.entries(fetched: shownFetched, own: own, filter: filter)
    let discrepancies = DepositShowcase.discrepancies(
      DepositShowcaseData.entries + shownFetched
        + own.filter { !$0.archived }.map(DepositShowcaseEntry.init))
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("dep.title")).appFont(.headline)
      Text(verbatim: t("dep.subtitle")).appFont(.callout).foregroundStyle(.secondary)
      Form {
        Picker(t("dep.filter.term"), selection: $termChoice) {
          ForEach(Self.terms, id: \.self) { months in
            Text(verbatim: months == 0 ? t("dep.filter.any") : "\(months)").tag(months)
          }
        }
        LabeledContent(t("dep.filter.amount")) {
          AmountField(amount: $amount, locale: environment.language.locale)
            .frame(maxWidth: 160)
        }
        Toggle(t("dep.filter.topup"), isOn: $requiresTopup)
        Toggle(t("dep.parser"), isOn: $parserOn)
          .accessibilityIdentifier("deposits.parser")
      }
      .formStyle(.grouped)
      .frame(maxHeight: 190)
      if parserOn, fetchFailed {
        Text(verbatim: t("dep.parser.failed")).appFont(.caption).foregroundStyle(.secondary)
      }
      if parserOn, let indicator {
        centralBankBlock(indicator)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          if entries.isEmpty {
            Text(verbatim: t("dep.none")).foregroundStyle(.secondary)
          }
          ForEach(entries) { entry in
            row(
              entry, today: today,
              discrepancy: discrepancies[DepositShowcase.bankKey(entry.bankName)])
          }
        }
      }
      Text(
        verbatim: DepositText.f(
          "dep.version", environment, environment.dates.longDay(DepositShowcaseData.readOn))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
      HStack {
        Button(t("dep.add")) { editing = .new }
          .accessibilityIdentifier("deposits.add")
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 560, height: 620)
    .task {
      reload()
      await loadParserSetting()
    }
    .onChange(of: parserOn) { _, on in
      guard settingLoaded else { return }
      try? environment.settings?.set(DepositParserSetting.key, to: DepositParserSetting.stored(on))
      if on { Task { await refreshFetched() } }
    }
    .sheet(item: $editing, onDismiss: reload) { target in
      DepositOfferEditor(target: target).handingOver(dependencies)
    }
  }

  /// «По данным Банка России»: the market mark, apart from the banks and never as a rate of one.
  private func centralBankBlock(_ indicator: CentralBankIndicator) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Label(t("dep.cbr.title"), systemImage: "building.columns").appFont(.callout)
      Text(
        verbatim: DepositText.f(
          "dep.cbr.body", environment, "\(indicator.ratePercent)",
          environment.dates.longDay(indicator.periodStart))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("deposits.centralBank")
  }

  private func row(
    _ entry: DepositShowcaseEntry, today: DateOnly, discrepancy: DepositDiscrepancy?
  ) -> some View {
    let stale = entry.isStale(on: today)
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: entry.bankName)
          if !entry.product.isEmpty {
            Text(verbatim: entry.product).foregroundStyle(.secondary)
          }
          if case .own = entry.origin {
            Text(verbatim: t("dep.own")).appFont(.caption).foregroundStyle(.secondary)
          }
        }
        let details = DepositText.details(entry, environment)
        if !details.isEmpty {
          Text(verbatim: details).appFont(.caption).foregroundStyle(.secondary)
        }
        let date = DepositText.rateDate(entry, today: today, environment)
        if !date.isEmpty {
          Label {
            Text(verbatim: date)
          } icon: {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "calendar")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
        if let discrepancy {
          Label {
            Text(verbatim: DepositText.discrepancy(discrepancy, environment))
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      Text(verbatim: DepositText.rate(entry, environment))
        .monospacedDigit()
        .foregroundStyle(entry.ratePercent == nil || stale ? .secondary : .primary)
      if case .own(let id) = entry.origin, let offer = own.first(where: { $0.id == id }) {
        Menu {
          Button(environment.language("action.edit")) { editing = .edit(offer) }
          Button(environment.language("action.delete"), role: .destructive) {
            try? environment.depositOffers?.delete(id: id)
            reload()
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func loadParserSetting() async {
    let stored = (try? environment.settings?.string(DepositParserSetting.key)) ?? nil
    parserOn = DepositParserSetting.isEnabled(from: stored)
    settingLoaded = true
    if parserOn { await refreshFetched() }
  }

  private func refreshFetched() async {
    let result = await DepositRateService().load(today: environment.today)
    fetched = result.entries
    indicator = result.indicator
    fetchFailed = result.failed
  }

  private func reload() {
    own = (try? environment.depositOffers?.all()) ?? []
  }
}

/// «Добавить предложение…» and the edit of one: the bank, the rate, the term, the amounts, and the
/// conditions the owner read on the bank's page.
struct DepositOfferEditor: View {
  enum Target: Identifiable {
    case new
    case edit(DepositOffer)

    var id: String {
      switch self {
      case .new: "new"
      case .edit(let offer): offer.id.uuidString
      }
    }
  }

  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  let target: Target
  @State private var bank = ""
  @State private var rateText = ""
  @State private var termText = ""
  @State private var minimum: AmountE4 = .zero
  @State private var maximum: AmountE4 = .zero
  @State private var newClient = false
  @State private var subscription = false
  @State private var topup = false
  @State private var rateDay = Date()
  @State private var note = ""
  @State private var loaded = false

  private func t(_ key: String) -> String { DepositText.t(key, environment) }

  /// The rate as typed: a positive decimal, a comma or a point for the fraction.
  static func rate(_ text: String) -> Decimal? {
    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
      value > 0, value < 1000
    else { return nil }
    return value
  }

  private var valid: Bool {
    !bank.trimmingCharacters(in: .whitespaces).isEmpty && Self.rate(rateText) != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(isNew ? "dep.form.new" : "dep.form.edit")).appFont(.headline)
      Form {
        TextField(t("dep.form.bank"), text: $bank)
        TextField(t("dep.form.rate"), text: $rateText, prompt: Text(verbatim: "15.5"))
        TextField(t("dep.form.term"), text: $termText)
        LabeledContent(t("dep.form.min")) {
          AmountField(amount: $minimum, locale: environment.language.locale).frame(maxWidth: 160)
        }
        LabeledContent(t("dep.form.max")) {
          AmountField(amount: $maximum, locale: environment.language.locale).frame(maxWidth: 160)
        }
        Toggle(t("dep.form.newClient"), isOn: $newClient)
        Toggle(t("dep.form.subscription"), isOn: $subscription)
        Toggle(t("dep.form.topup"), isOn: $topup)
        DatePicker(t("dep.form.rateOn"), selection: $rateDay, displayedComponents: .date)
        TextField(t("dep.form.note"), text: $note)
      }
      .formStyle(.grouped)
      if !rateText.isEmpty, Self.rate(rateText) == nil {
        Text(verbatim: t("dep.form.rateInvalid")).appFont(.callout).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save")) {
          if save() { dismiss() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!valid)
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 560)
    .onAppear(perform: load)
  }

  private var isNew: Bool {
    if case .new = target { return true }
    return false
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    rateDay = environment.calendar.startOfDay(environment.today)
    guard case .edit(let offer) = target else { return }
    bank = offer.bankName
    rateText = "\(offer.ratePercent)"
    termText = offer.termMonths.map(String.init) ?? ""
    minimum = offer.minAmountE4 ?? .zero
    maximum = offer.maxAmountE4 ?? .zero
    newClient = offer.newClientOnly
    subscription = offer.needsSubscription
    topup = offer.topup
    rateDay = environment.calendar.startOfDay(offer.rateOn)
    note = offer.note ?? ""
  }

  private func save() -> Bool {
    guard valid, let rate = Self.rate(rateText) else { return false }
    var offer: DepositOffer
    if case .edit(let existing) = target {
      offer = existing
    } else {
      offer = DepositOffer(bankName: "", ratePercent: rate, rateOn: environment.today)
    }
    offer.bankName = bank.trimmingCharacters(in: .whitespaces)
    offer.ratePercent = rate
    offer.termMonths = Int(termText.trimmingCharacters(in: .whitespaces)).flatMap {
      $0 > 0 ? $0 : nil
    }
    offer.minAmountE4 = minimum.raw > 0 ? minimum : nil
    offer.maxAmountE4 = maximum.raw > 0 ? maximum : nil
    offer.newClientOnly = newClient
    offer.needsSubscription = subscription
    offer.topup = topup
    offer.rateOn = environment.calendar.day(of: rateDay)
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    offer.note = trimmed.isEmpty ? nil : trimmed
    do {
      try environment.depositOffers?.save(offer)
      return true
    } catch {
      return false
    }
  }
}
