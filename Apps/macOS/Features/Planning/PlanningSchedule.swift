import AppCore
import Foundation

/// How often a scheduled payment comes, as its form offers it: one picker of the usual
/// cadences, «Once» for a planned expense of a single date, and «Other…» for any other count
/// of weeks, months or years. A preset is only a way of choosing: the payment keeps its
/// frequency and interval, and «Once» is a single month — every month, ending on its own next
/// date.
enum FrequencyPreset: String, CaseIterable, Hashable, Sendable {
  case weekly
  case everyTwoWeeks
  case monthly
  case everyTwoMonths
  case quarterly
  case halfYearly
  case yearly
  case once
  case other

  /// The frequency and interval the preset stands for; nil for «Once», which is a date and not
  /// a rhythm, and for «Other…», where the owner sets both.
  var cadence: Cadence? {
    switch self {
    case .weekly: Cadence(.weekly, 1)
    case .everyTwoWeeks: Cadence(.weekly, 2)
    case .monthly: Cadence(.monthly, 1)
    case .everyTwoMonths: Cadence(.monthly, 2)
    case .quarterly: Cadence(.monthly, 3)
    case .halfYearly: Cadence(.monthly, 6)
    case .yearly: Cadence(.yearly, 1)
    case .once, .other: nil
    }
  }

  /// The words of the picker (table «Planning»).
  var key: String { "form.preset.\(rawValue)" }

  /// The preset a saved payment reads as: «Once» when it is a single month — every month and
  /// ending on its next date, as «Once» is saved — the preset of its frequency and interval when
  /// there is one, «Other…» for every other interval: a row made every 5 months still opens as
  /// what it is. A yearly subscription whose last due has come ends on its next date too, and
  /// still opens as yearly.
  static func of(_ payment: ScheduledPayment) -> FrequencyPreset {
    let cadence = Cadence(payment.freq, payment.interval)
    if let next = payment.nextDate, payment.endDate == next, cadence == onceCadence {
      return .once
    }
    return of(cadence)
  }

  /// What «Once» is saved as: every month, ending on its next date.
  static let onceCadence = Cadence(.monthly, 1)

  static func of(_ cadence: Cadence) -> FrequencyPreset {
    allCases.first { $0.cadence == cadence } ?? .other
  }

  /// A frequency and an interval: every `interval` weeks, months or years.
  struct Cadence: Hashable, Sendable {
    var freq: Frequency
    var interval: Int

    init(_ freq: Frequency, _ interval: Int) {
      self.freq = freq
      self.interval = interval
    }
  }

  /// The intervals «Other…» offers.
  static let intervals = 1...24

  /// The words of «Other…» for a frequency, declined with the number: «Каждые 5 месяцев».
  static func everyKey(_ freq: Frequency) -> String { "form.every.\(freq.rawValue)" }

  /// The words of «Other…» for `interval` units of `freq`: «Каждые 5 месяцев», «Каждые 21
  /// неделю». One unit is said the way its preset says it — «Каждую неделю» — never «каждые 1
  /// неделю».
  @MainActor
  static func everyText(_ freq: Frequency, interval: Int, language: AppLanguage) -> String {
    let preset = of(Cadence(freq, interval))
    if interval == 1, preset != .other {
      return language(preset.key, table: "Planning")
    }
    return language.format(everyKey(freq), table: "Planning", interval)
  }
}

/// «On the last day of the month» of a schedule. It is kept as a day of the rule that every
/// shorter month clips to its own last day: 31 for a monthly rule, and for a yearly one the
/// longest its month ever gets — 29 in February, 30 in April — the most a yearly day may be.
/// A weekly rule has no such day.
enum MonthEnd {
  /// The day a rule of `freq` keeps for the last day of the month; `month` is the month of a
  /// yearly rule.
  static func day(freq: Frequency, month: Int?) -> Int {
    guard freq == .yearly, let month, (1...12).contains(month) else { return 31 }
    return MonthKey(year: 2000, month: month).dayCount
  }

  /// Whether a stored day means the last day of the month.
  static func isLastDay(day: Int?, freq: Frequency, month: Int?) -> Bool {
    guard let day, freq != .weekly else { return false }
    return day == Self.day(freq: freq, month: month)
  }

  /// The last day of the month of `date`: where a date chosen with the switch on goes.
  static func lastDay(of date: DateOnly) -> DateOnly { date.monthKey.lastDay }
}

extension ScheduledPayment {
  /// Whether its rule keeps the last day of the month.
  var isOnLastDay: Bool { MonthEnd.isLastDay(day: day, freq: freq, month: month) }

  /// The row the form saves, from what the form holds: the frequency and interval of the
  /// preset chosen, the end date of «Once» or of the «Ends» switch, the trial of its switch,
  /// and the day (and the month of a yearly rule) the schedule keeps.
  ///
  /// The day is read off the next date only when the owner changed the schedule — the date,
  /// the frequency, or the last-day switch — or the payment is new. The next date of a
  /// payment of the 31st is clipped to the 30th in a short month, and reading the day off it
  /// at every save turned it into a payment of the 30th for good.
  func readyToSave(
    original: ScheduledPayment?, preset: FrequencyPreset, lastDay: Bool, hasEnd: Bool,
    hasTrial: Bool, today: DateOnly
  ) -> ScheduledPayment {
    var saved = self
    if let cadence = preset == .once ? FrequencyPreset.onceCadence : preset.cadence {
      saved.freq = cadence.freq
      saved.interval = cadence.interval
    }
    if preset == .once {
      // A planned expense of one date: the date the form shows, and the schedule ends on it.
      if saved.nextDate == nil { saved.nextDate = today }
      saved.endDate = saved.nextDate
    } else if !hasEnd {
      saved.endDate = nil
    }
    if !hasTrial { saved.trialEnd = nil }
    guard let next = saved.nextDate else { return saved }

    let onLastDay = lastDay && preset != .once && saved.freq != .weekly
    if let original, original.day != nil, original.nextDate == next,
      original.freq == saved.freq, original.isOnLastDay == onLastDay
    {
      saved.day = original.day
      saved.month = original.month
      return saved
    }
    let anchor = Recurrence.anchor(of: next, freq: saved.freq)
    saved.month = anchor.month
    saved.day = onLastDay ? MonthEnd.day(freq: saved.freq, month: anchor.month) : anchor.day
    return saved
  }
}

/// What the form of a scheduled payment holds: the payment as edited, and the choices that
/// are not fields of it — the preset of «How often», the last-day switch, and the switches of
/// the end and of the trial. Every control of the form goes through here, so what one does to
/// the others is the same in the form and in the tests.
struct ScheduledPaymentDraft: Equatable {
  var payment: ScheduledPayment
  private(set) var preset: FrequencyPreset
  private(set) var lastDay: Bool
  private(set) var hasEnd: Bool
  private(set) var hasTrial: Bool

  /// The form of a saved payment, or of a new one. The end of a row read as «Once» is kept
  /// on, out of sight while «Once» is chosen: a monthly subscription on its last due reads as
  /// «Once» too, and choosing its rhythm again shows the end it has rather than dropping it.
  /// The last-day switch is read off the stored day only where the form shows it — a «Once» of
  /// the 31st is a date, and a switch nobody sees would move the next date picked.
  init(opening payment: ScheduledPayment) {
    self.payment = payment
    preset = FrequencyPreset.of(payment)
    hasEnd = payment.endDate != nil
    hasTrial = payment.trialEnd != nil
    lastDay = false
    lastDay = offersLastDay && payment.isOnLastDay
  }

  /// «On the last day of the month» is a day of a month: a weekly rhythm and «Once» have none.
  var offersLastDay: Bool { preset != .once && payment.freq != .weekly }

  /// «Once» ends on its own date: there is no other end to choose.
  var offersEnd: Bool { preset != .once }

  /// A preset chosen writes its frequency and interval at once, so «Other…» opens on the
  /// rhythm the payment had; «Once» and «Other…» leave them as they are. The switch of the
  /// end stays as it was under «Once», which hides it.
  mutating func choose(_ chosen: FrequencyPreset, today: DateOnly) {
    preset = chosen
    if let cadence = chosen.cadence {
      payment.freq = cadence.freq
      payment.interval = cadence.interval
    }
    followTheLastDay(today: today)
  }

  /// The unit of «Other…».
  mutating func setUnit(_ freq: Frequency, today: DateOnly) {
    payment.freq = freq
    followTheLastDay(today: today)
  }

  mutating func setLastDay(_ on: Bool, today: DateOnly) {
    lastDay = on
    followTheLastDay(today: today)
  }

  /// A date picked while the switch is on is the last day of its month. The end of «Once» is
  /// its own date and moves with it, so a rhythm chosen afterwards shows that end.
  mutating func setNextDate(_ date: DateOnly, today: DateOnly) {
    if preset == .once, payment.endDate != nil, payment.endDate == payment.nextDate {
      payment.endDate = date
    }
    payment.nextDate = date
    followTheLastDay(today: today)
  }

  /// Switched on, the end starts today.
  mutating func setHasEnd(_ on: Bool, today: DateOnly) {
    hasEnd = on
    if on, payment.endDate == nil { payment.endDate = today }
  }

  /// Switched on, the trial ends today.
  mutating func setHasTrial(_ on: Bool, today: DateOnly) {
    hasTrial = on
    if on, payment.trialEnd == nil { payment.trialEnd = today }
  }

  /// The row «Save» writes (`ScheduledPayment.readyToSave`).
  func saved(original: ScheduledPayment?, today: DateOnly) -> ScheduledPayment {
    payment.readyToSave(
      original: original, preset: preset, lastDay: lastDay, hasEnd: hasEnd, hasTrial: hasTrial,
      today: today)
  }

  /// What keeps «Save» inactive, or nil: the rules checked on the row «Save» writes. The form
  /// holds the day the payment had until the save reads a new one off the date, and a
  /// payment of the 15th made weekly is saved with a weekday, not refused for a 15th weekday.
  func issue(
    original: ScheduledPayment?, tree: CategoryTree, today: DateOnly
  )
    -> ScheduledIssue?
  {
    ScheduledRules.validate(saved(original: original, today: today), tree: tree)
  }

  /// With the switch on, the next date is moved to the last day of its month. A switch the
  /// form no longer shows — under «Once» or a weekly rhythm — is turned off: out of sight it
  /// would move a date picked later.
  private mutating func followTheLastDay(today: DateOnly) {
    guard offersLastDay else {
      lastDay = false
      return
    }
    guard lastDay else { return }
    payment.nextDate = MonthEnd.lastDay(of: payment.nextDate ?? today)
  }
}
