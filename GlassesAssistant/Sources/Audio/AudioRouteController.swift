import AVFoundation

/// Owns the shared AVAudioSession so replies play through the glasses' speakers.
@MainActor
final class AudioRouteController {
    private let session = AVAudioSession.sharedInstance()

    func configure(for mode: AudioInputMode) throws {
        switch mode {
        case .datStream:
            // Mic arrives over DAT, so iOS only needs to play. `.playback` routes to the glasses
            // over A2DP when they're the connected Bluetooth output and ignores the silent switch.
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        case .bluetoothHFP:
            // `.voiceChat` turns on echo cancellation; HFP carries both mic and speaker.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        }
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Human-readable current output, e.g. "Ray-Ban Meta (Bluetooth A2DP)".
    var currentOutputDescription: String {
        let outputs = session.currentRoute.outputs
        guard !outputs.isEmpty else { return "None" }
        return outputs.map { "\($0.portName) (\(Self.label(for: $0.portType)))" }.joined(separator: ", ")
    }

    var isOutputBluetooth: Bool {
        session.currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
    }

    private static func label(for port: AVAudioSession.Port) -> String {
        switch port {
        case .bluetoothA2DP: "Bluetooth A2DP"
        case .bluetoothHFP: "Bluetooth HFP"
        case .bluetoothLE: "Bluetooth LE"
        case .builtInSpeaker: "iPhone speaker"
        case .builtInReceiver: "iPhone earpiece"
        case .headphones: "Headphones"
        default: port.rawValue
        }
    }
}
