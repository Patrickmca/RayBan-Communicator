import AVFoundation
import Foundation
import Observation

/// The voice loop: glasses mic → Speech transcription → LLM (via router) → spoken reply → listen.
@MainActor
@Observable
final class AppModel {
    enum Phase: String {
        case idle = "Idle"
        case starting = "Starting…"
        case listening = "Listening"
        case thinking = "Thinking…"
        case speaking = "Speaking"
    }

    private(set) var phase: Phase = .idle
    private(set) var partialTranscript = ""
    private(set) var turns: [ChatTurn] = []
    private(set) var outputRoute = ""
    var errorMessage: String?

    let glasses = GlassesManager()
    let settings = AppSettings()
    let keychain = KeychainStore()

    @ObservationIgnored private let audioRoute = AudioRouteController()
    @ObservationIgnored private let transcriber = SpeechTranscriber()
    @ObservationIgnored private let speech = SpeechOutput()
    @ObservationIgnored private let gate = AudioGate()
    @ObservationIgnored private var source: (any AudioBufferSource)?
    @ObservationIgnored private var router: (any LLMRouter)?
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = Date.distantPast

    init() {
        refreshOutputRoute()
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOutputRoute() }
        }
    }

    var isOutputOnGlasses: Bool { audioRoute.isOutputBluetooth }

    // MARK: Conversation control

    func start() async {
        guard phase == .idle else { return }
        errorMessage = nil
        phase = .starting
        do {
            router = try ProviderRegistry(keychain: keychain).makeRouter(
                defaultProvider: settings.provider,
                options: .init(anthropicEffort: settings.anthropicEffort)
            )
            guard await SpeechTranscriber.requestAuthorization() else { throw TranscriberError.notAuthorized }
            transcriber.preferOnDevice = settings.onDeviceRecognition

            try audioRoute.configure(for: settings.audioInput)
            let source: any AudioBufferSource =
                switch settings.audioInput {
                case .datStream:
                    DATStreamAudioSource(glasses: glasses) { [weak self] in
                        self?.fail(with: AudioSourceError.streamFailed)
                    }
                case .bluetoothHFP:
                    HFPAudioSource()
                }
            self.source = source
            let transcriber = self.transcriber
            let gate = self.gate
            try await source.start { buffer in
                if gate.isOpen { transcriber.append(buffer) }
            }
            // Stop was pressed while the glasses were connecting.
            guard self.source === source else {
                await source.stop()
                return
            }
            refreshOutputRoute()
            beginListening()
        } catch {
            fail(with: error)
        }
    }

    func stop() async {
        responseTask?.cancel()
        responseTask = nil
        silenceTask?.cancel()
        restartTask?.cancel()
        gate.isOpen = false
        transcriber.cancel()
        speech.stop()
        let source = self.source
        self.source = nil
        await source?.stop()
        audioRoute.deactivate()
        partialTranscript = ""
        phase = .idle
    }

    /// Cuts the reply short and goes back to listening.
    func interrupt() {
        guard phase == .thinking || phase == .speaking else { return }
        responseTask?.cancel()
        responseTask = nil
        speech.stop()
        beginListening()
    }

    /// Sends what has been heard so far without waiting for the silence timeout.
    func sendNow() {
        commitUtterance()
    }

    func clearConversation() {
        turns.removeAll()
    }

    private func fail(with error: Error) {
        let message = error.localizedDescription
        Task {
            await stop()
            errorMessage = message
        }
    }

    // MARK: Listening

    private func beginListening() {
        guard source != nil else { return }
        partialTranscript = ""
        lastHeard = .now
        do {
            try transcriber.start(
                onText: { [weak self] text, isFinal in self?.handleTranscript(text, isFinal: isFinal) },
                onError: { [weak self] error in self?.handleRecognitionError(error) }
            )
        } catch {
            fail(with: error)
            return
        }
        phase = .listening
        gate.isOpen = true
        startSilenceMonitor()
    }

    private func handleTranscript(_ text: String, isFinal: Bool) {
        guard phase == .listening else { return }
        if text != partialTranscript {
            partialTranscript = text
            lastHeard = .now
        }
        if isFinal { commitUtterance() }
    }

    private func handleRecognitionError(_ error: Error) {
        guard phase == .listening else { return }
        if !partialTranscript.isEmpty {
            commitUtterance()
            return
        }
        // "No speech detected", recognizer timeouts, etc.: quietly start a fresh utterance.
        gate.isOpen = false
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.phase == .listening else { return }
            self.beginListening()
        }
    }

    private func startSilenceMonitor() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.phase == .listening else { return }
                let silence = Date.now.timeIntervalSince(self.lastHeard)
                if !self.partialTranscript.isEmpty, silence >= self.settings.silenceTimeout {
                    self.commitUtterance()
                    return
                }
            }
        }
    }

    private func commitUtterance() {
        let text = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .listening, !text.isEmpty else { return }
        gate.isOpen = false
        silenceTask?.cancel()
        transcriber.cancel()
        partialTranscript = ""
        phase = .thinking
        responseTask = Task { [weak self] in await self?.respond(to: text) }
    }

    // MARK: Responding

    private func respond(to text: String) async {
        guard let router else { return }
        let userTurn = ChatTurn(role: .user, text: text)
        turns.append(userTurn)
        var chunker = SentenceChunker()

        do {
            let provider = try router.route(RoutingContext(latestUserText: text, history: turns))
            let request = LLMRequest(system: settings.systemPrompt, turns: turns)
            var reply: ChatTurn?
            for try await event in provider.streamReply(request) {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let delta):
                    chunker.append(delta).forEach(say)
                case .finished(let turn):
                    reply = turn
                }
            }
            if let rest = chunker.flush() { say(rest) }
            if let reply {
                turns.append(reply)
            } else {
                dropTurn(userTurn)
            }
            await speech.waitUntilFinished()
        } catch is CancellationError {
            dropTurn(userTurn)
            return
        } catch {
            if Task.isCancelled {
                dropTurn(userTurn)
                return
            }
            // Keep history well-formed: a user turn without a reply is not sent again.
            dropTurn(userTurn)
            speech.stop()
            errorMessage = error.localizedDescription
            say((error as? LLMError)?.spokenDescription ?? "Sorry, something went wrong.")
            await speech.waitUntilFinished()
        }

        guard !Task.isCancelled, phase != .idle else { return }
        beginListening()
    }

    private func say(_ sentence: String) {
        phase = .speaking
        speech.enqueue(sentence)
    }

    private func dropTurn(_ turn: ChatTurn) {
        turns.removeAll { $0.id == turn.id }
    }

    private func refreshOutputRoute() {
        outputRoute = audioRoute.currentOutputDescription
    }
}
