import AVFoundation
import Speech

enum TranscriberError: LocalizedError {
    case notAuthorized
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Speech recognition is off. Enable it in iOS Settings → Privacy."
        case .unavailable: "Speech recognition isn't available right now for this language."
        }
    }
}

/// Apple Speech framework transcription of externally supplied PCM buffers.
/// One recognition task per utterance; `AppModel` decides when an utterance ends.
@MainActor
final class SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0

    /// Written on the main actor, read from the audio thread in `append`.
    nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    private let lock = NSLock()

    var preferOnDevice = true

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Starts a new utterance. Callbacks arrive on the main actor and only for this utterance.
    func start(
        onText: @escaping @MainActor (_ text: String, _ isFinal: Bool) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) throws {
        cancel()
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if preferOnDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true  // no 1-minute server limit, lower latency
        }

        generation += 1
        let current = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if let text { onText(text, isFinal) }
                if let error, text == nil { onError(error) }
            }
        }
        lock.withLock { self.request = request }
    }

    /// Thread-safe; called from the audio callback.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    /// Ends the current utterance and ignores any further callbacks from it.
    func cancel() {
        generation += 1
        let request = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { self.request = nil }
            return self.request
        }
        request?.endAudio()
        task?.cancel()
        task = nil
    }
}
