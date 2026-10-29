import AppCore
import AppDatabase
import Foundation

/// The answers to «Как прошла неделя?» in the table `week_answers` of the database, through the
/// repository of the attachments, which owns that table. They travel with the database and the
/// archive, and are not in the CSV.
struct DatabaseWeekAnswers: WeekAnswerStore {
  let repository: AttachmentRepository

  func answers() async throws -> [WeekMood] {
    try repository.answers().compactMap { answer in
      WeekKey(iso: answer.week).map {
        WeekMood(week: $0, mood: answer.mood, answeredAt: answer.answeredAt)
      }
    }
  }

  func save(_ answer: WeekMood) async throws {
    try repository.save(
      WeekAnswer(week: answer.week.iso, mood: answer.mood, answeredAt: answer.answeredAt))
  }

  /// The store of the open database; `nil` while it is not open.
  @MainActor
  static func current(_ environment: AppEnvironment) -> DatabaseWeekAnswers? {
    environment.stack.map {
      DatabaseWeekAnswers(repository: AttachmentRepository(writer: $0.writer))
    }
  }
}

/// A store that keeps the answers in memory: the trial sets and the tests.
actor MemoryWeekAnswers: WeekAnswerStore {
  private var stored: [WeekKey: WeekMood] = [:]

  init(_ answers: [WeekMood] = []) {
    for answer in answers { stored[answer.week] = answer }
  }

  func answers() async throws -> [WeekMood] { stored.values.sorted { $0.week < $1.week } }
  func save(_ answer: WeekMood) async throws { stored[answer.week] = answer }
}
