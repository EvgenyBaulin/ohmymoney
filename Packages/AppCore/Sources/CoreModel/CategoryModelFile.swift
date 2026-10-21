import CoreArchive
import CoreKit
import Foundation

/// The model on disk, in a portable format: JSON with the weights and the vocabulary of
/// features.
///
/// Every number in the file is an integer, and every list is written in a fixed order, so the
/// same examples produce the same bytes — on macOS, on Linux, and later on Windows. That is
/// not tidiness: it is what lets the file be checked by its checksum at all.
///
/// The file is a cache. The truth is the database, and a file that fails any of the checks
/// below is refused and the model trained again from the operations. A refused file is left
/// alone rather than deleted: deleting the owner's file to hide a defect is worse than
/// leaving it.
public enum CategoryModelFile {
  public static let format = "io.github.EvgenyBaulin.ohmymoney.category-model"
  /// A model larger than this is not one of ours, and is not read into memory to find out.
  public static let maximumBytes = 16 * 1024 * 1024

  public enum Refusal: String, Error, Equatable, Sendable {
    case notOurFormat
    case anotherFormatVersion
    case anotherFeatureVersion
    case anotherSetOfOptions
    case unreadable
    case tooLarge
    case countsDoNotAddUp
    case negativeWeight
  }

  public static func data(of model: CategoryModel, trainedAt: Date) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(Payload(model: model, trainedAt: trainedAt))
  }

  /// Lower-case hex, the spelling the archive already uses.
  public static func checksum(of data: Data) -> String { SHA256.hexDigest(data) }

  public static func model(
    from data: Data, expecting options: CategoryModelOptions = .standard
  ) throws -> CategoryModel {
    guard data.count <= maximumBytes else { throw Refusal.tooLarge }
    guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
      throw Refusal.unreadable
    }
    guard header.format == format else { throw Refusal.notOurFormat }
    guard header.formatVersion == CategoryModel.formatVersion else {
      throw Refusal.anotherFormatVersion
    }
    guard header.featureVersion == CategoryFeatures.version else {
      throw Refusal.anotherFeatureVersion
    }
    guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
      throw Refusal.unreadable
    }
    guard payload.options == options else { throw Refusal.anotherSetOfOptions }
    return try payload.model()
  }

  // MARK: The shape on disk

  struct ClassWeight: Codable, Sendable {
    var id: String
    var weight: Int64
  }

  struct ClassRow: Codable, Sendable {
    var id: String
    var documents: Int
    var weight: Int64
    var featureTotal: Int64
  }

  struct FeatureRow: Codable, Sendable {
    var key: String
    var byClass: [ClassWeight]
  }

  struct ExactRow: Codable, Sendable {
    var key: String
    /// Sightings of this key, whenever they were (format 2).
    var documents: Int
    var byClass: [ClassWeight]
  }

  /// What is read first, so a file of another version is refused as one rather than as
  /// unreadable because a field of this version is missing from it.
  struct Header: Decodable, Sendable {
    var format: String
    var formatVersion: Int
    var featureVersion: Int
  }

  struct Payload: Codable, Sendable {
    var format: String
    var formatVersion: Int
    var featureVersion: Int
    var trainedAt: String
    var anchorDay: DateOnly
    var options: CategoryModelOptions
    var documents: Int
    var classes: [ClassRow]
    var features: [FeatureRow]
    var exact: [ExactRow]

    init(model: CategoryModel, trainedAt: Date) {
      self.format = CategoryModelFile.format
      self.formatVersion = CategoryModel.formatVersion
      self.featureVersion = CategoryFeatures.version
      self.trainedAt = LogStampFreeISO.text(of: trainedAt)
      self.anchorDay = model.anchorDay
      self.options = model.options
      self.documents = model.documents
      self.classes = model.classDocuments.keys.sorted { $0.uuidString < $1.uuidString }
        .map { id in
          ClassRow(
            id: id.uuidString, documents: model.classDocuments[id] ?? 0,
            weight: model.classWeight[id] ?? 0, featureTotal: model.featureTotal[id] ?? 0)
        }
      self.features = model.featureWeight.keys.sorted().map { key in
        FeatureRow(key: key, byClass: CategoryModelFile.sorted(model.featureWeight[key] ?? [:]))
      }
      self.exact = model.exact.keys.sorted().map { key in
        let entry = model.exact[key]
        return ExactRow(
          key: key, documents: entry?.documents ?? 0,
          byClass: CategoryModelFile.sorted(entry?.byClass ?? [:]))
      }
    }

    func model() throws -> CategoryModel {
      var model = CategoryModel(options: options, anchorDay: anchorDay)
      var documentsByClass: [UUID: Int] = [:]
      var weightByClass: [UUID: Int64] = [:]
      var totalByClass: [UUID: Int64] = [:]
      for row in classes {
        guard let id = UUID(uuidString: row.id) else { throw Refusal.unreadable }
        guard row.documents >= 0, row.weight >= 0, row.featureTotal >= 0 else {
          throw Refusal.negativeWeight
        }
        documentsByClass[id] = row.documents
        weightByClass[id] = row.weight
        totalByClass[id] = row.featureTotal
      }
      guard documentsByClass.values.reduce(0, +) == documents else {
        throw Refusal.countsDoNotAddUp
      }

      var featureWeight: [String: [UUID: Int64]] = [:]
      var summed: [UUID: Int64] = [:]
      for row in features {
        var byClass: [UUID: Int64] = [:]
        for entry in row.byClass {
          guard let id = UUID(uuidString: entry.id) else { throw Refusal.unreadable }
          guard entry.weight >= 0 else { throw Refusal.negativeWeight }
          guard documentsByClass[id] != nil else { throw Refusal.countsDoNotAddUp }
          byClass[id] = entry.weight
          summed[id, default: 0] += entry.weight
        }
        featureWeight[row.key] = byClass
      }
      guard summed == totalByClass.filter({ $0.value != 0 }) else {
        throw Refusal.countsDoNotAddUp
      }

      var exactEntries: [String: CategoryModel.Exact] = [:]
      var sightings = 0
      for row in exact {
        var byClass: [UUID: Int64] = [:]
        for entry in row.byClass {
          guard let id = UUID(uuidString: entry.id) else { throw Refusal.unreadable }
          guard entry.weight >= 0 else { throw Refusal.negativeWeight }
          byClass[id] = entry.weight
        }
        // Every sighting is one example, and an example has at most one exact key.
        guard row.documents > 0 else { throw Refusal.countsDoNotAddUp }
        sightings += row.documents
        exactEntries[row.key] = CategoryModel.Exact(byClass: byClass, documents: row.documents)
      }
      guard sightings <= documents else { throw Refusal.countsDoNotAddUp }

      model.restore(
        documents: documents, classDocuments: documentsByClass, classWeight: weightByClass,
        featureWeight: featureWeight, featureTotal: totalByClass, exact: exactEntries)
      return model
    }
  }

  static func sorted(_ byClass: [UUID: Int64]) -> [ClassWeight] {
    byClass.keys.sorted { $0.uuidString < $1.uuidString }
      .map { ClassWeight(id: $0.uuidString, weight: byClass[$0] ?? 0) }
  }
}

/// The moment a model was trained, written the way the journal writes a moment but without
/// dragging the journal in: this file has no business depending on `CoreLog`.
enum LogStampFreeISO {
  static func text(of date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
  }
}

extension CategoryModel {
  /// Only the file reader uses this: a model read back is not learned, it is restored.
  mutating func restore(
    documents: Int, classDocuments: [UUID: Int], classWeight: [UUID: Int64],
    featureWeight: [String: [UUID: Int64]], featureTotal: [UUID: Int64],
    exact: [String: Exact]
  ) {
    self.documents = documents
    self.classDocuments = classDocuments
    self.classWeight = classWeight
    self.featureWeight = featureWeight
    self.featureTotal = featureTotal
    self.exact = exact
  }
}
