import AVFoundation
import Foundation
import Speech

/// Audio stays in memory. A missing local model is an error, never a network fallback.
@MainActor
final class OnDeviceEntrySpeech: EntrySpeechRecognizing {
  private var engine: AVAudioEngine?
  private var audioSink: EntrySpeechAudioSink?
  private var task: SFSpeechRecognitionTask?
  private var recognizer: SFSpeechRecognizer?
  private var hasTap = false
  #if os(iOS)
    private var ownsAudioSession = false
  #endif

  func isAvailable(localeIdentifier: String) -> Bool {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
      return false
    }
    return recognizer.supportsOnDeviceRecognition && recognizer.isAvailable
  }

  func authorize() async -> Bool {
    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { @Sendable status in
        continuation.resume(returning: status)
      }
    }
    guard status == .authorized, !Task.isCancelled else { return false }
    return await AVCaptureDevice.requestAccess(for: .audio)
  }

  func start(
    localeIdentifier: String,
    receive: @escaping @MainActor @Sendable (EntryDictationEvent) -> Void
  ) throws {
    stop()
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
      recognizer.supportsOnDeviceRecognition, recognizer.isAvailable
    else { throw EntryDictationError.unavailable }

    do {
      #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true)
        ownsAudioSession = true
      #endif
      let engine = AVAudioEngine()
      self.engine = engine
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw EntryDictationError.unavailable
      }
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = true
      request.taskHint = .dictation
      let sink = EntrySpeechAudioSink(request: request)
      audioSink = sink
      self.recognizer = recognizer
      // Explicitly sendable: an audio-thread callback must not inherit the main actor.
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
        sink.append(buffer)
      }
      hasTap = true
      task = recognizer.recognitionTask(with: request) { @Sendable result, error in
        // Copy values before crossing to the main actor; never retain or log an error's text.
        let words = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal ?? false
        let failed = error != nil
        Task { @MainActor in
          if let words { receive(.transcript(words, isFinal: isFinal)) }
          if failed, !isFinal { receive(.unavailable) }
        }
      }
      engine.prepare()
      try engine.start()
    } catch {
      stop()
      throw EntryDictationError.unavailable
    }
  }

  func stop() {
    engine?.stop()
    if hasTap { engine?.inputNode.removeTap(onBus: 0) }
    hasTap = false
    audioSink?.finish()
    task?.cancel()
    task = nil
    audioSink = nil
    recognizer = nil
    engine = nil
    #if os(iOS)
      if ownsAudioSession {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        ownsAudioSession = false
      }
    #endif
  }
}

/// The audio tap and cancellation can overlap. Only appending and ending audio cross threads;
/// configuration and recognition-task ownership remain on the main actor.
private final class EntrySpeechAudioSink: @unchecked Sendable {
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?

  init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.withLock { request?.append(buffer) }
  }

  func finish() {
    lock.withLock {
      request?.endAudio()
      request = nil
    }
  }
}
