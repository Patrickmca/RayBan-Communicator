import Foundation
import Observation

/// Non-secret preferences (API keys live in the Keychain, never here).
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var provider: ProviderID { didSet { defaults.set(provider.rawValue, forKey: Keys.provider) } }
    var anthropicEffort: AnthropicProvider.Effort {
        didSet { defaults.set(anthropicEffort.rawValue, forKey: Keys.effort) }
    }
    var audioInput: AudioInputMode { didSet { defaults.set(audioInput.rawValue, forKey: Keys.audioInput) } }
    /// Seconds of no new words before the utterance is sent.
    var silenceTimeout: Double { didSet { defaults.set(silenceTimeout, forKey: Keys.silence) } }
    var onDeviceRecognition: Bool { didSet { defaults.set(onDeviceRecognition, forKey: Keys.onDevice) } }
    var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: Keys.systemPrompt) } }

    static let defaultSystemPrompt = """
        You are a voice assistant heard through smart glasses. Your reply is read aloud by a \
        text-to-speech voice, so answer in plain spoken sentences with no Markdown, lists, \
        headings, code blocks, emoji or URLs. Be brief: one to three sentences unless the user \
        asks for more detail. The user's words come from speech recognition and may contain \
        transcription errors; infer the likely meaning.
        """

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = defaults.string(forKey: Keys.provider).flatMap(ProviderID.init) ?? .anthropic
        anthropicEffort = defaults.string(forKey: Keys.effort).flatMap(AnthropicProvider.Effort.init) ?? .low
        audioInput = defaults.string(forKey: Keys.audioInput).flatMap(AudioInputMode.init) ?? .datStream
        silenceTimeout = defaults.object(forKey: Keys.silence) as? Double ?? 1.2
        onDeviceRecognition = defaults.object(forKey: Keys.onDevice) as? Bool ?? true
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? Self.defaultSystemPrompt
    }

    private enum Keys {
        static let provider = "provider"
        static let effort = "anthropicEffort"
        static let audioInput = "audioInput"
        static let silence = "silenceTimeout"
        static let onDevice = "onDeviceRecognition"
        static let systemPrompt = "systemPrompt"
    }
}
