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
  /// What «Save» needs besides the panel, when the app has it: the dictionaries and the
  /// currency of everything new. Without it — the panel on its own, as its tests make it — a
  /// record is written the way the panel writes one.
  struct Context {
    var references: ReferenceRepository?
    var defaultCurrency: CurrencyCode = .rub

    /// The context of the app's window.
    @MainActor
    static func app(_ environment: AppEnvironment, store: TransactionsStore) -> Context {
      Context(references: environment.references, defaultCurrency: environment.defaultCurrency)
    }
  }

  /// Why «Save» wrote nothing.
  enum Failure: Error, Equatable {
    /// Said by the words of table «Entry» under this key.
    case key(String)

    /// The words under the fields.
    @MainActor
    func text(_ environment: AppEnvironment) -> String {
      switch self {
      case .key(let key): environment.language(key, table: "Entry")
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
  /// when it would. Only a name that says nothing: a name another record has, live or
  /// archived, never stops «Save» — the sheet advises renaming or bringing the old one back
  /// (`PlanningNamesakeNotice`, `accountAdviceKey`).
  func refusalKey(in model: EntryDraftModel) -> String? {
    ReferenceNames.folded(trimmedName).isEmpty ? "entry.add.nameMissing" : nil
  }

  /// For a new account: the name is, or is one of the other names of, another live account or
  /// the name of a live card, or an archived account has it. «Save» still writes the account;
  /// the entry line may read such a name as the other record. Nil for every other kind, whose
  /// advice is the namesake notice.
  func accountAdviceKey(in model: EntryDraftModel, all: [PaymentMethod]? = nil) -> String? {
    guard kind == .paymentMethod else { return nil }
    let name = trimmedName
    guard !ReferenceNames.folded(name).isEmpty else { return nil }
    let accounts = all ?? model.paymentMethods
    let spellings = accounts.map(ReferenceNames.spellings)
    if accounts.filter({ !$0.archived }).map(ReferenceNames.spellings)
      .contains(where: { $0.contains { ReferenceNames.folded($0) == ReferenceNames.folded(name) } })
      || Self.cardOfLiveAccount(named: name, in: model) != nil
    {
      return "entry.add.accountNameTaken"
    }
    return spellings.contains(where: { $0.contains { ReferenceNames.folded($0) == ReferenceNames.folded(name) } })
      ? "entry.add.accountInArchive" : nil
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
  /// A name another record has, live or archived, changes nothing: a new record is written,
  /// and the owner chooses to rename or bring the old one back from the notice. A new account
  /// is in the default currency.
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

  /// A new category, beside any of the same name.
  private func category(
    named name: String, under parent: UUID?, context: Context, model: EntryDraftModel
  ) -> Result<UUID, Failure> {
    guard let id = model.createCategory(named: name, under: parent) else {
      return .failure(.key(failureKey))
    }
    return .success(id)
  }

  /// A new person; a namesake in the archive stays there until the owner brings it back.
  private func person(
    named name: String, context: Context, model: EntryDraftModel
  ) -> Result<UUID, Failure> {
    guard let id = model.createPerson(named: name) else { return .failure(.key(failureKey)) }
    return .success(id)
  }

  /// A new place, by the rules of `person(named:…)`.
  private func place(
    named name: String, context: Context, model: EntryDraftModel
  ) -> Result<UUID, Failure> {
    guard let id = model.createPlace(named: name) else { return .failure(.key(failureKey)) }
    return .success(id)
  }

  /// A new event for the days of the sheet, beside any of the same name.
  private func event(named name: String, context: Context, model: EntryDraftModel) -> UUID? {
    model.createEvent(named: name, from: start, to: end)
  }

  /// A new account in the default currency, placed where a new account goes.
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
    var account = NewReference.paymentMethod(
      named: name, kind: paymentKind, currency: context.defaultCurrency,
      among: all.filter { !$0.archived })
    // Under a bank, like every account: the live bank of its name, else a new one written with it.
    let choice = BankRules.bank(
      forNewAccountNamed: name,
      among: (try? references.banks(includeArchived: true)) ?? model.banks)
    account.bankId = choice.bank.id
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
}
