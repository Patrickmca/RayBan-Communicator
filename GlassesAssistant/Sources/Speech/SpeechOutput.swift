import AVFoundation

/// Speaks reply sentences with AVSpeechSynthesizer through the app's audio session
/// (configured by `AudioRouteController` to route to the glasses).
@MainActor
final class SpeechOutput: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var inFlight = Set<ObjectIdentifier>()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        ?? AVSpeechSynthesisVoice(language: "en-US")

    var isSpeaking: Bool { !inFlight.isEmpty }

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    func enqueue(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.prefersAssistiveTechnologySettings = true
        inFlight.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    /// Returns once everything queued so far has been spoken (or `stop()` was called).
    func waitUntilFinished() async {
        guard isSpeaking else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        inFlight.removeAll()
        resumeWaitersIfIdle()
    }

    private func finished(_ id: ObjectIdentifier) {
        inFlight.remove(id)
        resumeWaitersIfIdle()
    }

    private func resumeWaitersIfIdle() {
        guard inFlight.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }
}

extension SpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
}
