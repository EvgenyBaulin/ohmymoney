import Testing

@testable import CoreKit

/// How a new operation is filled in: the line, or the form at the side — kept as one word.
@Suite("The style of the entry")
struct EntryStyleTests {
  @Test func theStandardStyleIsTheLine() {
    #expect(EntryStyle.standard == .line)
    #expect(EntryStyle(stored: nil) == .line)
  }

  @Test func aStoredWordIsReadBack() {
    #expect(EntryStyle(stored: "form") == .form)
    #expect(EntryStyle(stored: "line") == .line)
  }

  /// A word another build wrote, or none at all, is the standard style: an archive of another
  /// Mac never leaves the owner without a way to enter operations.
  @Test func anUnknownWordIsTheStandardStyle() {
    for stored in ["", "panel", "FORM", " form", "1"] {
      #expect(EntryStyle(stored: stored) == .line, "«\(stored)»")
    }
  }

  /// The words are the contract of the setting and of the archive.
  @Test func theRawValuesAreTheContract() {
    #expect(EntryStyle.allCases.map(\.rawValue) == ["line", "form"])
  }

  @Test func onlyTheLineAssists() {
    #expect(EntryStyle.line.assists)
    #expect(!EntryStyle.form.assists)
  }
}
