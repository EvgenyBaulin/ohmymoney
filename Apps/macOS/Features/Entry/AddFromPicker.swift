import AppCore
import AppDatabase
import SwiftUI

/// «Add…», the last item of every menu of the ↓ panel that lists a dictionary: the category
/// and the subcategory, the person «для кого», the place, the event, the payment method and
/// the debtor of a part paid for someone. Choosing it chooses nothing — the menu keeps what it
/// showed — and opens a sheet that makes a record of its kind; saved there, the record is
/// chosen in the menu it was asked for from.
///
/// Menus of fixed values — the type, the quality, «для кого» itself, the currency, the month
/// of an income — have nothing to add to. A goal and a debt are not added here either: each
/// needs more than a name, and Planning and Debts ask for it.
enum AddFromPicker {
  /// The tag of the item in the menu. No record has it: a random identifier is never of
  /// version 0.
  static let tag = UUID(uuidString: "00000000-0000-0000-0000-00000000ADD0")!

  /// What the sheet makes, and where in the draft the new record goes.
  enum Kind: Hashable, Identifiable {
    /// A top-level category of the kind of the operation, for the part at this index.
    case category(part: Int)
    /// A subcategory of the category that part has.
    case subcategory(part: Int)
    /// The person «для кого» of the part.
    case person(part: Int)
    /// Who gives back a part paid for someone.
    case debtor(part: Int)
    /// A person of «За кого»: the one paid for, or one more of «Поровну».
    case payingFor(slot: Int)
    case place
    case event(part: Int)
    case paymentMethod

    var id: Self { self }
  }

  /// The choice of a menu with «Add…» at its end: that item calls `adding` and leaves the
  /// choice as it was; every other item is chosen as it always is.
  @MainActor
  static func selection(
    _ choice: Binding<UUID?>, adding: @escaping @MainActor () -> Void
  ) -> Binding<UUID?> {
    Binding(
      get: { choice.wrappedValue },
      set: { value in
        if value == tag {
          adding()
        } else {
          choice.wrappedValue = value
        }
      })
  }
}

/// What the sheet of «Add…» asks for, and what «Save» does with it.
@MainActor
struct NewRecordForm {
  /// What «Save» needs besides the panel, when the app has it: the dictionaries with their
  /// archives, the currency of everything new, and «Вернуть» of an account by the rules of the
  /// accounts. Without it — the panel on its own, as its tests make it — a record is written
  /// the way the panel writes one.
  struct Context {
    var references: ReferenceRepository?
    var defaultCurrency: CurrencyCode = .rub
    /// Brings an archived account back, and says what came of it.
    var restoreAccount: (@MainActor (UUID) -> AccountActionOutcome)?

    /// The context of the app's window. An account comes back by the rules of the accounts —
    /// one step of ⌘Z, as in Settings → Счета — with its currencies switched on: every
    /// currency a live account holds is on, so the entry line knows it and the bank's table is
    /// checked for it. When that would make more than ten, the account stays in the archive.
    @MainActor
    static func app(_ environment: AppEnvironment, store: TransactionsStore) -> Context {
      Context(
        references: environment.references, defaultCurrency: environment.defaultCurrency,
        restoreAccount: { id in
          NewRecordForm.restoreAccount(id, environment: environment, store: store)
        })
    }
  }

  /// Why «Save» wrote nothing.
  enum Failure: Error, Equatable {
    /// Said by the words of table «Entry» under this key.
    case key(String)
    /// The archive holds the account of this name, and it cannot come back.
    case accountNotBack(String, AccountRefusal)

    /// The words under the fields.
    @MainActor
    func text(_ environment: AppEnvironment) -> String {
      switch self {
      case .key(let key):
        environment.language(key, table: "Entry")
      case .accountNotBack(let name, let refusal):
        environment.format(
          "entry.add.accountNotBack", table: "Entry", name,
          AccountText.message(refusal, environment))
      }
    }
  }

  let kind: AddFromPicker.Kind
  /// As typed; saved without the spaces around it.
  var name: String
  /// The days of an event: today, until moved.
  private(set) var start: DateOnly
  private(set) var end: DateOnly
  /// The kind of a payment method.
  var paymentKind: PaymentMethodKind = .card

  /// A place or a person starts from the name the entry line read and could not match.
  init(kind: AddFromPicker.Kind, model: EntryDraftModel, today: DateOnly) {
    self.kind = kind
    switch kind {
    case .place: name = model.suggestedPlaceName ?? ""
    case .person, .debtor, .payingFor: name = model.suggestedPersonName ?? ""
    case .category, .subcategory, .event, .paymentMethod: name = ""
    }
    start = today
    end = today
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// A new start takes the end along when it passes it, and an end never comes before the
  /// start: the rule the reference book of events keeps.
  mutating func setStart(_ day: DateOnly) { take(days.startingOn(day)) }
  mutating func setEnd(_ day: DateOnly) { take(days.endingOn(day)) }

  private var days: Event { Event(name: name, startDate: start, endDate: end) }

  private mutating func take(_ moved: Event) {
    start = moved.startDate
    end = moved.endDate
  }

  /// Why «Save» would add nothing, as the key of the words that say so (table «Entry»); nil
  /// when it would. A name has to say something. A person, a place or a payment method whose
  /// name or alias is already another's is refused, as the reference books refuse it: the
  /// entry line could not tell the two apart; a payment method also by the name of another
  /// account's live card. A category is taken by one of the same kind
  /// under the same parent. Events may share a name: a yearly event is made again every year.
  func refusalKey(in model: EntryDraftModel) -> String? {
    let name = trimmedName
    guard !ReferenceNames.folded(name).isEmpty else { return "entry.add.nameMissing" }
    let taken: Bool
    switch kind {
    case .category:
      taken = Self.isTaken(category: name, under: nil, in: model)
    case .subcategory(let part):
      taken = Self.isTaken(
        category: name, under: model.categoryOfPart(model.part(at: part)), in: model)
    case .person, .debtor, .payingFor:
      taken = !ReferenceBooksView.canAdd(name, to: .people, people: model.people, places: [])
    case .place:
      taken = !ReferenceBooksView.canAdd(name, to: .places, people: [], places: model.places)
    case .paymentMethod:
      taken =
        ReferenceNames.isTaken(
          name, among: model.paymentMethods.filter { !$0.archived }.map(ReferenceNames.spellings))
        || Self.cardOfLiveAccount(named: name, in: model) != nil
    case .event:
      taken = false
    }
    guard taken else { return nil }
    switch kind {
    case .category, .subcategory: return "entry.add.categoryTaken"
    default: return "entry.add.nameTaken"
    }
  }

  /// A live card of a live account the entry line reads `name` as. An account called so would
  /// take that card's purchases, and the card it starts with would give the line two cards of
  /// one name, of which it reads neither. The cards of an archived account are left to «Save»:
  /// the name may be the one that brings that very account back.
  private static func cardOfLiveAccount(
    named name: String, in model: EntryDraftModel
  ) -> PaymentCard? {
    let live = Set(model.paymentMethods.filter { !$0.archived }.map(\.id))
    // No account has the tag's id, so every live card of a live account is another's.
    return CardRules.cardTaking(
      name, except: AddFromPicker.tag, cards: model.cards.filter { live.contains($0.accountId) })
  }

  private static func isTaken(
    category name: String, under parent: UUID?, in model: EntryDraftModel
  ) -> Bool {
    let wanted = ReferenceNames.folded(name)
    return model.categories.contains { category in
      category.parentId == parent && category.kind == model.draft.kind.categoryKind
        && ReferenceNames.folded(category.name) == wanted
    }
  }

  /// Why nothing was written, when the database refused: the key of the words (table «Entry»).
  var failureKey: String {
    switch kind {
    case .category, .subcategory: "entry.error.categoryNotCreated"
    case .person, .debtor, .payingFor: "entry.error.personNotCreated"
    case .place: "entry.error.placeNotCreated"
    case .event: "entry.error.eventNotCreated"
    case .paymentMethod: "entry.error.paymentMethodNotCreated"
    }
  }

  /// Writes the record the way the panel writes one and chooses it in the menu the sheet was
  /// opened from. False when nothing was written (`commit` says why).
  func save(into model: EntryDraftModel, today: DateOnly, context: Context = Context()) -> Bool {
    commit(into: model, today: today, context: context) == nil
  }

  /// «Save»: writes the record and chooses it in the menu the sheet was opened from; nil when
  /// it did, otherwise why nothing was written — a refusal, a part that is no longer there, a
  /// write the database refused, an account that cannot come back.
  ///
  /// A name the archive holds brings that row back instead of a second one of the same name,
  /// by the rules of Settings: a category of the same kind beside the same parent; a person and
  /// a place — by the panel's reading of the name — with the other names a live row took
  /// meanwhile dropped; an event whose days meet the days of the sheet; an account by the rules
  /// of the accounts. A new account is in the default currency.
  func commit(
    into model: EntryDraftModel, today: DateOnly, context: Context = Context()
  ) -> Failure? {
    if let key = refusalKey(in: model) { return .key(key) }
    let name = trimmedName
    // The reason is this form's own, never the one an earlier «Add…» left on the model.
    let failed = Failure.key(failureKey)
    switch kind {
    case .category(let part):
      guard model.draft.parts.indices.contains(part) else { return failed }
      switch category(named: name, under: nil, context: context, model: model) {
      case .success(let id): model.setCategory(id, forPartAt: part)
      case .failure(let failure): return failure
      }
    case .subcategory(let part):
      guard model.canAddSubcategory(forPartAt: part),
        let parent = model.categoryOfPart(model.part(at: part))
      else { return failed }
      switch category(named: name, under: parent, context: context, model: model) {
      case .success(let id): model.setSubcategory(id, forPartAt: part)
      case .failure(let failure): return failure
      }
    case .person(let part):
      guard model.draft.parts.indices.contains(part) else { return failed }
      switch person(named: name, context: context, model: model) {
      case .success(let id): model.draft.parts[part].forPersonId = id
      case .failure(let failure): return failure
      }
    case .debtor(let part):
      guard model.draft.parts.indices.contains(part) else { return failed }
      switch person(named: name, context: context, model: model) {
      case .success(let id): model.draft.parts[part].debtorPersonId = id
      case .failure(let failure): return failure
      }
    case .payingFor(let slot):
      switch person(named: name, context: context, model: model) {
      case .success(let id): model.setPayingForPerson(id, slot: slot)
      case .failure(let failure): return failure
      }
    case .place:
      switch place(named: name, context: context, model: model) {
      case .success(let id): model.draft.placeId = id
      case .failure(let failure): return failure
      }
    case .event(let part):
      guard model.draft.parts.indices.contains(part),
        let id = event(named: name, context: context, model: model)
      else { return failed }
      model.draft.parts[part].eventId = id
    case .paymentMethod:
      switch account(named: name, context: context, model: model) {
      case .success(let id): model.setPaymentMethod(id)
      case .failure(let failure): return failure
      }
    }
    // What the new record brings: a place its payment method, a category its quality.
    model.applyDefaults(today: today)
    return nil
  }

  /// The category the archive holds under the name — of the kind of the operation, beside the
  /// same parent — brought back by its flag, or a new one.
  private func category(
    named name: String, under parent: UUID?, context: Context, model: EntryDraftModel
  ) -> Result<UUID, Failure> {
    if let references = context.references,
      let archived = NewReference.archivedCategory(
        named: name, kind: model.draft.kind.categoryKind, parent: parent,
        among: (try? references.categories(includeArchived: true)) ?? [])
    {
      let restored = AppEnvironment.attempt("references.add", on: references) {
        try $0.restoreCategory(archived.id)
      }
      guard restored else { return .failure(.key(failureKey)) }
      model.reload()
      return .success(archived.id)
    }
    guard let id = model.createCategory(named: name, under: parent) else {
      return .failure(.key(failureKey))
    }
    return .success(id)
  }

  /// A person the panel reads the name as — from the archive too — or a new one. With the
  /// dictionaries at hand, one from the archive comes back as «Вернуть» brings it back in
  /// Settings: its other names a live row took meanwhile are dropped, and one whose own name a
  /// live row has taken stays where it is.
  private func person(
    named name: String, context: Context, model: EntryDraftModel
  ) -> Result<UUID, Failure> {
    guard let references = context.references else {
      guard let id = model.createPerson(named: name) else { return .failure(.key(failureKey)) }
      return .success(id)
    }
    var taken = false
    let id = model.createPerson(named: name) { person in
      try Self.bringBack(person.id, in: .people, references: references, taken: &taken) {
        try references.save(person)
      }
    }
    guard let id else { return .failure(.key(taken ? "entry.add.nameTaken" : failureKey)) }
    return .success(id)
  }

  /// A place, by the rules of `person(named:…)`.
  private func place(
    named name: String, context: Context, model: EntryDraftModel
  ) -> Result<UUID, Failure> {
    guard let references = context.references else {
      guard let id = model.createPlace(named: name) else { return .failure(.key(failureKey)) }
      return .success(id)
    }
    var taken = false
    let id = model.createPlace(named: name) { place in
      try Self.bringBack(place.id, in: .places, references: references, taken: &taken) {
        try references.save(place)
      }
    }
    guard let id else { return .failure(.key(taken ? "entry.add.nameTaken" : failureKey)) }
    return .success(id)
  }

  /// «Вернуть» of the row `id` when the archive holds it; `save` writes it as a new one when
  /// there is no such row. `taken` is set when a live row has the archived row's own name.
  private static func bringBack(
    _ id: UUID, in book: ReferenceBook, references: ReferenceRepository, taken: inout Bool,
    save: () throws -> Void
  ) throws {
    do {
      try references.restore(id, in: book)
    } catch ReferenceWriteError.notFound {
      try save()
    } catch ReferenceWriteError.nameTaken {
      taken = true
      throw ReferenceWriteError.nameTaken
    }
  }

  /// The event brought back from the archive for the name and the days of the sheet, or a new
  /// one; nil when nothing was written.
  private func event(named name: String, context: Context, model: EntryDraftModel) -> UUID? {
    guard let references = context.references else {
      return model.createEvent(named: name, from: start, to: end)
    }
    let revived: UUID?
    do {
      revived = try references.revive(named: name, in: .events, days: start...max(start, end))
    } catch {
      AppLog.error(
        "references.saveFailed", .db, "an archived event could not be brought back",
        [LogPair("reference", .token("event")), LogPair("error", .error(error))])
      return nil
    }
    guard let revived else { return model.createEvent(named: name, from: start, to: end) }
    model.reload()
    return revived
  }

  /// The account brought back from the archive for the name, or a new one in the default
  /// currency, placed where a new account goes.
  private func account(
    named name: String, context: Context, model: EntryDraftModel
  ) -> Result<UUID, Failure> {
    guard let references = context.references else {
      guard let id = model.createPaymentMethod(named: name, kind: paymentKind) else {
        return .failure(.key(failureKey))
      }
      return .success(id)
    }
    let all = (try? references.paymentMethods(includeArchived: true)) ?? model.paymentMethods
    if let restore = context.restoreAccount,
      let archived = NewReference.archivedAccount(answering: name, among: all)
    {
      switch restore(archived.id) {
      case .done:
        model.reload()
        return .success(archived.id)
      case .refused(let refusal):
        return .failure(.accountNotBack(archived.name, refusal))
      case .failed:
        return .failure(.key(failureKey))
      }
    }
    var account = NewReference.paymentMethod(
      named: name, kind: paymentKind, currency: context.defaultCurrency,
      among: all.filter { !$0.archived })
    // Under a bank, like every account: the live bank of its name, else a new one written with it.
    let choice = BankRules.bank(
      forNewAccountNamed: name,
      among: (try? references.banks(includeArchived: true)) ?? model.banks)
    account.bankId = choice.bank.id
    // A live card of an account in the archive keeps its name as well: the line reads it again
    // the day its account comes back.
    guard CardRules.cardTaking(name, except: account.id, cards: model.cards) == nil else {
      return .failure(.key("entry.add.nameTaken"))
    }
    // A card or a bank account is paid from with a card: it comes with one named like it, in
    // the same write.
    guard
      AppEnvironment.attempt(
        "references.add", on: references,
        {
          try $0.save(
            account, startingCard: CardRules.startingCard(for: account),
            bank: choice.isNew ? choice.bank : nil)
        })
    else {
      return .failure(.key(failureKey))
    }
    model.reload()
    return .success(account.id)
  }

  /// «Вернуть» of an account from «Add…»: the account by the rules of the accounts, then its
  /// currencies of the bank switched on — as many as it holds; the owner's own currencies are
  /// never switched on, they are always offered.
  @MainActor
  static func restoreAccount(
    _ id: UUID, environment: AppEnvironment, store: TransactionsStore
  ) -> AccountActionOutcome {
    guard let settings = environment.settings,
      let account = try? environment.references?.paymentMethods(includeArchived: true)
        .first(where: { $0.id == id })
    else { return .refused(.notFound) }
    let enabled = (try? settings.enabledCurrencies()) ?? CurrencyCode.defaultEnabled
    let missing = account.currencies.filter {
      !enabled.contains($0) && !environment.currencyCatalog.isCustom($0)
    }
    let outcome = AccountActions(environment: environment, store: store).restore(id)
    guard outcome == .done, !missing.isEmpty else { return outcome }
    // The account is back either way; a currency the database would not switch on is said
    // in the journal and stays offered in Settings → Валюты.
    environment.attempt("settings.currencies", on: settings) {
      try $0.setEnabledCurrencies(enabled + missing)
    }
    environment.refreshAccountSettings()
    environment.refreshVocabulary()
    return outcome
  }
}
