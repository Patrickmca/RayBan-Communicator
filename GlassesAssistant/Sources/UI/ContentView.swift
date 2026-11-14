import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                GlassesSection(glasses: model.glasses)

                Section("Assistant") {
                    LabeledContent("Status", value: model.phase.rawValue)
                    LabeledContent("Audio out", value: model.outputRoute)
                    if model.phase != .idle, !model.isOutputOnGlasses {
                        Label("Replies aren't going to Bluetooth. Check the glasses are connected in iOS Bluetooth settings.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if !model.partialTranscript.isEmpty {
                        Text(model.partialTranscript).italic().foregroundStyle(.secondary)
                    }
                    controls
                }

                if let error = model.errorMessage ?? model.glasses.lastError {
                    Section("Last error") {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section {
                    if model.turns.isEmpty {
                        Text("Start a conversation and speak to your glasses.").foregroundStyle(.secondary)
                    }
                    ForEach(model.turns) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.role == .user ? "You" : "Assistant").font(.caption).foregroundStyle(.secondary)
                            Text(turn.text)
                        }
                    }
                } header: {
                    HStack {
                        Text("Conversation")
                        Spacer()
                        if !model.turns.isEmpty {
                            Button("Clear") { model.clearConversation() }.font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Glasses Assistant")
            .toolbar {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    @ViewBuilder private var controls: some View {
        if model.phase == .idle {
            Button {
                Task { await model.start() }
            } label: {
                Label("Start conversation", systemImage: "mic.fill")
            }
        } else {
            if model.phase == .listening, !model.partialTranscript.isEmpty {
                Button("Send now") { model.sendNow() }
            }
            if model.phase == .thinking || model.phase == .speaking {
                Button("Interrupt") { model.interrupt() }
            }
            Button(role: .destructive) {
                Task { await model.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
    }
}

private struct GlassesSection: View {
    let glasses: GlassesManager

    var body: some View {
        Section("Glasses") {
            LabeledContent("Meta AI link", value: glasses.registration.rawValue)
            LabeledContent("Device", value: glasses.activeDeviceID == nil ? "Not available" : "Available")
            LabeledContent("Session", value: glasses.sessionState)
            switch glasses.registration {
            case .available:
                Button("Link with Meta AI") { Task { await glasses.register() } }
            case .registered:
                Button("Unlink", role: .destructive) { Task { await glasses.unregister() } }
            case .registering, .unavailable:
                EmptyView()
            }
        }
    }
}
