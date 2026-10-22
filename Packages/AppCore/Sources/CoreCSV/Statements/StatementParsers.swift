import CoreKit
import Foundation

/// Reads statements. A file is recognised by what is inside it, never by its name; the
/// matching profile says how to read it. Nothing here touches a database: the result is a
/// plain value that a preview screen shows before anything is written.
public enum StatementImporter {
  /// The profile whose required headers are all present in `headerRow`, or `nil`. When
  /// several fit, the one that asks for more headers wins (the more specific format).
  public static func detect(
    headerRow: [String], profiles: [StatementProfile] = StatementProfiles.all
  ) -> StatementProfile? {
    let names = Set(headerRow.map(StatementText.collapse))
    var best: (profile: StatementProfile, size: Int)?
    for profile in profiles {
      guard case .delimited(let layout) = profile.layout else { continue }
      guard layout.requiredHeaders.allSatisfy({ names.contains($0) }) else { continue }
      if best == nil || layout.requiredHeaders.count > best!.size {
        best = (profile, layout.requiredHeaders.count)
      }
    }
    return best?.profile
  }

  /// The profile for the text layer of a PDF statement, from its first page: every
  /// signature fragment of the profile must occur (case does not matter).
  public static func detect(
    textLines lines: [String], profiles: [StatementProfile] = StatementProfiles.all
  ) -> StatementProfile? {
    let firstPage = lines.prefix(120).joined(separator: "\n").uppercased()
    for profile in profiles {
      guard case .pdfText(let layout) = profile.layout else { continue }
      if layout.signatureFragments.allSatisfy({ firstPage.contains($0.uppercased()) }) {
        return profile
      }
    }
    return nil
  }

  /// Reads a CSV file of any known format.
  public static func parseCSV(
    _ data: Data, profiles: [StatementProfile] = StatementProfiles.all
  ) -> StatementOutcome {
    let decoded = StatementTextDecoder.decode(data)
    guard !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .unreadable
    }
    let firstLine = decoded.text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
    var firstCells: [String] = []
    var recognised: StatementProfile?
    var tried = Set<String>()
    for profile in profiles {
      guard case .delimited(let layout) = profile.layout,
        let delimiter = layout.delimiter.unicodeScalars.first,
        tried.insert(layout.delimiter).inserted
      else { continue }
      let cells =
        StatementDelimitedReader.rows(in: String(firstLine), delimiter: delimiter).first ?? []
      if firstCells.isEmpty { firstCells = cells }
      if let found = detect(
        headerRow: cells,
        profiles: profiles.filter {
          if case .delimited(let other) = $0.layout { return other.delimiter == layout.delimiter }
          return false
        })
      {
        recognised = found
        break
      }
    }
    guard let profile = recognised, case .delimited(let layout) = profile.layout,
      let result = StatementCSVParser.parse(
        text: decoded.text, usedLegacyEncoding: decoded.usedLegacyEncoding, profile: profile,
        layout: layout)
    else {
      let hint = firstCells.prefix(12).map { String($0.prefix(60)) }
      return .unknownFormat(headerHint: hint)
    }
    return .parsed(result)
  }

  /// Reads the text layer of a PDF statement (already extracted, one string per line).
  public static func parsePDFText(
    _ lines: [String], profiles: [StatementProfile] = StatementProfiles.all
  ) -> StatementOutcome {
    guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
      return .unreadable
    }
    guard let profile = detect(textLines: lines, profiles: profiles),
      case .pdfText(let layout) = profile.layout
    else {
      let hint = lines.lazy.map(StatementText.collapse).filter { !$0.isEmpty }.prefix(1).map {
        String($0.prefix(60))
      }
      return .unknownFormat(headerHint: Array(hint))
    }
    return .parsed(StatementPDFTextParser.parse(lines: lines, profile: profile, layout: layout))
  }

  public static func parsePDFText(
    text: String, profiles: [StatementProfile] = StatementProfiles.all
  ) -> StatementOutcome {
    parsePDFText(
      text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"),
      profiles: profiles)
  }
}

// MARK: - Delimited statements

enum StatementCSVParser {
  static func parse(
    text: String, usedLegacyEncoding: Bool, profile: StatementProfile,
    layout: StatementDelimitedLayout
  ) -> StatementParseResult? {
    guard let delimiter = layout.delimiter.unicodeScalars.first else { return nil }
    let rows = StatementDelimitedReader.rows(in: text, delimiter: delimiter)
    guard let headerRow = rows.first else { return nil }
    let names = headerRow.map(StatementText.collapse)
    guard layout.requiredHeaders.allSatisfy({ names.contains($0) }) else { return nil }
    var indexByName: [String: Int] = [:]
    for (index, name) in names.enumerated() where indexByName[name] == nil {
      indexByName[name] = index
    }

    func column(_ field: StatementField) -> Int? {
      layout.header(of: field).flatMap { indexByName[$0] }
    }
    let columns = Dictionary(
      uniqueKeysWithValues: StatementField.allCases.compactMap { field in
        column(field).map { (field, $0) }
      })
    let rules = StatementRuleSet(profile.descriptionRules)
    let hasDirection = !layout.debitWords.isEmpty && columns[.direction] != nil
    let split = layout.amountStyle == .splitIncomeExpense
    let currencyCode: (String) -> CurrencyCode = { text in
      let upper = StatementText.collapse(text).uppercased()
      return upper.isEmpty ? .rub : CurrencyCode(upper)
    }

    var result = StatementParseResult(
      profileID: profile.id, header: StatementHeader(), operations: [], declined: [],
      unparsed: [], checks: [], usedLegacyEncoding: usedLegacyEncoding)
    var signViolations = 0
    var amountColumnViolations = 0

    for (offset, row) in rows.dropFirst().enumerated() {
      guard row.count == names.count else {
        result.unparsed.append(
          StatementUnparsedLine(sourceIndex: offset, reason: .columnCountMismatch, amount: nil))
        continue
      }
      func cell(_ field: StatementField) -> String {
        columns[field].map { StatementText.collapse(row[$0]) } ?? ""
      }

      // Amount.
      var amount: AmountE4?
      var amountFailure: StatementUnparsedReason?
      var accountAmount: AmountE4?
      if split {
        let income = cell(.incomeAmount)
        let expense = cell(.expenseAmount)
        if income.isEmpty == expense.isEmpty {
          amountFailure = .amountColumnsConflict
          amountColumnViolations += 1
        } else if let parsed = StatementAmount.parse(income.isEmpty ? expense : income) {
          amount = income.isEmpty ? -parsed.magnitude : parsed.magnitude
        } else {
          amountFailure = .badAmount
        }
        let accountIncome = cell(.accountIncomeAmount)
        let accountExpense = cell(.accountExpenseAmount)
        if accountIncome.isEmpty != accountExpense.isEmpty,
          let parsed = StatementAmount.parse(accountIncome.isEmpty ? accountExpense : accountIncome)
        {
          accountAmount = accountIncome.isEmpty ? -parsed.magnitude : parsed.magnitude
        }
      } else {
        let text = cell(.amount)
        if let parsed = StatementAmount.parse(text) {
          amount = parsed
        } else {
          amountFailure = .badAmount
        }
        accountAmount = StatementAmount.parse(cell(.accountAmount))
      }
      guard let moment = StatementDateText.moment(cell(.moment)) else {
        result.unparsed.append(
          StatementUnparsedLine(sourceIndex: offset, reason: .badDate, amount: amount))
        continue
      }
      guard let signed = amount else {
        result.unparsed.append(
          StatementUnparsedLine(
            sourceIndex: offset, reason: amountFailure ?? .badAmount, amount: nil))
        continue
      }
      if hasDirection {
        let word = cell(.direction)
        let debit = layout.debitWords.contains(word)
        let credit = layout.creditWords.contains(word)
        if (debit && !signed.isNegative && !signed.isZero) || (credit && signed.isNegative) {
          signViolations += 1
          result.unparsed.append(
            StatementUnparsedLine(
              sourceIndex: offset, reason: .signContradictsDirection, amount: signed))
          continue
        }
      }

      // Status.
      let statusText = cell(.status).lowercased()
      let postedText = cell(.posted)
      let postedDay = StatementDateText.day(postedText)
      var status = StatementStatus.posted
      if layout.declinedMarkers.contains(where: { statusText.contains($0) }) {
        status = .declined
      } else if layout.pendingMarkers.contains(where: {
        statusText.contains($0) || postedText.lowercased().contains($0)
      }) {
        status = .pending
      } else if columns[.posted] != nil, postedDay == nil {
        status = .unknown
      }

      // Text.
      let description = layout.descriptionFields.compactMap { name -> String? in
        guard let field = StatementField(rawValue: name) else { return nil }
        let value = cell(field)
        return value.isEmpty ? nil : value
      }.joined(separator: " | ")
      let cardText = cell(.card)
      let cardDigits = StatementText.digits(cardText)
      var operation = ImportedOperation(
        profileID: profile.id, sourceIndex: offset, accountRef: cell(.account),
        cardTail: cardDigits.isEmpty ? nil : String(cardDigits.suffix(4)), moment: moment,
        postedOn: postedDay, status: status, amount: signed,
        currency: currencyCode(cell(.currency)), accountAmount: accountAmount,
        accountCurrency: cell(.accountCurrency).isEmpty
          ? nil : currencyCode(cell(.accountCurrency)),
        description: description)
      if let reading = rules.read(
        description, isIncome: !signed.isNegative, hasCard: !cardText.isEmpty)
      {
        operation.apply(reading)
      }
      let merchantColumn = cell(.merchant)
      if !merchantColumn.isEmpty { operation.merchant = StatementMerchant.clean(merchantColumn) }
      operation.mcc = nonEmpty(cell(.mcc))
      operation.bankCategory = nonEmpty(cell(.bankCategory))
      operation.comment = nonEmpty(cell(.comment))
      operation.documentID = nonEmpty(cell(.documentID))
      if let cashback = StatementAmount.parse(cell(.cashback)), !cashback.isZero {
        operation.cashbackAccrued = cashback.magnitude
      }
      if let fee = StatementAmount.parse(cell(.fee)), !fee.isZero {
        operation.feeAmount = fee.magnitude
      }
      if result.header.productName == nil { result.header.productName = nonEmpty(cell(.product)) }
      if result.header.accountNumber == nil {
        result.header.accountNumber = nonEmpty(cell(.account))
      }

      if status == .declined {
        result.declined.append(operation)
      } else {
        result.operations.append(operation)
      }
    }

    let days = result.operations.map(\.moment.day)
    result.header.periodFrom = days.min()
    result.header.periodTo = days.max()
    if hasDirection {
      result.checks.append(
        StatementCheck(
          kind: .signMatchesDirection, passed: signViolations == 0, blocking: false,
          violations: signViolations))
    }
    if split {
      result.checks.append(
        StatementCheck(
          kind: .oneAmountPerRow, passed: amountColumnViolations == 0, blocking: false,
          violations: amountColumnViolations))
    }
    return result
  }

  private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }
}

// MARK: - Text layer of PDF statements

enum StatementPDFTextParser {
  private struct Builder {
    var sourceIndex: Int
    var opDay: DateOnly?
    var postedDay: DateOnly?
    var amount: AmountE4?
    var currency: CurrencyCode
    var accountAmount: AmountE4?
    var accountCurrency: CurrencyCode
    var description: String
    var card: String
    var opMinute: Int?
  }

  static func parse(
    lines: [String], profile: StatementProfile, layout: StatementPDFTextLayout
  ) -> StatementParseResult {
    func regex(_ pattern: String) -> NSRegularExpression? {
      try? NSRegularExpression(pattern: pattern, options: [])
    }
    let rowRegex = regex(layout.rowPattern)
    let timeRegex = regex(layout.timePattern)
    let skipRegexes = layout.skipPatterns.compactMap(regex)
    let contractRegex = regex(layout.contractPattern)
    let accountRegex = regex(layout.accountPattern)
    let openedRegex = regex(layout.openedPattern)
    let periodRegex = regex(layout.periodPattern)
    let incomeRegex = regex(layout.footerIncomePattern)
    let expenseRegex = regex(layout.footerExpensePattern)
    let rowStart = regex(#"^\d{2}\.\d{2}\.\d{4}\s+\d{2}\.\d{2}\.\d{4}(?:\s|$)"#)
    let rules = StatementRuleSet(profile.descriptionRules)

    func group(_ regex: NSRegularExpression?, _ line: String, _ index: Int = 1) -> String? {
      guard let regex,
        let match = regex.firstMatch(
          in: line, options: [], range: NSRange(line.startIndex..., in: line)),
        match.numberOfRanges > index, match.range(at: index).location != NSNotFound,
        let range = Range(match.range(at: index), in: line)
      else { return nil }
      return String(line[range])
    }

    var header = StatementHeader()
    var built: [Builder] = []
    var current: Builder?
    var unparsed: [StatementUnparsedLine] = []

    func finish() {
      if let current { built.append(current) }
      current = nil
    }

    for (lineIndex, raw) in lines.enumerated() {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty { continue }

      // Head and foot facts can sit on any line.
      if header.contractNumber == nil { header.contractNumber = group(contractRegex, line) }
      if header.accountNumber == nil { header.accountNumber = group(accountRegex, line) }
      if header.openedOn == nil {
        header.openedOn = group(openedRegex, line).flatMap(StatementDateText.day)
      }
      if header.periodFrom == nil, let from = group(periodRegex, line, 1),
        let to = group(periodRegex, line, 2)
      {
        header.periodFrom = StatementDateText.day(from)
        header.periodTo = StatementDateText.day(to)
      }
      if let income = group(incomeRegex, line) {
        header.footerIncome = StatementAmount.parse(income)
        finish()
        continue
      }
      if let expense = group(expenseRegex, line) {
        header.footerExpense = StatementAmount.parse(expense)
        finish()
        continue
      }

      if let rowRegex,
        let match = rowRegex.firstMatch(
          in: line, options: [], range: NSRange(line.startIndex..., in: line))
      {
        finish()
        func piece(_ index: Int) -> String {
          Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
        current = Builder(
          sourceIndex: lineIndex, opDay: StatementDateText.day(piece(1)),
          postedDay: StatementDateText.day(piece(2)), amount: StatementAmount.parse(piece(3)),
          currency: StatementAmount.currency(forMark: piece(4)) ?? .rub,
          accountAmount: StatementAmount.parse(piece(5)),
          accountCurrency: StatementAmount.currency(forMark: piece(6)) ?? .rub,
          description: piece(7), card: piece(8), opMinute: nil)
        continue
      }
      if skipRegexes.contains(where: {
        $0.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) != nil
      }) {
        continue
      }
      if let rowStart,
        rowStart.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line))
          != nil
      {
        // Looks like the first line of an operation but the row pattern refuses it: counted
        // with the first amount that can be read, never skipped silently.
        finish()
        let amount = line.split(separator: " ").lazy.compactMap {
          StatementAmount.parse(String($0))
        }
        .first
        unparsed.append(
          StatementUnparsedLine(sourceIndex: lineIndex, reason: .unreadableLine, amount: amount))
        continue
      }
      guard var open = current else { continue }
      if open.opMinute == nil, let timeRegex,
        let match = timeRegex.firstMatch(
          in: line, options: [], range: NSRange(line.startIndex..., in: line)),
        let first = Range(match.range(at: 1), in: line)
      {
        open.opMinute = StatementDateText.minute(String(line[first]))
        if match.range(at: 3).location != NSNotFound, let rest = Range(match.range(at: 3), in: line)
        {
          open.description += " " + line[rest]
        }
      } else {
        open.description += " " + line
      }
      current = open
    }
    finish()

    var result = StatementParseResult(
      profileID: profile.id, header: header, operations: [], declined: [], unparsed: unparsed,
      checks: [], usedLegacyEncoding: false)
    for (position, item) in built.enumerated() {
      guard let day = item.opDay else {
        result.unparsed.append(
          StatementUnparsedLine(
            sourceIndex: item.sourceIndex, reason: .badDate, amount: item.amount))
        continue
      }
      guard let amount = item.amount else {
        result.unparsed.append(
          StatementUnparsedLine(sourceIndex: item.sourceIndex, reason: .badAmount, amount: nil))
        continue
      }
      let description = StatementText.collapse(item.description)
      var operation = ImportedOperation(
        profileID: profile.id, sourceIndex: position,
        accountRef: header.accountNumber ?? header.contractNumber ?? "",
        cardTail: item.card == "—" ? nil : item.card,
        moment: StatementMoment(day: day, minuteOfDay: item.opMinute), postedOn: item.postedDay,
        status: .posted, amount: amount, currency: item.currency,
        accountAmount: item.accountAmount, accountCurrency: item.accountCurrency,
        description: description)
      if let reading = rules.read(
        description, isIncome: !amount.isNegative, hasCard: item.card != "—")
      {
        operation.apply(reading)
      }
      result.operations.append(operation)
    }

    // The foot of the statement is the check of the text itself: what the lines add up to
    // must be what the bank printed, to the cent. A foot that is missing counts as failed.
    if let footerIncome = header.footerIncome, let footerExpense = header.footerExpense {
      let amounts = result.operations.map { $0.accountAmount ?? $0.amount }
      let income = AmountE4.sum(amounts.filter { !$0.isNegative })
      let expense = AmountE4.sum(amounts.filter(\.isNegative).map { $0.magnitude })
      result.checks.append(
        StatementCheck(
          kind: .footerTotals, passed: income == footerIncome && expense == footerExpense,
          blocking: true, missingIncome: footerIncome - income,
          missingExpense: footerExpense - expense))
    } else {
      result.checks.append(
        StatementCheck(kind: .footerTotals, passed: false, blocking: true, violations: 1))
    }
    if let from = header.periodFrom, let to = header.periodTo {
      let outside = result.operations.filter { $0.moment.day < from || $0.moment.day > to }.count
      result.checks.append(
        StatementCheck(
          kind: .datesInPeriod, passed: outside == 0, blocking: false, violations: outside))
    }
    return result
  }
}
