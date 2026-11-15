import Foundation

/// What a meter counts. A kind a later build adds reads as `other`, while the meter keeps the
/// word it was stored with (`UtilityMeter.kindKey`), so saving it back loses nothing.
public enum UtilityKind: String, CaseIterable, Sendable, Codable {
  case coldWater = "cold_water"
  case hotWater = "hot_water"
  case electricity
  case gas
  case heat
  case other

  /// The unit a new meter of this kind is counted in.
  public var defaultUnit: String {
    switch self {
    case .coldWater, .hotWater, .gas: "m3"
    case .electricity: "kwh"
    case .heat: "gcal"
    case .other: "unit"
    }
  }
}

/// A meter of the home (`utility_meters`): water, electricity, gas, heat. Quantities, like money,
/// are whole numbers of 1/10000 (`AmountE4`), so 123.456 m³ is 1234560 and no `Double` counts.
public struct UtilityMeter: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  /// The word stored in the database; `kind` reads it.
  public var kindKey: String
  /// `m3`, `kwh`, `gcal` or what the owner typed.
  public var unit: String
  /// The price of one unit now, in `currency`; nil — not known.
  public var tariffE4: AmountE4?
  public var currency: CurrencyCode
  /// The first and the last day of the month the provider takes readings on; nil — no reminder.
  /// A window may cross the end of a month: 25 to 5.
  public var submitFrom: Int?
  public var submitTo: Int?
  public var provider: String?
  /// The payment of «Планирование» that pays for what the meter counts.
  public var scheduledPaymentId: UUID?
  public var archived: Bool
  public var sort: Int
  public var note: String?

  public var kind: UtilityKind {
    get { UtilityKind(rawValue: kindKey) ?? .other }
    set { kindKey = newValue.rawValue }
  }

  public init(
    id: UUID = UUID(), name: String, kind: UtilityKind, unit: String? = nil,
    tariffE4: AmountE4? = nil, currency: CurrencyCode = .rub, submitFrom: Int? = nil,
    submitTo: Int? = nil, provider: String? = nil, scheduledPaymentId: UUID? = nil,
    archived: Bool = false, sort: Int = 0, note: String? = nil
  ) {
    self.id = id
    self.name = name
    self.kindKey = kind.rawValue
    self.unit = unit ?? kind.defaultUnit
    self.tariffE4 = tariffE4
    self.currency = currency
    self.submitFrom = submitFrom
    self.submitTo = submitTo
    self.provider = provider
    self.scheduledPaymentId = scheduledPaymentId
    self.archived = archived
    self.sort = sort
    self.note = note
  }
}

/// What a meter showed on a day (`utility_readings`).
public struct UtilityReading: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var meterId: UUID
  public var day: DateOnly
  public var valueE4: AmountE4
  /// The meter was replaced or went round: nothing is counted between the reading before and
  /// this one, and the count starts again from this value.
  public var restart: Bool
  /// The price of a unit this reading is counted at; nil — the meter's.
  public var tariffE4: AmountE4?
  /// When the owner passed it to the provider; nil — not yet.
  public var submittedAt: Date?
  public var recordedAt: Date

  public init(
    id: UUID = UUID(), meterId: UUID, day: DateOnly, valueE4: AmountE4, restart: Bool = false,
    tariffE4: AmountE4? = nil, submittedAt: Date? = nil, recordedAt: Date
  ) {
    self.id = id
    self.meterId = meterId
    self.day = day
    self.valueE4 = valueE4
    self.restart = restart
    self.tariffE4 = tariffE4
    self.submittedAt = submittedAt
    self.recordedAt = recordedAt
  }
}

/// A bill of a provider for one month (`utility_bills`).
public struct UtilityBill: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var provider: String
  public var period: MonthKey
  public var totalE4: AmountE4
  public var currency: CurrencyCode
  public var payBy: DateOnly?
  /// The operation that paid it.
  public var transactionId: UUID?
  /// The payment of «Планирование» it belongs to.
  public var scheduledPaymentId: UUID?
  public var note: String?
  public var recordedAt: Date

  public init(
    id: UUID = UUID(), provider: String, period: MonthKey, totalE4: AmountE4,
    currency: CurrencyCode = .rub, payBy: DateOnly? = nil, transactionId: UUID? = nil,
    scheduledPaymentId: UUID? = nil, note: String? = nil, recordedAt: Date
  ) {
    self.id = id
    self.provider = provider
    self.period = period
    self.totalE4 = totalE4
    self.currency = currency
    self.payBy = payBy
    self.transactionId = transactionId
    self.scheduledPaymentId = scheduledPaymentId
    self.note = note
    self.recordedAt = recordedAt
  }
}

/// A line of a bill (`utility_charges`): a service and what it costs, below zero for a
/// recalculation in the owner's favour.
public struct UtilityCharge: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var billId: UUID
  public var service: String
  public var amountE4: AmountE4
  public var quantityE4: AmountE4?
  public var tariffE4: AmountE4?
  public var meterId: UUID?
  public var sort: Int

  public init(
    id: UUID = UUID(), billId: UUID, service: String, amountE4: AmountE4,
    quantityE4: AmountE4? = nil, tariffE4: AmountE4? = nil, meterId: UUID? = nil, sort: Int = 0
  ) {
    self.id = id
    self.billId = billId
    self.service = service
    self.amountE4 = amountE4
    self.quantityE4 = quantityE4
    self.tariffE4 = tariffE4
    self.meterId = meterId
    self.sort = sort
  }
}

/// Everything of the utilities the screens read, as one value of the dataset.
public struct UtilityBook: Hashable, Sendable, Codable {
  public var meters: [UtilityMeter]
  public var readings: [UtilityReading]
  public var bills: [UtilityBill]
  public var charges: [UtilityCharge]

  public init(
    meters: [UtilityMeter] = [], readings: [UtilityReading] = [], bills: [UtilityBill] = [],
    charges: [UtilityCharge] = []
  ) {
    self.meters = meters
    self.readings = readings
    self.bills = bills
    self.charges = charges
  }

  public var isEmpty: Bool {
    meters.isEmpty && readings.isEmpty && bills.isEmpty && charges.isEmpty
  }
}
