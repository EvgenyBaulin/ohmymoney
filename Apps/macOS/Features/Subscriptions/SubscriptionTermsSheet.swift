import AppCore
import SwiftUI

/// What the terms editor starts from: the payment it is about, its terms as stored (neutral ones
/// when it has none), and the people it is shared with.
struct SubscriptionTermsRequest: Identifiable {
  var payment: ScheduledPayment
  var terms: SubscriptionTerms
  var people: [UUID]
  var id: UUID { payment.id }
}

/// The terms of a subscription that the payment itself does not hold: what the same service
/// costs on the other plan (so a year can be set against twelve months), «около N» with its
/// tolerance, the type of the service, «нужна», the reminder of a yearly charge, and who shares
/// it. The trial's end, the end date and the cancel link belong to the payment and are edited in
/// its own form. Saving is two writes of the store — the terms and the people — each one step
/// of ⌘Z; a field left empty or at zero means «not known».
struct SubscriptionTermsSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss
  let request: SubscriptionTermsRequest
  @State private var terms: SubscriptionTerms
  @State private var yearlyPlan: AmountE4
  @State private var monthlyPlan: AmountE4
  @State private var tolerance: Int
  @State private var people: Set<UUID>

  init(request: SubscriptionTermsRequest) {
    self.request = request
    _terms = State(initialValue: request.terms)
    _yearlyPlan = State(initialValue: request.terms.yearlyPlanE4 ?? .zero)
    _monthlyPlan = State(initialValue: request.terms.monthlyPlanE4 ?? .zero)
    _tolerance = State(
      initialValue: request.terms.tolerancePercent ?? FloatingAmount.defaultTolerancePercent)
    _people = State(initialValue: Set(request.people))
  }

  private func t(_ key: String) -> String { SubscriptionsText.t(key, environment) }

  var body: some View {
    let payment = request.payment
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: SubscriptionsText.f("subs.terms.title", environment, payment.name))
        .appFont(.headline)
      Form {
        Section(t("subs.terms.plans")) {
          if payment.freq == .monthly {
            LabeledContent(t("subs.terms.yearlyPlan")) {
              AmountField(amount: $yearlyPlan, locale: environment.language.locale)
                .accessibilityIdentifier("subs.terms.yearlyPlan")
            }
          } else if payment.freq == .yearly {
            LabeledContent(t("subs.terms.monthlyPlan")) {
              AmountField(amount: $monthlyPlan, locale: environment.language.locale)
                .accessibilityIdentifier("subs.terms.monthlyPlan")
            }
          }
          Toggle(t("subs.terms.yearlyReminder"), isOn: yearlyReminder)
            .disabled(payment.freq != .yearly)
        }
        Section {
          Toggle(t("subs.terms.floating"), isOn: $terms.floating)
            .accessibilityIdentifier("subs.terms.floating")
          if terms.floating {
            Toggle(t("subs.terms.toleranceAuto"), isOn: toleranceAuto)
            if terms.tolerancePercent != nil {
              Stepper(
                value: $tolerance, in: 1...100,
                step: 1
              ) {
                Text(
                  verbatim: SubscriptionsText.f(
                    "subs.terms.tolerance", environment,
                    SubscriptionsText.wholePercent(tolerance, environment)))
              }
            }
          }
        }
        Section {
          Picker(t("subs.terms.type"), selection: $terms.serviceType) {
            Text(verbatim: t("subs.terms.typeAuto")).tag(ServiceType?.none)
            ForEach(ServiceType.allCases, id: \.self) {
              Text(verbatim: SubscriptionsText.typeName($0, environment)).tag(Optional($0))
            }
          }
          Toggle(t("subs.terms.needed"), isOn: $terms.needed)
            .accessibilityIdentifier("subs.terms.needed")
          Text(verbatim: t("subs.terms.neededNote"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
        Section {
          AttachedFilesCard(owner: .subscription, id: payment.id)
        }
        Section(t("subs.terms.people")) {
          ForEach(candidates) { person in
            Toggle(
              person.name,
              isOn: Binding(
                get: { people.contains(person.id) },
                set: { if $0 { people.insert(person.id) } else { people.remove(person.id) } }))
          }
          if candidates.isEmpty {
            Text(verbatim: t("subs.terms.peopleNote"))
              .appFont(.caption)
              .foregroundStyle(.secondary)
          } else {
            Toggle(t("subs.terms.ownerUses"), isOn: $terms.ownerUses)
          }
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button(t("subs.terms.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(t("subs.terms.save")) { save() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("subs.terms.save")
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 440, idealWidth: 480, minHeight: 460, idealHeight: 620)
  }

  /// The people who can share it: the ones not in the archive, and those already chosen.
  private var candidates: [Person] {
    (compute.snapshot?.dataset.people ?? []).filter { !$0.archived || people.contains($0.id) }
  }

  private var yearlyReminder: Binding<Bool> {
    Binding(get: { !terms.yearlyReminderOff }, set: { terms.yearlyReminderOff = !$0 })
  }

  private var toleranceAuto: Binding<Bool> {
    Binding(
      get: { terms.tolerancePercent == nil },
      set: { terms.tolerancePercent = $0 ? nil : tolerance })
  }

  /// The terms as the sheet would store them.
  var result: SubscriptionTerms {
    var saved = terms
    saved.yearlyPlanE4 = yearlyPlan.raw > 0 ? yearlyPlan : nil
    saved.monthlyPlanE4 = monthlyPlan.raw > 0 ? monthlyPlan : nil
    saved.tolerancePercent = terms.floating && terms.tolerancePercent != nil ? tolerance : nil
    return saved
  }

  private func save() {
    store.saveSubscriptionTerms(result)
    let chosen = (compute.snapshot?.dataset.people ?? []).map(\.id).filter { people.contains($0) }
    if chosen != request.people {
      store.setSubscriptionUsers(payment: request.payment.id, people: chosen)
    }
    dismiss()
  }
}

/// «Отменить с …»: a subscription cancelled from a day is a payment that ends then — it still
/// runs until that day and its history stays. The write is the payment's own save, one step of
/// ⌘Z.
struct SubscriptionCancelSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let payment: ScheduledPayment
  @State private var day: Date

  @MainActor
  init(payment: ScheduledPayment) {
    self.payment = payment
    _day = State(initialValue: Date())
  }

  private func t(_ key: String) -> String { SubscriptionsText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: SubscriptionsText.f("subs.cancel.title", environment, payment.name))
        .appFont(.headline)
      DatePicker(t("subs.cancel.from"), selection: $day, displayedComponents: .date)
        .accessibilityIdentifier("subs.cancel.day")
      Text(verbatim: t("subs.cancel.message"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button(t("subs.terms.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(t("subs.cancel.confirm")) { confirm() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("subs.cancel.confirm")
      }
    }
    .padding(20)
    .sheetFrame(width: 420)
  }

  private func confirm() {
    var ended = payment
    ended.endDate = environment.calendar.day(of: day)
    if let dependencies { PlanningActions(dependencies).save(ended, previous: payment) }
    dismiss()
  }
}
