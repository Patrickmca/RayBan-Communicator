# GlassesAssistant

A SwiftUI iOS app that turns Ray-Ban Meta glasses into a voice assistant.

**Phase 1:** glasses mic → Apple Speech transcription → Claude (Anthropic API) → `AVSpeechSynthesizer` reply through the glasses speakers.

```
GlassesManager (Meta DAT SDK)          AudioRouteController (AVAudioSession → glasses)
   │ PCM buffers                                   ▲
   ▼                                               │
AudioBufferSource ──▶ SpeechTranscriber ──▶ AppModel ──▶ LLMRouter ──▶ LLMProvider (AnthropicProvider)
  (DAT stream | HFP)   (SFSpeechRecognizer)   (voice loop)  (FixedRouter)      │ streamed text
                                                  │                            ▼
                                                  └──────────── SentenceChunker ──▶ SpeechOutput
```

## Project layout

| Path | Purpose |
|---|---|
| `project.yml` | XcodeGen spec (app + unit-test targets, DAT package pinned to 1.0.1) |
| `Config/Shared.xcconfig` | Team ID, bundle ID, Meta App ID / Client Token |
| `GlassesAssistant/Support/Info.plist` | DAT `MWDAT` keys, URL scheme, background modes, usage strings |
| `Sources/Glasses/GlassesManager.swift` | DAT: configure, registration, permissions, `DeviceSession`, mic over camera stream |
| `Sources/Audio/` | Audio sources (DAT stream / Bluetooth HFP), audio-session routing to the glasses |
| `Sources/Speech/` | `SFSpeechRecognizer` transcription, TTS output, sentence chunking for streamed replies |
| `Sources/LLM/` | Provider-neutral protocol, router, registry, and the Anthropic provider |
| `Sources/Security/KeychainStore.swift` | API keys in the Keychain (`AfterFirstUnlockThisDeviceOnly`) |
| `Sources/App/AppModel.swift` | The listen → think → speak loop |

## Two ways to get the glasses mic

Pick one in **Settings → Audio → Glasses mic via**.

| Mode | How | Trade-off |
|---|---|---|
| **DAT stream** (default) | `StreamConfiguration(audioCodec: .pcm(.rate16000, 1))` on a low-res camera stream; buffers from `stream.audioFramePublisher` | This is the toolkit's own mic API. It's **experimental in DAT 1.0**: fine with Developer Mode and beta release channels, but **not allowed in production release channels yet**. It needs both the camera and microphone permissions, and it runs a minimal camera stream (expect the glasses' capture LED). Replies play over A2DP, which sounds better. |
| **Bluetooth HFP** | The glasses act as a headset mic via `AVAudioSession` (`.allowBluetoothHFP`), the same way Meta's CameraAccess sample records audio | Production-safe and needs no toolkit permissions. Audio is narrower (hands-free profile) in both directions. |

## Claude settings

- Model: `claude-opus-5-5`, streamed. Speech starts after the first full sentence arrives.
- `output_config.effort: "low"` by default. That's the lowest latency for spoken chat. You can change it in Settings (low/medium/high).
- **Server-side refusal fallback is on** (`fallbacks: "default"` and the `server-side-fallback-2026-07-01` beta header). If a safety classifier declines, the API retries on a fallback model in the same call. To turn it off, set `Configuration.useServerSideFallbacks = false`.
- Claude's content blocks, including thinking signatures, are stored per turn and replayed unchanged, as the API requires.
- Automatic prompt caching (top-level `cache_control`) on the growing conversation.
- There is no official Anthropic Swift SDK, so the provider uses `URLSession` and parses the SSE stream (`AnthropicStreamAccumulator`, unit-tested).

## Manual steps

### 1. Apple / Xcode
1. Install **Xcode 26.4+** (DAT 1.0.x needs Swift 6.3+). Deployment target is iOS 17.2.
2. Generate the project on a Mac:
   ```bash
   brew install xcodegen
   ```
   ```bash
   cd GlassesAssistant && xcodegen generate && open GlassesAssistant.xcodeproj
   ```
   Without XcodeGen, create a new iOS App project named `GlassesAssistant` (SwiftUI). Then drag in `GlassesAssistant/Sources`, point *Info.plist File* and *Code Signing Entitlements* at the files in `GlassesAssistant/Support`, and add the package below.
3. The package `https://github.com/facebook/meta-wearables-dat-ios`, exact version **1.0.1**, products **MWDATCore** and **MWDATCamera**, is already in `project.yml`.
4. **Signing:** in `Config/Shared.xcconfig`, set `DEVELOPMENT_TEAM` to your Team ID and `PRODUCT_BUNDLE_IDENTIFIER` to something unique, e.g. `com.yourname.GlassesAssistant`. Keep Automatic signing. The DAT SDK also reads the Team ID through `MWDAT > TeamID`.
5. Run on a **physical iPhone**. The Simulator can't reach the glasses.
   - Turn on iOS Developer Mode: Settings → Privacy & Security → Developer Mode.
   - With a free Apple ID, trust the certificate: Settings → General → VPN & Device Management.

### 2. Meta AI app and glasses
1. Install the **Meta AI** app, pair your Ray-Ban Meta glasses, and update the glasses' firmware and the app.
2. Enable **Developer Mode**: Meta AI → Settings → *your glasses* → Developer Mode. It's per-device and **turns itself off after firmware updates**, so re-enable it after each one.
3. Make sure the glasses also show as a connected Bluetooth audio device in iOS Settings → Bluetooth. Replies are routed there. The app shows the current **Audio out** route.

### 3. Wearables Developer Center
With Developer Mode on, you can leave `META_APP_ID` and `CLIENT_TOKEN` empty and the SDK skips attestation. For anything beyond your own Developer Mode glasses:
1. Create an account at <https://wearables.developer.meta.com/> and register an **organization**.
2. Create a **project/app** for your bundle ID. Request the capabilities the app uses: **Camera** and **Audio Streaming**, which Meta's own guidance lists for camera-stream audio.
3. Copy the **Meta App ID** and **Client Token** into `Config/Shared.xcconfig`.
4. Create a **release channel** and add your testers. Experimental features, including the DAT-stream audio this app uses by default, can go to beta channels but not production.
5. Accept the Meta Wearables Developer Terms and Acceptable Use Policy.

Optional: to opt out of Meta's SDK analytics or crash reporting, add `MWDAT > Analytics > OptOut = YES` or `MWDAT > CrashReporting > OptOut = YES` to `Info.plist`.

### 4. Anthropic
Create an API key in the Claude Console. Then paste it in the app under **Settings → API keys → Save**. It's stored only in the Keychain.

### 5. First run
1. **Glasses → Link with Meta AI.** Meta AI opens; approve, and it returns to the app through the `glassesassistant://` URL scheme.
2. **Start conversation.** In DAT-stream mode, Meta AI opens to grant **camera** and **microphone** access; choose *Allow always*. iOS then asks for Speech Recognition permission, plus Microphone in HFP mode.
3. Speak. After 1.2 s of silence (adjustable) the text goes to Claude, and the reply is spoken through the glasses. **Interrupt** cuts a reply short; **Send now** skips the wait.

## Phase 2: adding OpenAI and a router

1. `ProviderID`: add `case openai` and its `displayName` and `keyPlaceholder`. The Settings key field appears automatically.
2. Add `Sources/LLM/OpenAI/OpenAIProvider.swift` conforming to `LLMProvider`. Emit `.textDelta` while streaming and `.finished(ChatTurn)` at the end. Store any native payload under `.openai`. For turns from other providers, use `ChatTurn.text`.
3. `ProviderRegistry.makeProvider`: add the `.openai` case.
4. Replace `FixedRouter` in `ProviderRegistry.makeRouter` with a router that holds several providers. It can route on `RoutingContext`, for example by keyword or user setting, with fallback on error. `AppModel` needs no changes.

## Status and known limits
- **Not yet compiled.** The code was written against the DAT 1.0.1 sources and samples but hasn't been built in Xcode. Expect a few small compile fixes on the first build.
- MockDeviceKit can't inject mic PCM, so testing the voice loop needs real glasses. Unit tests cover the SSE parser, request shape, and sentence chunking.
- `SFSpeechRecognizer` is used for iOS 17 compatibility. On iOS 26, `SpeechAnalyzer` is an option later.
