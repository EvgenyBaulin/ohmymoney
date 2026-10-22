import CoreAnalytics
import CoreKit
import CoreParse
import Foundation

extension QuestionCatalog {
  /// The names of a snapshot, archived ones included: an archived category still has
  /// operations to ask about.
  public init(dataset: Dataset) {
    self.init(
      categories: dataset.categories.map {
        QuestionName(id: $0.id, name: $0.name, parentId: $0.parentId, kind: $0.kind)
      },
      places: dataset.places.map { QuestionName(id: $0.id, name: $0.name) },
      people: dataset.people.map { QuestionName(id: $0.id, name: $0.name) },
      events: dataset.events.map { QuestionName(id: $0.id, name: $0.name) },
      paymentMethods: dataset.paymentMethods.map { QuestionName(id: $0.id, name: $0.name) })
  }
}

/// One call from a line of text to an answer, for the question mode of the entry line and
/// for the palette: parse, settle the terms against the catalogue, count.
public struct QuestionDesk: Sendable {
  public let answerer: QuestionAnswerer
  public let catalog: QuestionCatalog

  public init(ledger: Ledger, today: DateOnly) {
    self.answerer = QuestionAnswerer(ledger: ledger, today: today)
    self.catalog = QuestionCatalog(dataset: ledger.dataset)
  }

  public func resolve(_ text: String) -> Result<ResolvedQuestion, QuestionFailure> {
    QuestionParser.parse(text, today: answerer.today).map {
      QuestionResolver.resolve($0, in: catalog)
    }
  }

  public func ask(_ text: String) -> Result<QuestionAnswer, QuestionFailure> {
    resolve(text).map(answerer.answer)
  }
}
