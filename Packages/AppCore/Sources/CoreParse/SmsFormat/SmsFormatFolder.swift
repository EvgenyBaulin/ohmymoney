import CoreKit
import Foundation

/// One file read from the folder, by its path below the folder.
public struct SmsFolderFile: Sendable {
  public var path: String
  public var data: Data

  public init(path: String, data: Data) {
    self.path = path
    self.data = data
  }
}

/// A file left out, and why.
public struct SmsFolderSkip: Hashable, Sendable, Identifiable {
  public var path: String
  public var problems: [SmsFormatProblem]
  public var id: String { path }
}

/// A bank's own category of cashback and the merchant codes it covers: a purchase counts when its
/// code is in `includeMCC` (or the list is empty) and not in `excludeMCC`.
public struct BankCashbackCategory: Hashable, Sendable {
  public var bank: String
  public var category: String
  public var unifiedCategory: String?
  public var includeMCC: [Int]
  public var excludeMCC: [Int]

  public func covers(mcc: Int) -> Bool {
    !excludeMCC.contains(mcc) && (includeMCC.isEmpty || includeMCC.contains(mcc))
  }
}

/// What a folder holds, once read.
public struct SmsFolderContents: Sendable {
  public var entries: [SmsFormatEntry] = []
  public var categories: [BankCashbackCategory] = []
  public var skipped: [SmsFolderSkip] = []
  /// Folders of banks that gave at least one format or category.
  public var bankCount = 0
}

/// Reads a folder the owner chose and laid out by banks:
///
///     <bank>/senders.txt                  one sender per line
///     <bank>/formats/<name>.txt           a format (`SmsFormat`)
///     <bank>/categories/<name>.json       `category`, `unified_category`, `include_mcc`,
///                                         `exclude_mcc`
///
/// The app ships none of it and never fetches it. A file that cannot be used is skipped with the
/// reason; the rest still count.
public enum SmsFormatFolder {
  public static func read(files: [SmsFolderFile]) -> SmsFolderContents {
    var contents = SmsFolderContents()
    var byBank: [String: [SmsFolderFile]] = [:]
    for file in files.sorted(by: { $0.path < $1.path }) {
      let parts = file.path.split(separator: "/").map(String.init)
      guard parts.count >= 2 else { continue }
      byBank[parts[0], default: []].append(file)
    }
    for bank in byBank.keys.sorted() {
      let bankFiles = byBank[bank] ?? []
      let name = bankName(of: bank)
      var senders: [String] = []
      var accepted: [SmsFormat] = []
      var found = false
      for file in bankFiles {
        let parts = file.path.split(separator: "/").map(String.init)
        let last = parts.last ?? ""
        if parts.count == 2, last == "senders.txt" {
          guard let text = String(data: file.data, encoding: .utf8) else {
            contents.skipped.append(SmsFolderSkip(path: file.path, problems: [.badSenders]))
            continue
          }
          senders = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        } else if parts.count == 3, parts[1] == "formats", last.hasSuffix(".txt") {
          guard let text = String(data: file.data, encoding: .utf8) else {
            contents.skipped.append(SmsFolderSkip(path: file.path, problems: [.notText]))
            continue
          }
          let id = "folder." + file.path.dropLast(4)
          switch SmsFormat.parse(fileText: text, id: id) {
          case .failure(let problem):
            contents.skipped.append(SmsFolderSkip(path: file.path, problems: [problem]))
          case .success(var format):
            // Banks of the folder are the folder's, whatever the file says.
            format.bank = .unknown
            // Compared with the ones accepted before it: the later of two that clash is the one
            // left out.
            let problems = SmsFormatValidator.problems(of: format, among: accepted)
            if problems.isEmpty {
              accepted.append(format)
              found = true
            } else {
              contents.skipped.append(SmsFolderSkip(path: file.path, problems: problems))
            }
          }
        } else if parts.count == 3, parts[1] == "categories", last.hasSuffix(".json") {
          if let read = categories(in: file.data, bank: name) {
            contents.categories += read
            found = found || !read.isEmpty
          } else {
            contents.skipped.append(SmsFolderSkip(path: file.path, problems: [.badCategoryFile]))
          }
        }
      }
      for format in accepted {
        if let entry = SmsFormatEntry(
          format, source: .folder, senders: senders, bankName: name)
        {
          contents.entries.append(entry)
        }
      }
      if found { contents.bankCount += 1 }
    }
    return contents
  }

  /// `sber_12` → `sber`: the digits after the last underscore are the folder's number.
  static func bankName(of folder: String) -> String {
    guard let cut = folder.lastIndex(of: "_"),
      folder[folder.index(after: cut)...].allSatisfy(\.isNumber),
      folder.index(after: cut) != folder.endIndex
    else { return folder }
    return String(folder[..<cut])
  }

  /// The categories of one file, an array or a single object; nil when it is not one.
  static func categories(in data: Data, bank: String) -> [BankCashbackCategory]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let items: [[String: Any]]
    if let array = object as? [[String: Any]] {
      items = array
    } else if let single = object as? [String: Any] {
      items = [single]
    } else {
      return nil
    }
    var out: [BankCashbackCategory] = []
    for item in items {
      guard let category = item["category"] as? String,
        !category.trimmingCharacters(in: .whitespaces).isEmpty,
        let include = codes(item["include_mcc"]), let exclude = codes(item["exclude_mcc"])
      else { return nil }
      out.append(
        BankCashbackCategory(
          bank: bank, category: category, unifiedCategory: item["unified_category"] as? String,
          includeMCC: include, excludeMCC: exclude))
    }
    return out
  }

  /// A list of merchant codes — numbers or numeric strings; absent is empty; nil when malformed.
  private static func codes(_ value: Any?) -> [Int]? {
    guard let value else { return [] }
    guard let list = value as? [Any] else { return nil }
    var out: [Int] = []
    for item in list {
      if let number = item as? Int, (0...9999).contains(number) {
        out.append(number)
      } else if let text = item as? String, let number = Int(text), (0...9999).contains(number) {
        out.append(number)
      } else {
        return nil
      }
    }
    return out
  }
}
