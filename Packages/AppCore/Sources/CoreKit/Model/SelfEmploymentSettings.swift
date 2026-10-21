import Foundation

/// The tax an income in a category owes: a percent, and whether it is the tax on professional
/// income (НПД) with its deduction, its 100-ruble rule and its due day.
public struct IncomeTax: Hashable, Sendable, Codable {
  public var rate: Decimal
  public var npd: Bool

  public init(rate: Decimal, npd: Bool = false) {
    self.rate = rate
    self.npd = npd
  }
}

/// What the law says of the tax on professional income, as the app knows it; the owner may
/// correct any value in the settings (`SelfEmploymentSettings.overrides`).
public struct NPDReference: Hashable, Sendable, Codable {
  /// % on income from individuals.
  public var individualsRate: Decimal
  /// % on income from organisations.
  public var organizationsRate: Decimal
  /// The deduction a self-employed person has, all of it.
  public var deductionTotalE4: AmountE4
  /// Percentage points the deduction takes off the rate on individuals (4 → 3).
  public var individualsCut: Decimal
  /// …and on organisations (6 → 4).
  public var organizationsCut: Decimal
  /// The income of a year above which the tax no longer applies.
  public var yearLimitE4: AmountE4
  /// The day of the next month the tax of a month is due.
  public var dueDay: Int
  /// A tax below this is not due yet: it goes on to the next month.
  public var minimumTaxE4: AmountE4
  /// Days before the due day the reminder starts.
  public var remindDaysBefore: Int

  public init(
    individualsRate: Decimal = 4, organizationsRate: Decimal = 6,
    deductionTotalE4: AmountE4 = AmountE4(whole: 10_000), individualsCut: Decimal = 1,
    organizationsCut: Decimal = 2, yearLimitE4: AmountE4 = AmountE4(whole: 2_400_000),
    dueDay: Int = 28, minimumTaxE4: AmountE4 = AmountE4(whole: 100), remindDaysBefore: Int = 3
  ) {
    self.individualsRate = individualsRate
    self.organizationsRate = organizationsRate
    self.deductionTotalE4 = deductionTotalE4
    self.individualsCut = individualsCut
    self.organizationsCut = organizationsCut
    self.yearLimitE4 = yearLimitE4
    self.dueDay = dueDay
    self.minimumTaxE4 = minimumTaxE4
    self.remindDaysBefore = remindDaysBefore
  }

  /// The law as the app knows it.
  public static let law = NPDReference()
}

/// The values of `NPDReference` the owner corrected; `nil` — as the law says.
public struct NPDOverrides: Hashable, Sendable, Codable {
  public var individualsRate: Decimal?
  public var organizationsRate: Decimal?
  public var deductionTotalE4: AmountE4?
  public var yearLimitE4: AmountE4?
  public var dueDay: Int?
  public var minimumTaxE4: AmountE4?
  public var remindDaysBefore: Int?

  public init(
    individualsRate: Decimal? = nil, organizationsRate: Decimal? = nil,
    deductionTotalE4: AmountE4? = nil, yearLimitE4: AmountE4? = nil, dueDay: Int? = nil,
    minimumTaxE4: AmountE4? = nil, remindDaysBefore: Int? = nil
  ) {
    self.individualsRate = individualsRate
    self.organizationsRate = organizationsRate
    self.deductionTotalE4 = deductionTotalE4
    self.yearLimitE4 = yearLimitE4
    self.dueDay = dueDay
    self.minimumTaxE4 = minimumTaxE4
    self.remindDaysBefore = remindDaysBefore
  }

  public static let none = NPDOverrides()

  /// The law with these corrections over it.
  public func applied(to law: NPDReference = .law) -> NPDReference {
    var reference = law
    if let individualsRate { reference.individualsRate = individualsRate }
    if let organizationsRate { reference.organizationsRate = organizationsRate }
    if let deductionTotalE4 { reference.deductionTotalE4 = deductionTotalE4 }
    if let yearLimitE4 { reference.yearLimitE4 = yearLimitE4 }
    if let dueDay { reference.dueDay = dueDay }
    if let minimumTaxE4 { reference.minimumTaxE4 = minimumTaxE4 }
    if let remindDaysBefore { reference.remindDaysBefore = remindDaysBefore }
    return reference
  }
}

/// Settings of self-employment, kept in the `settings` table under these keys. A key that is
/// not there means its default, so nothing is ever inserted for them up front; they travel
/// inside the database of the archive.
public struct SelfEmploymentSettings: Hashable, Sendable, Codable {
  /// `1`: the owner is self-employed; absent — not.
  public static let enabledKey = "selfEmployed.enabled"
  /// `1`: the offer to turn it on was made once.
  public static let offeredKey = "selfEmployed.offered"
  /// The deduction left, a decimal string in rubles, on the day of `deductionLeftOnKey`.
  public static let deductionLeftKey = "selfEmployed.deductionLeft"
  public static let deductionLeftOnKey = "selfEmployed.deductionLeftOn"
  /// The account the tax is kept on, by id.
  public static let taxAccountKey = "selfEmployed.taxAccount"
  /// The expense category the tax is paid in, by id.
  public static let taxCategoryKey = "selfEmployed.taxCategory"
  /// The expense category a return to a client goes to, by id.
  public static let returnCategoryKey = "selfEmployed.returnCategory"
  /// Corrections of the law (`NPDReference`).
  public static let individualsRateKey = "selfEmployed.rate.individuals"
  public static let organizationsRateKey = "selfEmployed.rate.organizations"
  public static let deductionKey = "selfEmployed.deduction"
  public static let yearLimitKey = "selfEmployed.yearLimit"
  public static let dueDayKey = "selfEmployed.dueDay"
  public static let minimumTaxKey = "selfEmployed.minimumTax"
  public static let remindDaysKey = "selfEmployed.remindDays"

  /// Every key these settings live under, and write.
  public static let storageKeys = [
    enabledKey, offeredKey, deductionLeftKey, deductionLeftOnKey, taxAccountKey, taxCategoryKey,
    returnCategoryKey, individualsRateKey, organizationsRateKey, deductionKey, yearLimitKey,
    dueDayKey, minimumTaxKey, remindDaysKey,
  ]

  public var enabled: Bool
  public var offered: Bool
  /// `nil`: the owner has not said — no deduction is counted.
  public var deductionLeftE4: AmountE4?
  public var deductionLeftOn: DateOnly?
  public var taxAccountId: UUID?
  public var taxCategoryId: UUID?
  public var returnCategoryId: UUID?
  /// Only the values of the law the owner corrected.
  public var overrides: NPDOverrides

  public init(
    enabled: Bool = false, offered: Bool = false, deductionLeftE4: AmountE4? = nil,
    deductionLeftOn: DateOnly? = nil, taxAccountId: UUID? = nil, taxCategoryId: UUID? = nil,
    returnCategoryId: UUID? = nil, overrides: NPDOverrides = .none
  ) {
    self.enabled = enabled
    self.offered = offered
    self.deductionLeftE4 = deductionLeftE4
    self.deductionLeftOn = deductionLeftOn
    self.taxAccountId = taxAccountId
    self.taxCategoryId = taxCategoryId
    self.returnCategoryId = returnCategoryId
    self.overrides = overrides
  }

  public static let standard = SelfEmploymentSettings()

  /// The law with the owner's corrections.
  public var reference: NPDReference { overrides.applied() }

  /// The settings the rows give. A value that does not read keeps its default: a damaged value
  /// must not stop anything from being computed.
  public init(storedValues values: [String: String]) {
    self.init(
      enabled: values[Self.enabledKey].flatMap(SettingText.switchValue) ?? false,
      offered: values[Self.offeredKey].flatMap(SettingText.switchValue) ?? false,
      deductionLeftE4: values[Self.deductionLeftKey].flatMap(SettingText.amount)
        .flatMap { $0.isNegative ? nil : $0 },
      deductionLeftOn: values[Self.deductionLeftOnKey].flatMap(SettingText.day),
      taxAccountId: values[Self.taxAccountKey].flatMap(SettingText.uuid),
      taxCategoryId: values[Self.taxCategoryKey].flatMap(SettingText.uuid),
      returnCategoryId: values[Self.returnCategoryKey].flatMap(SettingText.uuid),
      overrides: NPDOverrides(
        individualsRate: values[Self.individualsRateKey].flatMap(SettingText.percent),
        organizationsRate: values[Self.organizationsRateKey].flatMap(SettingText.percent),
        deductionTotalE4: values[Self.deductionKey].flatMap(SettingText.amount)
          .flatMap { $0.isNegative ? nil : $0 },
        yearLimitE4: values[Self.yearLimitKey].flatMap(SettingText.amount)
          .flatMap { $0.raw > 0 ? $0 : nil },
        dueDay: values[Self.dueDayKey].flatMap(SettingText.number)
          .flatMap { (1...31).contains($0) ? $0 : nil },
        minimumTaxE4: values[Self.minimumTaxKey].flatMap(SettingText.amount)
          .flatMap { $0.isNegative ? nil : $0 },
        remindDaysBefore: values[Self.remindDaysKey].flatMap(SettingText.number)
          .flatMap { (0...31).contains($0) ? $0 : nil }))
  }

  /// The rows to write; a setting at nothing deletes its key (`nil`).
  public var storedValues: [String: String?] {
    [
      Self.enabledKey: enabled ? "1" : nil,
      Self.offeredKey: offered ? "1" : nil,
      Self.deductionLeftKey: deductionLeftE4.map(SettingText.text),
      Self.deductionLeftOnKey: deductionLeftOn?.iso,
      Self.taxAccountKey: taxAccountId?.uuidString,
      Self.taxCategoryKey: taxCategoryId?.uuidString,
      Self.returnCategoryKey: returnCategoryId?.uuidString,
      Self.individualsRateKey: overrides.individualsRate.map { "\($0)" },
      Self.organizationsRateKey: overrides.organizationsRate.map { "\($0)" },
      Self.deductionKey: overrides.deductionTotalE4.map(SettingText.text),
      Self.yearLimitKey: overrides.yearLimitE4.map(SettingText.text),
      Self.dueDayKey: overrides.dueDay.map { String($0) },
      Self.minimumTaxKey: overrides.minimumTaxE4.map(SettingText.text),
      Self.remindDaysKey: overrides.remindDaysBefore.map { String($0) },
    ]
  }
}

/// How the settings of 1.9 read and write their values: a value that does not read is `nil`.
enum SettingText {
  static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespaces)
  }

  static func number(_ text: String) -> Int? { Int(trimmed(text)) }

  /// `1`/`0` as the app writes switches; `true`/`false` as a person or the Windows port might.
  static func switchValue(_ text: String) -> Bool? {
    switch trimmed(text).lowercased() {
    case "1", "true": true
    case "0", "false": false
    default: nil
    }
  }

  static func uuid(_ text: String) -> UUID? { UUID(uuidString: trimmed(text)) }

  /// UUIDs separated by commas; one that does not read is left out.
  static func uuids(_ text: String) -> [UUID] {
    text.split(separator: ",").compactMap { UUID(uuidString: trimmed(String($0))) }
  }

  /// `YYYY-MM-DD` of a day the calendar has.
  static func day(_ text: String) -> DateOnly? {
    guard let day = DateOnly(iso: trimmed(text)), day.day <= days(in: day.year, day.month) else {
      return nil
    }
    return day
  }

  private static func days(in year: Int, _ month: Int) -> Int {
    switch month {
    case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  /// `YYYY-MM` exactly.
  static func month(_ text: String) -> MonthKey? {
    let value = trimmed(text)
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 4, parts[1].count == 2 else { return nil }
    return MonthKey(iso: value)
  }

  /// A decimal string with a point, rubles; written by `text`.
  static func amount(_ text: String) -> AmountE4? {
    guard let value = Decimal(string: trimmed(text), locale: Locale(identifier: "en_US_POSIX"))
    else { return nil }
    return try? AmountE4(decimal: value)
  }

  /// A percent, 0…100.
  static func percent(_ text: String) -> Decimal? {
    guard let value = Decimal(string: trimmed(text), locale: Locale(identifier: "en_US_POSIX")),
      value >= 0, value <= 100
    else { return nil }
    return value
  }

  static func text(_ amount: AmountE4) -> String { "\(amount.decimal)" }
}
