import Foundation
import Observation

/// A failed dictation never prevents editing or saving the entry line.
enum EntryDictationState: Equatable, Sendable {
  case idle, listening, denied, unavailable

  var hintKey: String? {
    switch self {
    case .idle: nil
    case .listening: "entry.dictation.listening"
    case .denied: "entry.dictation.denied"
    case .unavailable: "entry.dictation.unavailable"
    }
  }
}

enum EntryDictationEvent: Sendable {
  case transcript(String, isFinal: Bool)
  case unavailable
}

enum EntryDictationError: Error {
  case unavailable
}

/// Only this boundary knows about the microphone and the system speech recognizer.
@MainActor
protocol EntrySpeechRecognizing: AnyObject {
  func isAvailable(localeIdentifier: String) -> Bool
  func authorize() async -> Bool
  func start(
    localeIdentifier: String,
    receive: @escaping @MainActor @Sendable (EntryDictationEvent) -> Void
  ) throws
  func stop()
}

/// Injected so silence can be tested without waiting for a wall clock or using a microphone.
@MainActor
protocol EntryDictationPauseScheduling: AnyObject {
  func schedule(after delay: Duration, action: @escaping @MainActor () -> Void)
  func cancel()
}

@MainActor
final class EntryDictationPause: EntryDictationPauseScheduling {
  private var task: Task<Void, Never>?

  func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
    cancel()
    task = Task {
      do { try await Task.sleep(for: delay) } catch { return }
      guard !Task.isCancelled else { return }
      action()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  deinit { task?.cancel() }
}

/// Partial hypotheses replace only the words of this session, preserving the typed prefix.
/// A keyboard edit ends dictation before a late hypothesis can overwrite it.
@MainActor
@Observable
final class EntryDictation {
  private(set) var state: EntryDictationState = .idle
  private(set) var isActive = false

  @ObservationIgnored private let speech: any EntrySpeechRecognizing
  @ObservationIgnored private let pause: any EntryDictationPauseScheduling
  @ObservationIgnored private var authorizationTask: Task<Bool, Never>?
  @ObservationIgnored private var session: UUID?
  @ObservationIgnored private var prefix = ""
  @ObservationIgnored private var lastLine = ""
  @ObservationIgnored private var lastTranscript = ""
  @ObservationIgnored private var readLine: (@MainActor () -> String)?
  @ObservationIgnored private var writeLine: (@MainActor (String) -> Void)?

  init(
    speech: any EntrySpeechRecognizing = OnDeviceEntrySpeech(),
    pause: any EntryDictationPauseScheduling = EntryDictationPause()
  ) {
    self.speech = speech
    self.pause = pause
  }

  static func localeIdentifier(interfaceCode: String) -> String {
    interfaceCode.hasPrefix("ru") ? "ru-RU" : "en-US"
  }

  func toggle(
    interfaceCode: String,
    readLine: @escaping @MainActor () -> String,
    writeLine: @escaping @MainActor (String) -> Void
  ) async {
    if isActive {
      stop()
      return
    }
    state = .idle
    let locale = Self.localeIdentifier(interfaceCode: interfaceCode)
    guard speech.isAvailable(localeIdentifier: locale) else {
      state = .unavailable
      return
    }
    let id = UUID()
    session = id
    isActive = true
    prefix = readLine()
    lastLine = prefix
    self.readLine = readLine
    self.writeLine = writeLine
    let authorization = Task { await speech.authorize() }
    authorizationTask = authorization
    let authorized = await authorization.value
    guard session == id else { return }
    authorizationTask = nil
    guard !Task.isCancelled else {
      stop()
      return
    }
    guard authorized else {
      finish(.denied)
      return
    }
    guard readLine() == lastLine else {
      stop()
      return
    }
    do {
      try speech.start(localeIdentifier: locale) { [weak self] event in
        self?.receive(event, session: id)
      }
      state = .listening
      // Silence before the first word also releases the microphone.
      armPause(after: .seconds(6), session: id)
    } catch {
      finish(.unavailable)
    }
  }

  func lineChanged(to line: String) {
    if isActive, line != lastLine { stop() }
  }

  func stop() { finish(.idle) }

  private func receive(_ event: EntryDictationEvent, session id: UUID) {
    guard session == id else { return }
    guard readLine?() == lastLine else {
      stop()
      return
    }
    switch event {
    case .unavailable:
      finish(.unavailable)
    case .transcript(let words, let isFinal):
      if !words.isEmpty, words != lastTranscript {
        lastTranscript = words
        let separator = prefix.isEmpty || prefix.last?.isWhitespace == true ? "" : " "
        lastLine = prefix + separator + words
        writeLine?(lastLine)
        armPause(after: .seconds(2), session: id)
      }
      if isFinal { stop() }
    }
  }

  private func armPause(after delay: Duration, session id: UUID) {
    pause.schedule(after: delay) { [weak self] in
      guard let self, self.session == id else { return }
      self.stop()
    }
  }

  private func finish(_ next: EntryDictationState) {
    // Invalidate before cancel: cancellation itself may deliver a recognizer callback.
    session = nil
    isActive = false
    authorizationTask?.cancel()
    authorizationTask = nil
    pause.cancel()
    speech.stop()
    prefix = ""
    lastLine = ""
    lastTranscript = ""
    readLine = nil
    writeLine = nil
    state = next
  }
}
