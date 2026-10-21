import CoreKit
import Foundation
import Testing

@testable import CoreModel

/// The model on disk. It is a cache — the truth is the database — so the only thing that
/// matters here is that a file is either exactly what was written or refused.
@Suite("The model on disk")
struct CategoryModelFileTests {
  private let anchor = DateOnly(year: 2026, month: 9, day: 20)
  private let trainedAt = Date(timeIntervalSince1970: 1_789_000_000)
  private let groceries = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  private let transport = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

  private func examples(count: Int) -> [CategoryExample] {
    (0..<count).map(example(at:))
  }

  /// One step at a time, each with its type written out: as one expression inside `map`, the
  /// Swift 6.1 of the Linux job gave up on it («unable to type-check this expression in
  /// reasonable time», the first run of CI, 21.09), while Swift 6.4 took 7 ms.
  private func example(at index: Int) -> CategoryExample {
    let groceriesTurn: Bool = index % 2 == 0
    let day: Int = 1 + index % 19
    let weekday: Int = 1 + index % 7
    let text: String = groceriesTurn ? "продукты \(index % 4)" : "такси \(index % 3)"
    let amount: Int64 = Int64(100 + index * 13)
    let query = CategoryQuery(
      day: DateOnly(year: 2026, month: 9, day: day), weekday: weekday, kind: .expense,
      text: text, amountWhole: amount)
    return CategoryExample(
      query: query, partId: UUID(), categoryId: groceriesTurn ? groceries : transport)
  }

  private func model() -> CategoryModel {
    CategoryModel.train(on: examples(count: 60), anchor: anchor)
  }

  @Test func aModelSurvivesGoingToDiskAndBack() throws {
    let before = model()
    let after = try CategoryModelFile.model(
      from: try CategoryModelFile.data(of: before, trainedAt: trainedAt))

    #expect(before == after)
  }

  /// The same examples in any order give the same file, to the byte. Without that the
  /// checksum would mean nothing.
  @Test func theSameExamplesGiveTheSameBytesWhateverOrderTheyCameIn() throws {
    let forwards = CategoryModel.train(on: examples(count: 60), anchor: anchor)
    let backwards = CategoryModel.train(on: examples(count: 60).reversed(), anchor: anchor)

    #expect(
      try CategoryModelFile.data(of: forwards, trainedAt: trainedAt)
        == CategoryModelFile.data(of: backwards, trainedAt: trainedAt))
  }

  @Test func theFileHoldsNoFloatingPointAtAll() throws {
    let text = String(
      data: try CategoryModelFile.data(of: model(), trainedAt: trainedAt), encoding: .utf8)
    let json = try #require(text)

    // Not «no dots» — the format's own name has them, and so do feature keys — but no
    // number written as a fraction or in exponent form. Such a number would not mean the same
    // thing on every platform, and the whole file rests on meaning exactly one thing.
    let fraction = try NSRegularExpression(pattern: "[:\\[,]\\s*-?\\d+[.eE]")
    let range = NSRange(json.startIndex..., in: json)
    #expect(
      fraction.numberOfMatches(in: json, range: range) == 0,
      "a fraction in the file would not mean the same everywhere")
  }

  // MARK: What is refused

  @Test func aFileOfAnotherFormatIsRefused() throws {
    var data = try CategoryModelFile.data(of: model(), trainedAt: trainedAt)
    data = Data(
      String(data: data, encoding: .utf8)!
        .replacingOccurrences(of: CategoryModelFile.format, with: "something.else").utf8)

    #expect(throws: CategoryModelFile.Refusal.notOurFormat) {
      try CategoryModelFile.model(from: data)
    }
  }

  @Test func aFileFromAnotherSetOfFeaturesIsRefused() throws {
    let data = try CategoryModelFile.data(of: model(), trainedAt: trainedAt)
    let bumped = Data(
      String(data: data, encoding: .utf8)!
        .replacingOccurrences(
          of: "\"featureVersion\":\(CategoryFeatures.version)",
          with: "\"featureVersion\":\(CategoryFeatures.version + 1)"
        ).utf8)

    #expect(throws: CategoryModelFile.Refusal.anotherFeatureVersion) {
      try CategoryModelFile.model(from: bumped)
    }
  }

  @Test func aFileTrainedWithOtherNumbersIsRefused() throws {
    var options = CategoryModelOptions.standard
    options.halfLifeDays = 90
    let other = CategoryModel.train(on: examples(count: 60), anchor: anchor, options: options)
    let data = try CategoryModelFile.data(of: other, trainedAt: trainedAt)

    #expect(throws: CategoryModelFile.Refusal.anotherSetOfOptions) {
      try CategoryModelFile.model(from: data, expecting: .standard)
    }
  }

  @Test func aFileWhoseCountsDoNotAddUpIsRefused() throws {
    let data = try CategoryModelFile.data(of: model(), trainedAt: trainedAt)
    let tampered = Data(
      String(data: data, encoding: .utf8)!
        .replacingOccurrences(of: "\"documents\":60", with: "\"documents\":61").utf8)

    #expect(throws: CategoryModelFile.Refusal.countsDoNotAddUp) {
      try CategoryModelFile.model(from: tampered)
    }
  }

  /// A file of format 1 has no count of sightings in its exact rows. It is refused as a file
  /// of another version — read first — not as unreadable, and the model is trained again.
  @Test func aFileOfTheFirstVersionIsRefusedAsOne() throws {
    let text = try #require(
      String(data: try CategoryModelFile.data(of: model(), trainedAt: trainedAt), encoding: .utf8))
    #expect(text.contains("\"documents\":"))
    let first =
      text
      .replacingOccurrences(
        of: "\"formatVersion\":\(CategoryModel.formatVersion)", with: "\"formatVersion\":1"
      )
      .replacingOccurrences(
        of: "\"documents\":\\d+,\"key\"", with: "\"key\"", options: .regularExpression)

    #expect(throws: CategoryModelFile.Refusal.anotherFormatVersion) {
      try CategoryModelFile.model(from: Data(first.utf8))
    }
  }

  /// Every exact entry was seen at least once, and there are no more sightings than examples.
  @Test func anExactEntryWithoutSightingsIsRefused() throws {
    let text = try #require(
      String(data: try CategoryModelFile.data(of: model(), trainedAt: trainedAt), encoding: .utf8))
    for count in ["0", "1000"] {
      let tampered = text.replacingOccurrences(
        of: "\"documents\":\\d+,\"key\"", with: "\"documents\":\(count),\"key\"",
        options: .regularExpression)
      #expect(throws: CategoryModelFile.Refusal.countsDoNotAddUp, "\(count)") {
        try CategoryModelFile.model(from: Data(tampered.utf8))
      }
    }
  }

  @Test func somethingThatIsNotAModelAtAllIsRefused() {
    #expect(throws: CategoryModelFile.Refusal.unreadable) {
      try CategoryModelFile.model(from: Data("not json".utf8))
    }
  }

  /// A flipped byte is what the checksum in `ml_models` is for; here it is enough that the
  /// digest of a changed file is a different digest.
  @Test func theChecksumChangesWithTheFile() throws {
    var data = try CategoryModelFile.data(of: model(), trainedAt: trainedAt)
    let before = CategoryModelFile.checksum(of: data)
    data[data.count / 2] ^= 0xFF

    #expect(CategoryModelFile.checksum(of: data) != before)
  }
}
