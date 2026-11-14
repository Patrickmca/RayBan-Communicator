import AVFoundation
import Foundation

/// Where the glasses microphone audio comes from.
enum AudioInputMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// DAT camera-stream audio (16 kHz PCM). Experimental in DAT 1.0: not allowed in production
    /// release channels yet. Leaves the iOS audio session free, so replies play over A2DP.
    case datStream
    /// The glasses' Bluetooth hands-free mic via AVAudioSession, as Meta's CameraAccess sample
    /// does. Production-safe; replies play over the narrower HFP link.
    case bluetoothHFP

    var id: String { rawValue }

    var title: String {
        switch self {
        case .datStream: "DAT stream (experimental)"
        case .bluetoothHFP: "Bluetooth HFP"
        }
    }

    var footnote: String {
        switch self {
        case .datStream:
            "Uses the toolkit's camera stream to carry mic audio. Needs camera + microphone permission in Meta AI. Experimental features can't ship to production release channels yet."
        case .bluetoothHFP:
            "Uses the glasses as a Bluetooth headset mic. Works without toolkit permissions, but audio quality is lower."
        }
    }
}

/// Delivers PCM buffers from the glasses microphone.
@MainActor
protocol AudioBufferSource: AnyObject {
    /// `onBuffer` may be called on any thread.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws
    func stop() async
}

enum AudioSourceError: LocalizedError {
    case microphonePermissionDenied
    case glassesMicNotFound
    case noInputFormat
    case streamFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "Microphone access is off. Enable it in iOS Settings."
        case .glassesMicNotFound: "No Bluetooth headset mic found. Connect the glasses in iOS Bluetooth settings."
        case .noInputFormat: "The audio input isn't available."
        case .streamFailed: "The glasses audio stream failed."
        }
    }
}

/// Glasses mic via the Device Access Toolkit camera stream.
@MainActor
final class DATStreamAudioSource: AudioBufferSource {
    private let glasses: GlassesManager
    private let onFailure: @MainActor () -> Void

    init(glasses: GlassesManager, onFailure: @escaping @MainActor () -> Void) {
        self.glasses = glasses
        self.onFailure = onFailure
    }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        let onFailure = self.onFailure
        try await glasses.startMicrophoneStream(onBuffer: onBuffer) {
            Task { @MainActor in onFailure() }
        }
    }

    func stop() async {
        await glasses.stopSession()
    }
}

/// Glasses mic via Bluetooth HFP. Requires `AudioRouteController.configure(for: .bluetoothHFP)`.
@MainActor
final class HFPAudioSource: AudioBufferSource {
    private let engine = AVAudioEngine()

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioSourceError.microphonePermissionDenied
        }
        let session = AVAudioSession.sharedInstance()
        guard let glassesMic = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
            throw AudioSourceError.glassesMicNotFound
        }
        // Never fall back to the phone mic: the assistant should only hear the wearer.
        try session.setPreferredInput(glassesMic)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero format means no usable input; installTap would crash.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioSourceError.noInputFormat }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Thread-safe on/off switch between the audio thread and the main actor. Closed while the
/// assistant is thinking or speaking so the reply isn't transcribed back as user speech.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue } }
    }
}
