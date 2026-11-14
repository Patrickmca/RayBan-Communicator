import AVFoundation
import Foundation
import MWDATCamera
import MWDATCore
import Observation
import os

enum GlassesError: LocalizedError {
    case notRegistered
    case permissionDenied(String)
    case sessionStopped
    case sessionTimeout
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .notRegistered: "Link the app with Meta AI first (Glasses → Link)."
        case .permissionDenied(let name): "The \(name) permission was not granted in Meta AI."
        case .sessionStopped: "The glasses session stopped."
        case .sessionTimeout: "The glasses didn't connect. Are they on, unfolded and in range?"
        case .cameraUnavailable: "Couldn't attach the camera stream that carries the glasses microphone."
        }
    }
}

/// Everything that touches the Meta Wearables Device Access Toolkit: registration with Meta AI,
/// permissions, the `DeviceSession`, and the camera stream that carries the glasses mic audio.
@MainActor
@Observable
final class GlassesManager {
    enum RegistrationStatus: String {
        case unavailable = "Unavailable"
        case available = "Not linked"
        case registering = "Linking…"
        case registered = "Linked"
    }

    private(set) var registration: RegistrationStatus = .unavailable
    private(set) var activeDeviceID: String?
    private(set) var sessionState = "No session"
    var lastError: String?

    @ObservationIgnored private let wearables = Wearables.shared
    @ObservationIgnored private let selector: AutoDeviceSelector
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var isSessionStarted = false
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Void, Error>] = []
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var camera: Camera?
    @ObservationIgnored private var streamTokens = ListenerTokenBag()
    @ObservationIgnored private let logger = Logger(subsystem: "GlassesAssistant", category: "Glasses")

    init() {
        selector = AutoDeviceSelector(wearables: wearables)

        Task { [weak self] in
            guard let stream = self?.wearables.registrationStateStream() else { return }
            for await state in stream {
                guard let self else { return }
                switch state {
                case .registered: self.registration = .registered
                case .registering: self.registration = .registering
                case .available: self.registration = .available
                default: self.registration = .unavailable
                }
            }
        }
        Task { [weak self] in
            guard let stream = self?.selector.activeDeviceStream() else { return }
            for await deviceID in stream {
                self?.activeDeviceID = deviceID
            }
        }
    }

    // MARK: Registration

    /// Forwards Meta AI callback URLs (registration / permission results) to the SDK.
    func handleCallbackURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return }
        Task {
            do {
                _ = try await wearables.handleUrl(url)
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func register() async {
        do {
            try await wearables.startRegistration()
        } catch {
            lastError = String(describing: error)
        }
    }

    func unregister() async {
        do {
            try await wearables.startUnregistration()
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: Permissions

    /// Checks silently first; only opens Meta AI if the permission isn't granted yet.
    func ensurePermission(_ permission: Permission, name: String) async throws {
        if try await wearables.checkPermissionStatus(permission) == .granted { return }
        let status = try await wearables.requestPermission(permission)
        guard status == .granted else { throw GlassesError.permissionDenied(name) }
    }

    // MARK: Session

    func startSessionIfNeeded() async throws -> DeviceSession {
        if let session, isSessionStarted { return session }
        guard registration == .registered else { throw GlassesError.notRegistered }

        let session: DeviceSession
        if let existing = self.session {
            session = existing
        } else {
            session = try wearables.createSession(deviceSelector: selector)
            self.session = session
            observe(session)
            try session.start()
        }

        // Resumed by the state observer on `.started` / `.stopped`, or by the timeout below.
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.resumeStartWaiters(with: GlassesError.sessionTimeout)
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { startWaiters.append($0) }
        return session
    }

    func stopSession() async {
        await stopMicrophoneStream()
        session?.stop()
    }

    private func observe(_ session: DeviceSession) {
        sessionTasks.forEach { $0.cancel() }
        sessionTasks = [
            Task { [weak self] in
                for await state in session.stateStream() {
                    guard let self else { return }
                    self.sessionState = String(describing: state)
                    self.logger.debug("session state: \(String(describing: state))")
                    if state == .started {
                        self.isSessionStarted = true
                        self.resumeStartWaiters(with: nil)
                    } else if state == .stopped {
                        self.isSessionStarted = false
                        self.session = nil
                        self.camera = nil
                        self.resumeStartWaiters(with: GlassesError.sessionStopped)
                    } else if state == .paused {
                        // The device paused us (e.g. another experience took over). Wait for
                        // `.started` or `.stopped`; never restart while paused.
                        self.isSessionStarted = false
                    }
                }
            },
            Task { [weak self] in
                for await error in session.errorStream() {
                    self?.logger.error("session error: \(String(describing: error))")
                    self?.lastError = String(describing: error)
                    if error == .datAppOnTheGlassesUpdateRequired {
                        try? await Wearables.shared.openDATGlassesAppUpdate()
                    }
                }
            },
        ]
    }

    private func resumeStartWaiters(with error: Error?) {
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    // MARK: Microphone over the camera stream

    /// Starts the glasses microphone. In DAT 1.0 the mic PCM rides on a camera `Stream`
    /// (experimental: fine for Developer Mode and beta testing, not yet allowed in production
    /// release channels). Video is requested at the lowest cost; this app never decodes it.
    ///
    /// `onBuffer` is called on an SDK thread.
    func startMicrophoneStream(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onAudioError: @escaping @Sendable () -> Void
    ) async throws {
        try await ensurePermission(.camera, name: "camera")
        try await ensurePermission(.microphone, name: "microphone")
        let session = try await startSessionIfNeeded()

        await stopMicrophoneStream()
        let configuration = StreamConfiguration(
            // HEVC keeps flowing when the app is backgrounded; a raw stream pauses.
            videoCodec: .hvc1,
            audioCodec: .pcm(sampleRate: .rate16000, numberOfChannels: 1),
            resolution: .low,
            frameRate: 7
        )
        guard let camera = try session.addCamera(config: configuration) else {
            throw GlassesError.cameraUnavailable
        }
        self.camera = camera

        // Listen before starting so no frames are missed.
        camera.stream.audioFramePublisher.listen { frame in
            onBuffer(frame.pcmBuffer)
        }.store(in: streamTokens)
        camera.stream.errorPublisher.listen { [logger] error in
            logger.error("stream error: \(String(describing: error))")
            if error == .audioStreamingError { onAudioError() }
        }.store(in: streamTokens)
        camera.stream.start()
    }

    func stopMicrophoneStream() async {
        // Cancel listeners before stopping the camera (stopping cascades to the stream).
        await streamTokens.cancelAll()
        streamTokens = ListenerTokenBag()
        camera?.stop()
        camera = nil
    }
}
