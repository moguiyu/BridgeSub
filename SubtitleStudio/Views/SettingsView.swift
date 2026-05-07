import SwiftUI

private enum SettingsTab: Hashable {
    case openSubtitles
    case providers
    case translation
    case toolchain
    case about
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .openSubtitles
    @State private var providerSettings = ProviderSettings.load()
    @State private var editingPresetID: TranslationProviderPresetID = ProviderSettings.load().lastUsedProviderPresetID

    @State private var openSubtitlesUsername = ""
    @State private var openSubtitlesPassword = ""
    @State private var openSubtitlesAPIKey = ""
    @State private var currentProviderAPIKey = ""

    @State private var openSubtitlesStatusMessage = ""
    @State private var openSubtitlesStatusIsError = false
    @State private var providerStatusMessage = ""
    @State private var providerStatusIsError = false

    let toolStatuses: [MediaToolStatus]
    private let credentialStore = KeychainCredentialStore(serviceName: "SubtitleStudio")

    var body: some View {
        TabView(selection: $selectedTab) {
            openSubtitlesTab
                .tabItem { Label("OpenSubtitles", systemImage: "magnifyingglass") }
                .tag(SettingsTab.openSubtitles)

            translationProvidersTab
                .tabItem { Label("Translation Providers", systemImage: "network") }
                .tag(SettingsTab.providers)

            translationSettingsTab
                .tabItem { Label("Translation Settings", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.translation)

            toolchainTab
                .tabItem { Label("Toolchain", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.toolchain)

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 720, minHeight: 560)
        .padding(.top, 8)
        .onAppear {
            loadStoredCredentials()
        }
        .onChange(of: providerSettings) { _, newValue in
            newValue.persist()
            refreshProviderStatus()
        }
        .onChange(of: editingPresetID) { _, _ in
            loadCurrentProviderAPIKey()
        }
    }

    private var openSubtitlesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsCard("Search from OpenSubtitles", subtitle: "Store the credentials needed for subtitle lookup and downloads.") {
                    VStack(alignment: .leading, spacing: 12) {
                        labeledInput("Username") {
                            TextField("OpenSubtitles username", text: $openSubtitlesUsername)
                                .textFieldStyle(.roundedBorder)
                        }

                        labeledInput("Password") {
                            SecureField("OpenSubtitles password", text: $openSubtitlesPassword)
                                .textFieldStyle(.roundedBorder)
                        }

                        labeledInput("API Key") {
                            SecureField("OpenSubtitles API key", text: $openSubtitlesAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Button("Save OpenSubtitles Credentials") {
                                saveOpenSubtitlesCredentials()
                            }
                            .disabled(openSubtitlesUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || openSubtitlesPassword.isEmpty
                                || openSubtitlesAPIKey.isEmpty)

                            Spacer()

                            Text(openSubtitlesValidationMessage)
                                .font(.caption)
                                .foregroundStyle(openSubtitlesValidationColor)
                        }

                        if !openSubtitlesStatusMessage.isEmpty {
                            Text(openSubtitlesStatusMessage)
                                .font(.caption)
                                .foregroundStyle(openSubtitlesStatusIsError ? .red : .secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var translationProvidersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsCard("Provider Presets", subtitle: "Edit the endpoint details and credentials that each translation card can use.") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Edit Preset", selection: $editingPresetID) {
                            ForEach(providerSettings.availablePresets) { preset in
                                Text(preset.displayName).tag(preset.id)
                            }
                        }
                        .pickerStyle(.menu)

                        LabeledContent("Transport") {
                            Text(editingPresetConfiguration.transportKind.displayName)
                                .foregroundStyle(.secondary)
                        }

                        TextField("Base URL", text: presetBinding(\.baseURL))
                            .textFieldStyle(.roundedBorder)

                        TextField("Model", text: presetBinding(\.model))
                            .textFieldStyle(.roundedBorder)

                        if editingPresetDescriptor.supportsOpenAICompatibleToggle {
                            Toggle(
                                "Use OpenAI-compatible endpoint (/v1/chat/completions)",
                                isOn: presetBoolBinding(\.useOpenAICompatibleEndpoint)
                            )
                            .font(.caption)
                        }

                        if editingPresetDescriptor.requiresAPIKey {
                            HStack(alignment: .center, spacing: 12) {
                                SecureField("API Key", text: $currentProviderAPIKey)
                                    .textFieldStyle(.roundedBorder)

                                Button("Save Key") {
                                    saveProviderAPIKey()
                                }
                                .disabled(currentProviderAPIKey.isEmpty)
                            }
                        } else {
                            Text("This local preset does not require an API key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(providerValidationMessage)
                            .font(.caption)
                            .foregroundStyle(providerValidationColor)

                        if !providerStatusMessage.isEmpty {
                            Text(providerStatusMessage)
                                .font(.caption)
                                .foregroundStyle(providerStatusIsError ? .red : .secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var translationSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsCard("Translation Behavior", subtitle: "Tune prompt behavior, QA strictness, and batching for subtitle generation.") {
                    VStack(alignment: .leading, spacing: 14) {
                        settingsGroup("Strategy", subtitle: "Choose how strongly the translator prioritizes quality review, fidelity, and subtitle readability.") {
                            Picker("Quality Profile", selection: $providerSettings.translationQualityProfile) {
                                ForEach(TranslationQualityProfile.allCases) { profile in
                                    Text(profile.title).tag(profile)
                                }
                            }

                            Picker("Pass Strategy", selection: $providerSettings.translationPassStrategy) {
                                ForEach(TranslationPassStrategy.allCases) { strategy in
                                    Text(strategy.title).tag(strategy)
                                }
                            }

                            Picker("Strictness", selection: $providerSettings.translationStrictness) {
                                ForEach(TranslationStrictness.allCases) { strictness in
                                    Text(strictness.title).tag(strictness)
                                }
                            }
                        }

                        settingsGroup("Batching And QA", subtitle: "Adjust how much subtitle text is sent per request and how cautious QA assist should be.") {
                            HStack {
                                Text("Batch Size")
                                Spacer()
                                Stepper("\(providerSettings.translationBatchSize)", value: $providerSettings.translationBatchSize, in: 1...200)
                                    .labelsHidden()
                                TextField("", value: $providerSettings.translationBatchSize, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 72)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Reference Override Confidence")
                                    Spacer()
                                    Text("\(Int((providerSettings.referenceOverrideConfidenceThreshold * 100).rounded()))%")
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $providerSettings.referenceOverrideConfidenceThreshold, in: 0.5...0.99, step: 0.01)
                                Text("Higher values make the selected reference subtitle less likely to override the original subtitle.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        settingsGroup("Preservation", subtitle: "Protect named entities when the source wording should usually stay unchanged.") {
                            Toggle("Keep names unchanged when possible", isOn: $providerSettings.translationKeepNames)
                            Toggle("Keep locations unchanged when possible", isOn: $providerSettings.translationKeepLocations)
                            Toggle("Keep brands unchanged when possible", isOn: $providerSettings.translationKeepBrands)
                        }

                        settingsGroup("Custom Instructions", subtitle: "Add optional expert guidance that will be appended to the generated translation system prompt.") {
                            TextEditor(text: $providerSettings.translationCustomInstructions)
                                .frame(minHeight: 120)
                                .font(.body)
                                .overlay(alignment: .topLeading) {
                                    if providerSettings.translationCustomInstructions.isEmpty {
                                        Text("Optional style or terminology instructions for the translation service.")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                            .padding(.top, 8)
                                            .padding(.leading, 5)
                                    }
                                }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var toolchainTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsCard("Media Toolchain", subtitle: "Verify the bundled and system fallback tools used for probing, extraction, and embedding.") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(toolStatuses) { status in
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(status.tool.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Text(status.detailLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }

                                Spacer()

                                Text(status.origin.displayName)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(status.isAvailable ? Color.green.opacity(0.14) : Color.red.opacity(0.14))
                                    .foregroundStyle(status.isAvailable ? .green : .red)
                                    .clipShape(Capsule())
                            }

                            if status.id != toolStatuses.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var aboutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsCard("BridgeSub", subtitle: "Native macOS tooling for assembling, translating, and exporting bilingual subtitles for local video playback.") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Version") {
                            Text(versionLabel)
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("Build") {
                            Text(buildLabel)
                                .foregroundStyle(.secondary)
                        }

                        Text("This redesign branch uses a two-card workflow for subtitle discovery, OpenSubtitles search, LLM translation, bilingual preview, and export or MKV embedding.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
        }
    }

    private var editingPresetConfiguration: TranslationProviderPresetConfiguration {
        providerSettings.configuration(for: editingPresetID)
    }

    private var editingPresetDescriptor: TranslationProviderPresetDescriptor {
        editingPresetID.descriptor
    }

    private var openSubtitlesValidationMessage: String {
        if openSubtitlesUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a username to enable OpenSubtitles search."
        }
        if openSubtitlesPassword.isEmpty || openSubtitlesAPIKey.isEmpty {
            return "Password and API key are both required."
        }
        return "Credentials look complete."
    }

    private var openSubtitlesValidationColor: Color {
        openSubtitlesUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || openSubtitlesPassword.isEmpty || openSubtitlesAPIKey.isEmpty
            ? .orange : .secondary
    }

    private var providerValidationMessage: String {
        let configuration = editingPresetConfiguration
        if configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Base URL is required."
        }
        if URL(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            return "Base URL is not valid."
        }
        if configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Model is required."
        }
        if editingPresetDescriptor.requiresAPIKey,
           currentProviderAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Save an API key for this preset before using it."
        }
        return "Preset is ready for translation cards."
    }

    private var providerValidationColor: Color {
        providerValidationMessage == "Preset is ready for translation cards." ? .secondary : .orange
    }

    private var versionLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build"
    }

    private var buildLabel: String {
        Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "Local"
    }

    private func settingsCard<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(nsColor: .windowBackgroundColor))
                .strokeBorder(Color.black.opacity(0.08))
        }
    }

    private func settingsGroup<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        }
    }

    private func labeledInput<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
        }
    }

    private func presetBinding(_ keyPath: WritableKeyPath<TranslationProviderPresetConfiguration, String>) -> Binding<String> {
        Binding(
            get: { editingPresetConfiguration[keyPath: keyPath] },
            set: { newValue in
                providerSettings.updatePresetConfiguration(for: editingPresetID) { configuration in
                    configuration[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func presetBoolBinding(_ keyPath: WritableKeyPath<TranslationProviderPresetConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { editingPresetConfiguration[keyPath: keyPath] },
            set: { newValue in
                providerSettings.updatePresetConfiguration(for: editingPresetID) { configuration in
                    configuration[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func loadStoredCredentials() {
        openSubtitlesUsername = (try? credentialStore.load(account: "opensubtitles.username")) ?? ""
        openSubtitlesPassword = (try? credentialStore.load(account: "opensubtitles.password")) ?? ""
        openSubtitlesAPIKey = (try? credentialStore.load(account: "opensubtitles.apiKey")) ?? ""
        loadCurrentProviderAPIKey()
    }

    private func loadCurrentProviderAPIKey() {
        guard let account = editingPresetDescriptor.keychainAccount else {
            currentProviderAPIKey = ""
            return
        }
        currentProviderAPIKey = (try? credentialStore.load(account: account)) ?? ""
        if currentProviderAPIKey.isEmpty && account != "openai.apiKey" {
            currentProviderAPIKey = (try? credentialStore.load(account: "openai.apiKey")) ?? ""
        }
    }

    private func refreshProviderStatus() {
        if !providerStatusIsError {
            providerStatusMessage = ""
        }
    }

    private func saveOpenSubtitlesCredentials() {
        do {
            try credentialStore.save(openSubtitlesUsername, account: "opensubtitles.username")
            try credentialStore.save(openSubtitlesPassword, account: "opensubtitles.password")
            try credentialStore.save(openSubtitlesAPIKey, account: "opensubtitles.apiKey")
            openSubtitlesStatusMessage = "OpenSubtitles credentials saved to Keychain."
            openSubtitlesStatusIsError = false
        } catch {
            openSubtitlesStatusMessage = error.localizedDescription
            openSubtitlesStatusIsError = true
        }
    }

    private func saveProviderAPIKey() {
        guard let account = editingPresetDescriptor.keychainAccount else { return }
        do {
            try credentialStore.save(currentProviderAPIKey, account: account)
            providerStatusMessage = "\(editingPresetConfiguration.displayName) API key saved to Keychain."
            providerStatusIsError = false
        } catch {
            providerStatusMessage = error.localizedDescription
            providerStatusIsError = true
        }
    }
}
