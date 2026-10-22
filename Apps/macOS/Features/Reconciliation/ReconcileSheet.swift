import AppCore
import SwiftUI

/// «Сверка»: how much money is on every account, in each of its currencies, against what the
/// books expect. Every live account × each of its currencies is one row, the expected balance
/// already in its field: the owner fixes only the rows that differ, and zero is a count like
/// any other — and so is a balance below zero, a credit card's. Each row's difference is in its
/// own currency — a rate that moved is never a difference. The first count of a balance is its
/// starting point: nothing is compared and nothing is written but the count. A pair that rested
/// only on the zero openings older versions wrote for empty fields is one too, by default,
/// whatever the books expect: its row says «Точка отсчёта», with what either choice writes.
///
/// «Записать разницу» writes every difference as an operation in «Сверка» on its account, in
/// its currency, and the operation follows the books from then on; «Сохранить без записи»
/// keeps only the counts. With nothing different, one «Сохранить». Each is one write and one
/// step of ⌘Z. The groups left out of the summary are counted too — their money is real — and
/// their rows say they are apart. The history lists what each reconciliation found and offers
/// to make a first count older versions recorded as a difference the starting point it was.
struct ReconcileSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces

  /// What the owner typed, by balance: a row he never touched counts its expected balance, and
  /// a starting point he never touched counts nothing.
  @State private var typed: [BalanceKey: AmountE4] = [:]
  /// Fields the owner emptied: a starting point left empty is not counted.
  @State private var blank: Set<BalanceKey> = []
  /// Rows offering «Точка отсчёта» the owner unticked: they compare like any row.
  @State private var unticked: Set<BalanceKey> = []
  /// The moment the expected balances are counted for, and the reconciliation is stamped with.
  @State private var now = Date()
  @State private var showsHistory = false
  /// The answers «до сверки?» remembered by reconciliation, read when the history opens and
  /// after «Забыть».
  @State private var answers: [UUID: Bool] = [:]
  /// The key of why the last press saved nothing, until the next one: the sheet is never left
  /// open without a word.
  @State private var failure: String?

  var body: some View {
    let snapshot = compute.snapshot
    let rows =
      snapshot.map {
        Self.rows(
          of: $0, at: now, first: environment.focusedAccountId,
          locale: environment.language.locale)
      } ?? []
    let offered = snapshot.map { Self.startingPointKeys(rows, snapshot: $0) } ?? []
    let draft = Self.draft(
      rows: rows, offered: offered, unticked: unticked, typed: typed, blank: blank)
    let startingPoints = draft.startingPoints
    let compared = draft.rows
    let counted = draft.counted
    let saved = Dictionary(compared.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    let differs = Self.differs(rows: compared, counted: counted)
    let noRate = Self.differencesWithoutRate(
      rows: compared, counted: counted, rubPerUnit: snapshot?.context.rubPerUnit ?? [:])
    let notHeld = Self.differencesNotHeld(rows: compared, counted: counted)
    VStack(alignment: .leading, spacing: 12) {
      // The title with its question under it, set off from the table by a rule.
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: t("reconcile.title")).appFont(.title3).bold()
        Text(verbatim: t("reconcile.accountsQuestion"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      if let snapshot {
        if rows.isEmpty {
          Text(verbatim: t("reconcile.noAccounts")).foregroundStyle(.secondary)
        } else {
          ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
              columnCaptions
              ForEach(rows, id: \.key) { row in
                rowView(
                  row, snapshot: snapshot, counted: counted, compared: saved[row.key] ?? row)
                if offered.contains(row.key) {
                  GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    firstCountToggle(
                      row, name: accountName(row.key.accountId, snapshot),
                      counted: counted[row.key]
                    )
                    .gridCellColumns(4)
                  }
                }
              }
            }
            .padding(12)
            .background(surfaces.card, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(surfaces.cardBorder))
            .padding(.vertical, 2)
          }
          .frame(maxHeight: 340)
          if !offered.isEmpty {
            notice("reconcile.firstCountToggleHint", symbol: "info.circle")
          }
        }
      } else {
        // Without the data the sheet cannot tell a starting point from a count to compare:
        // nothing is saved until it is here.
        ComputedBlock(
          title: nil, state: compute.states.data, style: .plain,
          retry: { compute.retry(ComputeStep.data) }
        ) { _ in EmptyView() }
      }
      if !noRate.isEmpty {
        notice(
          environment.format(
            "reconcile.noRateForDifference", table: "Planning",
            noRate.map(\.code).joined(separator: ", ")),
          symbol: "exclamationmark.triangle", translated: true)
      }
      if !notHeld.isEmpty, let snapshot {
        notice(
          environment.format(
            "reconcile.notHeldDifference", table: "Planning",
            notHeld.map { "\(accountName($0.key.accountId, snapshot)) \($0.key.currency.code)" }
              .joined(separator: ", ")),
          symbol: "exclamationmark.triangle", translated: true)
      }
      DisclosureGroup(isExpanded: $showsHistory) {
        history(snapshot)
          .onAppear { answers = environment.rememberedCountAnswers() }
      } label: {
        Text(verbatim: t("reconcile.history"))
      }
      if let failure {
        Label {
          Text(verbatim: t(failure)).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.octagon")
        }
        .appFont(.caption)
        .foregroundStyle(.red)
      }
      Divider()
      HStack {
        if let last = snapshot?.planning.lastReconciliation {
          Button(t("reconcile.findMissing")) {
            Self.findMissing(
              since: last.date, today: environment.today,
              typing: ReconcileTyping(typed: typed, blank: blank, unticked: unticked),
              in: environment)
            dismiss()
            OperationsScreenOpening.open(with: openWindow)
          }
        }
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        let savable = snapshot != nil && !counted.isEmpty
        let save = { (record: Bool) in
          self.save(
            counted, rows, record: record, startingPoints: startingPoints, keeping: draft.keeping)
        }
        switch Self.buttons(rows: compared, counted: counted) {
        case .startingPoint:
          Button(t("reconcile.saveStart")) { save(false) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!savable)
        case .save:
          // Nothing differs: nothing to decline, and the counts follow the books from now on.
          Button(t("reconcile.save")) { save(true) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!savable)
        case .saveOrRecord:
          Button(t("reconcile.saveOnly")) { save(false) }
            .disabled(!savable)
            .help(t("reconcile.saveOnlyHint"))
          Button(t("reconcile.record")) { save(true) }
            .disabled(!savable || !differs || !noRate.isEmpty || !notHeld.isEmpty)
            .help(t("reconcile.recordHint"))
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .sheetFrame(width: 620)
    .onAppear {
      now = Date()
      // Back from «Найти пропущенные…»: what was typed before is here again.
      if let kept = ReconcileDraftKeeper.shared.take() {
        typed = kept.typed
        blank = kept.blank
        unticked = kept.unticked
      }
      // The card of Overview asked for the first counts to decide on: they are in the history.
      if ReconcileHistoryRequest.shared.isRequested {
        ReconcileHistoryRequest.shared.isRequested = false
        showsHistory = true
      }
    }
    // An operation entered while the sheet stands open — the coffee «Найти пропущенные…» went
    // looking for — comes with new data, and the moment moves with it: the expected balances
    // take it in, the untouched fields follow them, and what the owner typed stays.
    .onChange(of: compute.generation) { _, _ in now = Date() }
  }

  // MARK: Rows

  /// One row; `compared` is the row as it is saved — without an expected balance while it is
  /// a starting point.
  @ViewBuilder
  private func rowView(
    _ row: ReconcileRow, snapshot: DataSnapshot, counted: [BalanceKey: AmountE4],
    compared: ReconcileRow
  ) -> some View {
    let currency = row.key.currency
    let name = accountName(row.key.accountId, snapshot)
    GridRow(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: name).lineLimit(1)
        if !row.isInSummary {
          Label {
            Text(verbatim: t("reconcile.notInSummary"))
          } icon: {
            Image(systemName: "eye.slash")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
        if let note = Self.note(for: row, accounts: snapshot.dataset.paymentMethods) {
          Text(verbatim: t(note))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(minWidth: 150, alignment: .leading)
      Text(verbatim: currency.code)
        .monospacedDigit()
        .foregroundStyle(.secondary)
      if let expected = row.expected {
        Text(verbatim: environment.money.exact(expected, currency: currency))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .help(t("reconcile.expectedHint"))
      } else {
        Label {
          Text(verbatim: t("reconcile.startingPoint"))
        } icon: {
          Image(systemName: "flag")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .help(t("reconcile.first"))
      }
      // The field shows what is saved: nothing on a starting point nobody typed in.
      AmountField(
        amount: Binding(
          get: { Self.shown(compared, typed: typed) },
          set: { typed[row.key] = $0 }),
        onTyped: { amount, text in
          Self.typing(amount, text: text, row: compared, typed: &typed, blank: &blank)
        }
      )
      .frame(width: 130)
      .accessibilityLabel(Text(verbatim: "\(name) \(currency.code)"))
      // A row that differs stands out by its sign and weight; a matching one stays quiet.
      let differs = Self.differs(rows: [compared], counted: counted)
      Text(verbatim: differenceText(compared, counted: counted))
        .monospacedDigit()
        .fontWeight(differs ? .semibold : .regular)
        .foregroundStyle(differs ? .primary : .secondary)
        .frame(minWidth: 100, alignment: .trailing)
        // Read on its own, the figure says whose difference it is.
        .accessibilityLabel(
          Text(verbatim: "\(t("reconcile.difference")) \(name) \(currency.code)")
        )
        .accessibilityValue(Text(verbatim: differenceText(compared, counted: counted)))
    }
  }

  /// «Точка отсчёта» of a pair that rested only on zero openings: on by default, and under it
  /// what either choice writes, in exact money.
  private func firstCountToggle(
    _ row: ReconcileRow, name: String, counted: AmountE4?
  ) -> some View {
    let currency = row.key.currency
    let outcome = Self.firstCountOutcome(row, counted: counted)
    return VStack(alignment: .leading, spacing: 2) {
      Toggle(
        isOn: Binding(
          get: { !unticked.contains(row.key) },
          set: { isOn in
            if isOn { unticked.remove(row.key) } else { unticked.insert(row.key) }
          })
      ) {
        Text(verbatim: t("reconcile.firstCountToggle"))
      }
      .toggleStyle(.checkbox)
      .help(t("reconcile.firstCountToggleHint"))
      .accessibilityLabel(
        Text(
          verbatim: Self.spoken(
            t("reconcile.firstCountToggle"), account: name, currency: currency)))
      Group {
        if let balance = outcome.balance {
          Text(
            verbatim: environment.format(
              "reconcile.firstCountToggle.on", table: "Planning",
              environment.money.exact(balance, currency: currency)))
        }
        if let difference = outcome.difference, !difference.isZero {
          Text(
            verbatim: environment.format(
              difference.isNegative
                ? "reconcile.firstCountToggle.offExpense" : "reconcile.firstCountToggle.offIncome",
              table: "Planning", environment.money.exact(difference.magnitude, currency: currency)))
        }
      }
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// «−500.00 ₽», «+10.00 $», «0 ₽» — in the row's currency; «—» for a starting point or a row
  /// not counted.
  private func differenceText(_ row: ReconcileRow, counted: [BalanceKey: AmountE4]) -> String {
    guard let expected = row.expected, let actual = counted[row.key] else { return "—" }
    return Self.signed(actual - expected, currency: row.key.currency, money: environment.money)
  }

  private func accountName(_ id: UUID, _ snapshot: DataSnapshot) -> String {
    Self.accountName(
      id, accounts: snapshot.dataset.paymentMethods, banks: snapshot.dataset.banks)
  }

  /// The account of a row as every list of accounts names it (`AccountLabels`): the bank alone
  /// when it has one live account, «Банк › Счёт» when it has several; «—» for one not there.
  static func accountName(_ id: UUID, accounts: [PaymentMethod], banks: [Bank]) -> String {
    AccountLabels(accounts: accounts, cards: [], banks: banks).label(account: id) ?? "—"
  }

  private func notice(_ text: String, symbol: String, translated: Bool = false) -> some View {
    Label {
      Text(verbatim: translated ? text : t(text)).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbol)
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(theme.palette.accentTint), in: .rect(cornerRadius: 10))
  }

  /// The captions over the columns of the table, as the design draws them.
  private var columnCaptions: some View {
    GridRow {
      Text(verbatim: t("reconcile.col.account"))
      Color.clear.frame(width: 1, height: 1)
      Text(verbatim: t("reconcile.col.expected"))
      Text(verbatim: t("reconcile.col.counted"))
      Text(verbatim: t("reconcile.difference")).frame(minWidth: 100, alignment: .trailing)
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }

  // MARK: The rules of the sheet

  /// The rows of the sheet at `t0` (`AccountReconciliation.rows`), those of `first` — the
  /// account whose screen asked for the sheet — on top.
  static func rows(
    of snapshot: DataSnapshot, at t0: Date, first: UUID?, locale: Locale
  ) -> [ReconcileRow] {
    let rows = AccountReconciliation.rows(
      accounts: snapshot.dataset.paymentMethods, groups: snapshot.dataset.accountGroups,
      balances: snapshot.planning.accounts.balances, at: t0, locale: locale)
    guard let first else { return rows }
    return rows.filter { $0.key.accountId == first } + rows.filter { $0.key.accountId != first }
  }

  /// The pairs whose new count is their starting point by default: they rested only on the
  /// zero openings older versions wrote for empty fields (`FirstCountFix.startingPointKeys`).
  static func startingPointKeys(_ rows: [ReconcileRow], snapshot: DataSnapshot) -> Set<BalanceKey> {
    FirstCountFix.startingPointKeys(
      rows, balances: snapshot.planning.accounts.balances,
      reconciliations: snapshot.dataset.planning.reconciliations)
  }

  /// The rows as the sheet saves them: a starting point compares nothing, whatever the books
  /// expected for it.
  static func compared(_ rows: [ReconcileRow], startingPoints: Set<BalanceKey>) -> [ReconcileRow] {
    guard !startingPoints.isEmpty else { return rows }
    return rows.map { row in
      guard startingPoints.contains(row.key) else { return row }
      var start = row
      start.expected = nil
      return start
    }
  }

  /// The sheet as it is saved, from what the owner did in it.
  struct Draft {
    /// The rows as saved: a starting point compares nothing.
    var rows: [ReconcileRow]
    /// The offered pairs left ticked: their counts are starting points.
    var startingPoints: Set<BalanceKey>
    /// The offered pairs unticked: compared like any row, and their counts remembered as a real
    /// difference.
    var keeping: Set<BalanceKey>
    /// What is counted, by balance.
    var counted: [BalanceKey: AmountE4]
  }

  /// The sheet of `rows` as it is saved: `offered` — the pairs «Точка отсчёта» is offered for —
  /// less the `unticked` ones are starting points, and the counts are read from the rows as
  /// saved (`counted(rows:typed:blank:)`). A ticked row is thus a pair nobody counted yet: it
  /// is counted only once the owner types a balance and leaves it there. Taken at what the
  /// books expect — the zero older versions wrote for an empty field, and what moved since —
  /// it would be saved as a starting point nobody counted, and the owner's first real count
  /// would be compared with it, the whole balance a «Сверка» difference.
  static func draft(
    rows: [ReconcileRow], offered: Set<BalanceKey>, unticked: Set<BalanceKey>,
    typed: [BalanceKey: AmountE4], blank: Set<BalanceKey>
  ) -> Draft {
    let startingPoints = offered.subtracting(unticked)
    let saved = compared(rows, startingPoints: startingPoints)
    return Draft(
      rows: saved, startingPoints: startingPoints, keeping: offered.subtracting(startingPoints),
      counted: counted(rows: saved, typed: typed, blank: blank))
  }

  /// What the field of `row` — as saved — shows: what the owner typed, else the expected
  /// balance, else nothing.
  static func shown(_ row: ReconcileRow, typed: [BalanceKey: AmountE4]) -> AmountE4 {
    typed[row.key] ?? row.expected ?? .zero
  }

  /// What VoiceOver reads for a control of one balance: its words and whose balance it is.
  static func spoken(_ title: String, account: String?, currency: CurrencyCode?) -> String {
    ([title] + [account, currency?.code].compactMap { $0 }).joined(separator: " ")
  }

  /// The buttons of the sheet.
  enum Buttons: Equatable {
    /// Nothing is compared: «Сохранить как точку отсчёта».
    case startingPoint
    /// Rows are compared and none differs: one «Сохранить», which keeps them following the
    /// books.
    case save
    /// A row differs: «Сохранить без записи» and «Записать разницу», the default.
    case saveOrRecord
  }

  /// Which buttons `rows` — as saved — call for with `counted`.
  static func buttons(rows: [ReconcileRow], counted: [BalanceKey: AmountE4]) -> Buttons {
    guard rows.contains(where: { $0.expected != nil }) else { return .startingPoint }
    return differs(rows: rows, counted: counted) ? .saveOrRecord : .save
  }

  /// What «Точка отсчёта» of `row` says: the balance it starts from, and the difference the
  /// count would record unticked — `nil` while nothing is counted.
  static func firstCountOutcome(
    _ row: ReconcileRow, counted: AmountE4?
  ) -> (balance: AmountE4?, difference: AmountE4?) {
    guard let counted else { return (nil, nil) }
    return (counted, row.expected.map { counted - $0 })
  }

  /// What the sheet counts of `rows` — as saved —, by balance: what the owner typed, else the
  /// expected balance he left as it is. A starting point is counted only as typed, and not
  /// once its field is emptied. A balance below zero is
  /// counted like any other: a credit card holds what is owed.
  static func counted(
    rows: [ReconcileRow], typed: [BalanceKey: AmountE4], blank: Set<BalanceKey>
  ) -> [BalanceKey: AmountE4] {
    var counted: [BalanceKey: AmountE4] = [:]
    for row in rows {
      if let value = typed[row.key] {
        if row.expected == nil, blank.contains(row.key) { continue }
        counted[row.key] = value
      } else if let expected = row.expected {
        counted[row.key] = expected
      }
    }
    return counted
  }

  /// What one field tells the sheet: the amount typed, with the text behind it; `row` is the
  /// row as saved, whose amount the field shows.
  ///
  /// The field writes the amount it is given into itself — the expected balance when the sheet
  /// opens, a new one when new data comes, nothing on a starting point — and tells that text
  /// like any other. It is not the
  /// owner counting: taken for a count, it would pin an untouched row to the expectation of the
  /// moment the field appeared, and the coffee «Найти пропущенные…» went looking for would
  /// show up as a difference nobody typed. So a row nobody typed in yet takes no text that is
  /// just what it shows by itself.
  static func typing(
    _ amount: AmountE4, text: String, row: ReconcileRow,
    typed: inout [BalanceKey: AmountE4], blank: inout Set<BalanceKey>
  ) {
    if typed[row.key] == nil, text == AmountField.text(for: row.expected ?? .zero) { return }
    typed[row.key] = amount
    if text.trimmingCharacters(in: .whitespaces).isEmpty {
      blank.insert(row.key)
    } else {
      blank.remove(row.key)
    }
  }

  /// Why a row is not an ordinary one, as a key of the Planning table: an archived account
  /// still holding money, or money in a currency the account does not list. Nil for the rest.
  static func note(for row: ReconcileRow, accounts: [PaymentMethod]) -> String? {
    guard !row.isHeld else { return nil }
    let account = accounts.first { $0.id == row.key.accountId }
    return account.map { !$0.archived } == true ? "reconcile.notHeld" : "reconcile.archived"
  }

  /// Rows that differ where no operation can be written: an archived account, or a currency
  /// the account does not hold — an operation there has no account to be taken from. Their
  /// difference is not recorded; «Сохранить без записи» still keeps the count.
  static func differencesNotHeld(
    rows: [ReconcileRow], counted: [BalanceKey: AmountE4]
  ) -> [ReconcileRow] {
    rows.filter { row in
      guard !row.isHeld, let expected = row.expected, let actual = counted[row.key] else {
        return false
      }
      return actual != expected
    }
  }

  /// Some compared row counts another amount than expected.
  static func differs(rows: [ReconcileRow], counted: [BalanceKey: AmountE4]) -> Bool {
    rows.contains { row in
      guard let expected = row.expected, let actual = counted[row.key] else { return false }
      return actual != expected
    }
  }

  /// Currencies of rows with a difference that has no rate today: that difference cannot be
  /// written in rubles, so «Записать разницу» waits for the rate.
  static func differencesWithoutRate(
    rows: [ReconcileRow], counted: [BalanceKey: AmountE4], rubPerUnit: [CurrencyCode: Decimal]
  ) -> [CurrencyCode] {
    var missing: Set<CurrencyCode> = []
    for row in rows where row.key.currency != .rub && rubPerUnit[row.key.currency] == nil {
      guard let expected = row.expected, let actual = counted[row.key], actual != expected
      else { continue }
      missing.insert(row.key.currency)
    }
    return missing.sorted { $0.code < $1.code }
  }

  /// A difference with its sign. Exact in the sheet: a reconciliation shows kopecks, and the
  /// operation it writes has them too. `rounded` — whole units — where amounts are shown to
  /// the ruble, as on the Overview card.
  static func signed(
    _ amount: AmountE4, currency: CurrencyCode, money: MoneyFormatter, rounded: Bool = false
  ) -> String {
    guard !rounded else { return money.signedRounded(amount, currency: currency) }
    return (amount.isNegative ? "−" : amount.isZero ? "" : "+")
      + money.exact(amount.magnitude, currency: currency)
  }

  // MARK: History

  private func history(_ snapshot: DataSnapshot?) -> some View {
    let book = snapshot?.dataset.planning
    let all = Array((book?.reconciliations ?? []).reversed())
    // Every first count older versions recorded as a difference — kept ones too: this is the
    // place to change one's mind.
    let candidates = snapshot.map { Self.candidates(in: $0, kept: []) } ?? []
    let recordable = snapshot.map(Self.recordable(in:)) ?? []
    return VStack(alignment: .leading, spacing: 4) {
      if all.isEmpty { Text(verbatim: t("reconcile.historyNone")).foregroundStyle(.secondary) }
      ForEach(all, id: \.id) { item in
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: environment.dates.longDay(item.date))
          Text(verbatim: t(Self.kindKey(item)))
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Text(verbatim: summary(of: item, snapshot))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
        .appFont(.caption)
        ForEach(Self.candidates(candidates, of: item), id: \.id) { candidate in
          fixButton(candidate, snapshot: snapshot)
        }
        ForEach(recordable.filter { $0.reconciliationId == item.id }, id: \.id) { count in
          recordButton(count, snapshot: snapshot)
        }
        if let wasBefore = answers[item.id] {
          answerLine(wasBefore, reconciliation: item.id)
        }
      }
    }
  }

  /// «Это первая сверка — сделать точкой отсчёта» under the reconciliation it is about, the
  /// account named when the sheet counted several.
  private func fixButton(_ candidate: FirstCountCandidate, snapshot: DataSnapshot?) -> some View {
    let name = candidate.key.flatMap { key in snapshot.map { accountName(key.accountId, $0) } }
    return HStack {
      Spacer(minLength: 8)
      if let name {
        Text(verbatim: name)
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      // Content, not a floating control: a plain small button, never glass.
      Button(t("reconcile.firstCount.fix")) {
        guard let dependencies else { return }
        PlanningActions(dependencies).fixFirstCount(candidate)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      // A base of older versions has several such buttons: each says whose count it fixes.
      .accessibilityLabel(
        Text(
          verbatim: Self.spoken(
            t("reconcile.firstCount.fix"), account: name, currency: candidate.key?.currency)))
    }
  }

  /// «Записывать разницу» under a count that keeps only its numbers, the account named.
  private func recordButton(_ count: ReconciledBalance, snapshot: DataSnapshot?) -> some View {
    let name = snapshot.map { accountName(count.accountId, $0) }
    return HStack {
      Spacer(minLength: 8)
      if let name {
        Text(verbatim: name)
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      // Content, not a floating control: a plain small button, never glass.
      Button(t("reconcile.recordAgain")) {
        guard let dependencies else { return }
        PlanningActions(dependencies).recordDifference(of: count)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityLabel(
        Text(
          verbatim: Self.spoken(t("reconcile.recordAgain"), account: name, currency: count.currency)
        ))
    }
  }

  /// «Операции этого дня: до сверки · Забыть» under a count whose question is answered for good.
  private func answerLine(_ wasBefore: Bool, reconciliation: UUID) -> some View {
    HStack {
      Spacer(minLength: 8)
      Text(verbatim: Self.answerText(wasBefore, environment.language))
        .appFont(.caption)
        .foregroundStyle(.secondary)
      Button(t("reconcile.answer.forget")) {
        environment.forgetCountAnswer(reconciliation: reconciliation)
        answers = environment.rememberedCountAnswers()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  /// The words of a remembered answer: where the operations of the count's day go.
  static func answerText(_ wasBefore: Bool, _ language: AppLanguage) -> String {
    language(wasBefore ? "reconcile.answer.before" : "reconcile.answer.after", table: "Planning")
  }

  /// The live counts of `snapshot` that keep only their numbers and found a difference: each
  /// can record it again («Записывать разницу»). A first count still to decide on is not one.
  static func recordable(in snapshot: DataSnapshot) -> [ReconciledBalance] {
    let book = snapshot.dataset.planning
    let frozen = ZeroOpenings.frozenCounts(
      balances: snapshot.planning.accounts.balances, reconciliations: book.reconciliations,
      kept: book.settings.firstCountKept)
    let live = LiveCounts.liveIds(
      reconciliations: book.reconciliations, balances: book.reconciledBalances, frozen: frozen)
    return book.reconciledBalances.filter {
      live.contains($0.id) && $0.recordsDifference == false
        && !($0.differenceE4 ?? .zero).isZero
    }
  }

  /// The first counts of `snapshot` recorded as a difference against zero openings or zero
  /// totals, newest first, less `kept` (`FirstCountFix.candidates`).
  static func candidates(in snapshot: DataSnapshot, kept: Set<UUID>) -> [FirstCountCandidate] {
    FirstCountFix.candidates(
      book: snapshot.dataset.planning, balances: snapshot.planning.accounts.balances,
      liveOperations: Set(snapshot.dataset.entries.map(\.id)), kept: kept)
  }

  /// The candidates among `all` that belong to the reconciliation `item`.
  static func candidates(
    _ all: [FirstCountCandidate], of item: Reconciliation
  ) -> [FirstCountCandidate] {
    all.filter { candidate in
      switch candidate {
      case .count(let balance, _, _, _): balance.reconciliationId == item.id
      case .total(let reconciliation, _): reconciliation.id == item.id
      }
    }
  }

  /// The words of a reconciliation's kind in the history: starting balances say where they came
  /// from — the setup, a new account, a merge — when that is known.
  static func kindKey(_ reconciliation: Reconciliation) -> String {
    if reconciliation.kind == .opening, let origin = reconciliation.origin {
      return "reconcile.kind.\(origin.rawValue)"
    }
    return "reconcile.kind.\(reconciliation.kind.rawValue)"
  }

  /// What one reconciliation found, as it found it: the differences of its balances, each in
  /// its currency; a reconciliation of one total gives its difference in rubles.
  private func summary(of item: Reconciliation, _ snapshot: DataSnapshot?) -> String {
    guard item.kind != .total else {
      return item.differenceE4.map { Self.signed($0, currency: .rub, money: environment.money) }
        ?? t("reconcile.startingPoint")
    }
    let balances = (snapshot?.dataset.planning.reconciledBalances ?? [])
      .filter { $0.reconciliationId == item.id }
    return Self.differencesText(
      balances, names: { id in snapshot.map { accountName(id, $0) } ?? "—" },
      money: environment.money, language: environment.language, marksNotRecorded: true)
  }

  /// What the balances of one reconciliation found.
  enum Findings: Equatable {
    /// Nothing was compared: every balance was counted for the first time.
    case startingPoint
    /// Every compared balance was what the books expected.
    case noDifference
    /// The balances that differed, with their differences.
    case differences([ReconciledBalance])
  }

  static func findings(_ balances: [ReconciledBalance]) -> Findings {
    let compared = balances.filter { !$0.isStartingPoint }
    guard !compared.isEmpty else { return .startingPoint }
    let differing = compared.filter { !($0.differenceE4 ?? .zero).isZero }
    return differing.isEmpty ? .noDifference : .differences(differing)
  }

  /// «Т-Банк −500.00 ₽ · Freedom +10.00 $», each difference in its currency — «−500 ₽»
  /// with `rounded`; «без расхождений» when every compared balance matched, «точка отсчёта»
  /// when nothing was compared. With `marksNotRecorded`, a difference saved without recording
  /// says so: «−500.00 ₽ не записана».
  static func differencesText(
    _ balances: [ReconciledBalance], names: (UUID) -> String, money: MoneyFormatter,
    language: AppLanguage, rounded: Bool = false, marksNotRecorded: Bool = false
  ) -> String {
    switch findings(balances) {
    case .startingPoint: language("reconcile.startingPoint", table: "Planning")
    case .noDifference: language("reconcile.noDifference", table: "Planning")
    case .differences(let differing):
      differing.map {
        "\(names($0.accountId)) "
          + signed(
            $0.differenceE4 ?? .zero, currency: $0.currency, money: money, rounded: rounded)
          + (marksNotRecorded && $0.recordsDifference == false
            ? " " + language("reconcile.notRecordedMark", table: "Planning") : "")
      }.joined(separator: " · ")
    }
  }

  // MARK: Saving

  private func save(
    _ counted: [BalanceKey: AmountE4], _ rows: [ReconcileRow], record: Bool,
    startingPoints: Set<BalanceKey>, keeping: Set<BalanceKey>
  ) {
    guard let dependencies else { return }
    if let failure = Self.save(
      counted: counted, rows: rows, record: record, at: now, dependencies: dependencies,
      startingPoints: startingPoints, keeping: keeping)
    {
      self.failure = failure
      return
    }
    environment.showsReconciliation = false
    dismiss()
  }

  /// «Найти пропущенные…»: «Операции» shows the days from the last reconciliation to today,
  /// and the sheet closes — standing over the main window it would hide the table. What the
  /// owner typed is kept, and the sheet opened again starts from it; an untouched sheet keeps
  /// nothing.
  static func findMissing(
    since last: DateOnly, today: DateOnly, typing: ReconcileTyping, in environment: AppEnvironment
  ) {
    environment.pendingTransactionsRange = DayRange(last, today)
    if !typing.isEmpty { ReconcileDraftKeeper.shared.keep(typing) }
    environment.showsReconciliation = false
  }

  /// Writes the reconciliation: nil when it landed, or the key of what the sheet says when it
  /// did not. A refused save keeps the sheet open with the money counted in it — and says so,
  /// rather than leave a button that seems to do nothing (the journal has `reconcile.failed`).
  static func save(
    counted: [BalanceKey: AmountE4], rows: [ReconcileRow], record: Bool, at t0: Date,
    dependencies: AppDependencies, startingPoints: Set<BalanceKey> = [],
    keeping: Set<BalanceKey> = []
  ) -> String? {
    PlanningActions(dependencies).reconcile(
      counted: counted, rows: rows, recordDifference: record, at: t0,
      startingPoints: startingPoints, keepingFirstCounts: keeping)?.rawValue
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// «и ещё N» on the card of Overview: the sheet opens with its history, where every first count
/// to decide on has its button.
@MainActor @Observable
final class ReconcileHistoryRequest {
  static let shared = ReconcileHistoryRequest()

  var isRequested = false
}

/// What the owner typed into the reconciliation sheet: the amounts by balance, the fields he
/// emptied and the starting points he unticked.
struct ReconcileTyping: Equatable {
  var typed: [BalanceKey: AmountE4]
  var blank: Set<BalanceKey>
  var unticked: Set<BalanceKey>

  var isEmpty: Bool { typed.isEmpty && blank.isEmpty && unticked.isEmpty }
}

/// The typing of a sheet «Найти пропущенные…» closed, until the sheet opens again and takes it:
/// the counts the owner made are not lost while he looks through the operations.
@MainActor
final class ReconcileDraftKeeper {
  static let shared = ReconcileDraftKeeper()

  private var kept: ReconcileTyping?

  func keep(_ typing: ReconcileTyping) { kept = typing }

  /// The kept typing, once: the sheet after that starts from the books.
  func take() -> ReconcileTyping? {
    defer { kept = nil }
    return kept
  }
}
