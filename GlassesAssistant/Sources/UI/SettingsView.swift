import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [ProviderID: String] = [:]
    @State private var savedKeys: Set<ProviderID> = []
    @State private var keyError: String?

    var body: some View {
        @Bindable var settings = model.settings

        NavigationStack {
            Form {
                Section {
                    ForEach(ProviderID.allCases) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent(provider.displayName,
                                           value: savedKeys.contains(provider) ? "Saved in Keychain" : "Not set")
                            SecureField(provider.keyPlaceholder, text: draftBinding(for: provider))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            HStack {
                                Button("Save") { save(provider) }
                                    .disabled((drafts[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                if savedKeys.contains(provider) {
                                    Spacer()
                                    Button("Delete", role: .destructive) { delete(provider) }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if let keyError {
                        Text(keyError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("API keys")
                } footer: {
                    Text("Keys are stored only in this device's Keychain and sent only to the provider's API.")
                }

                Section("Model") {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(ProviderID.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Claude effort", selection: $settings.anthropicEffort) {
                        ForEach(AnthropicProvider.Effort.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }

                Section {
                    Picker("Glasses mic via", selection: $settings.audioInput) {
                        ForEach(AudioInputMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("On-device speech recognition", isOn: $settings.onDeviceRecognition)
                    Stepper(value: $settings.silenceTimeout, in: 0.6...3.0, step: 0.2) {
                        LabeledContent("End of speech after", value: String(format: "%.1f s", settings.silenceTimeout))
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text(settings.audioInput.footnote)
                }

                Section {
                    TextEditor(text: $settings.systemPrompt).frame(minHeight: 140)
                    Button("Reset to default") { settings.systemPrompt = AppSettings.defaultSystemPrompt }
                } header: {
                    Text("System prompt")
                } footer: {
                    Text("Changes apply the next time you start a conversation.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: refreshSavedKeys)
        }
    }

    private func draftBinding(for provider: ProviderID) -> Binding<String> {
        Binding(get: { drafts[provider] ?? "" }, set: { drafts[provider] = $0 })
    }

    private func save(_ provider: ProviderID) {
        do {
            try model.keychain.setAPIKey(drafts[provider] ?? "", for: provider)
            drafts[provider] = ""
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        refreshSavedKeys()
    }

    private func delete(_ provider: ProviderID) {
        do {
            try model.keychain.deleteAPIKey(for: provider)
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        refreshSavedKeys()
    }

    private func refreshSavedKeys() {
        savedKeys = Set(ProviderID.allCases.filter { model.keychain.hasAPIKey(for: $0) })
    }
}
