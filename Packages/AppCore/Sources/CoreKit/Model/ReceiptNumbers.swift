import Foundation

/// The fiscal numbers of a Russian cash receipt kept on the operation it was recorded as: the
/// fiscal drive (`fn`), the number of the document on it (`i`, «ФД»), the fiscal sign (`fp`,
/// «ФП») and the kind of settlement (`n`).
///
/// The numbers are kept as decimal digits without leading zeros. The QR code of a receipt writes
/// `i` and `fp` without them and the paper prints them with, so the same receipt read from either
/// is the same text here: they compare as numbers.
public struct ReceiptNumbers: Hashable, Sendable, Codable {
  public var fiscalDrive: String
  public var documentNumber: String
  /// `nil`: the code carried none.
  public var fiscalSign: String?
  /// The `n` of the code: 1 a sale, 2 a refund of a sale, 3 a payout, 4 a refund of a payout;
  /// `nil`: none read.
  public var operation: Int?

  /// `nil` when the drive or the document number is missing or is not a number: such a receipt
  /// has no key and is never taken for one already recorded.
  public init?(
    fiscalDrive: String?, documentNumber: String?, fiscalSign: String? = nil,
    operation: Int? = nil
  ) {
    guard let drive = fiscalDrive.flatMap(Self.canonical),
      let document = documentNumber.flatMap(Self.canonical)
    else { return nil }
    self.fiscalDrive = drive
    self.documentNumber = document
    self.fiscalSign = fiscalSign.flatMap(Self.canonical)
    self.operation = operation
  }

  /// The digits of a number without its leading zeros (`"0000000042"` → `"42"`, `"000"` → `"0"`);
  /// `nil` for an empty text or one with anything but ASCII digits. Surrounding spaces are
  /// dropped.
  public static func canonical(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count <= 40,
      trimmed.allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    let stripped = trimmed.drop { $0 == "0" }
    return stripped.isEmpty ? "0" : String(stripped)
  }

  /// Whether the two are one receipt: the same drive and document, and — when both carry a
  /// fiscal sign — the same sign. Two signs that differ under one key are two different
  /// documents (or one misread code), and neither is taken for the other.
  public func isSameReceipt(as other: ReceiptNumbers) -> Bool {
    guard fiscalDrive == other.fiscalDrive, documentNumber == other.documentNumber else {
      return false
    }
    if let fiscalSign, let theirs = other.fiscalSign { return fiscalSign == theirs }
    return true
  }
}
