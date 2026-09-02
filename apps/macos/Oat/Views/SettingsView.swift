import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var modelPendingDelete: LocalWhisperModel?

    var body: some View {
        @Bindable var appState = appState
        Form {
            if let error = appState.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("Folder") {
                    Text(folderLabel)
                        .foregroundStyle(appState.settings.storageDir == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
                Button("Browse…", action: appState.chooseFolder)
                    .oatGlassButtonStyle()
                if appState.settings.storageDir != nil {
                    Button("Show in Finder", action: appState.openStorageFolder)
                        .oatGlassButtonStyle()
                }
            } header: {
                Text("Folder")
            } footer: {
                Text("WAV files and transcripts are saved here. Nothing is hosted.")
            }

            Section {
                Picker("Engine", selection: $appState.settings.engine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .pickerStyle(.segmented)

                if appState.settings.engine == .local {
                    Picker("Model", selection: $appState.settings.localModel) {
                        ForEach(LocalWhisperModel.multilingual) { model in
                            Text(model.label).tag(model)
                        }
                        Divider()
                        ForEach(LocalWhisperModel.english) { model in
                            Text(model.label).tag(model)
                        }
                    }
                    Text(appState.settings.localModel.hint)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(appState.localModelReady ? "Downloaded" : "Not downloaded")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if appState.isDownloadingModel {
                            ProgressView(value: appState.modelDownloadProgress)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 120)
                            if let fraction = appState.modelDownloadProgress, fraction > 0 {
                                Text("\(Int(fraction * 100))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } else {
                            Button(appState.localModelReady ? "Re-download" : "Download") {
                                Task { await appState.downloadLocalModel() }
                            }
                            .controlSize(.small)
                            .oatGlassButtonStyle()
                            if appState.localModelReady {
                                Button("Delete", role: .destructive) {
                                    modelPendingDelete = appState.settings.localModel
                                }
                                .controlSize(.small)
                                .disabled(!appState.transcribing.isEmpty)
                            }
                        }
                    }
                    ForEach(otherDownloadedModels) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.label)
                                Text(model.hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Delete", role: .destructive) {
                                modelPendingDelete = model
                            }
                            .controlSize(.small)
                            .disabled(!appState.transcribing.isEmpty || appState.isDownloadingModel)
                        }
                    }
                } else if appState.settings.engine == .openai {
                    Picker("Model", selection: $appState.settings.model) {
                        ForEach(OpenAIModel.allCases) { model in
                            Text(model.label).tag(model.rawValue)
                        }
                    }
                    if let hint = OpenAIModel(rawValue: appState.settings.model)?.hint {
                        Text(hint)
                            .foregroundStyle(.secondary)
                    }
                    SecureField("API key", text: $appState.settings.apiKey, prompt: Text("sk-…"))
                }
            } header: {
                Text("Transcription")
            } footer: {
                switch appState.settings.engine {
                case .local:
                    Text("Whisper runs on this Mac. The first transcript downloads the selected model.")
                case .openai:
                    Text("Bring your own OpenAI key. Audio is sent to OpenAI; files stay on this Mac.")
                case .off:
                    Text("Recordings are saved as audio only. No transcript is written.")
                }
            }

            Section {
                if let permission = appState.permission {
                    permissionRow(
                        title: "Microphone",
                        systemImage: "mic.fill",
                        state: permission.microphone,
                        busy: appState.requestingMicrophone
                    ) {
                        Task { await appState.requestMicrophoneAccess() }
                    } openSettings: {
                        appState.openPrivacy(.microphone)
                    }

                    permissionRow(
                        title: "System audio",
                        systemImage: "speaker.wave.2.fill",
                        state: permission.systemAudio,
                        busy: appState.requestingSystemAudio
                    ) {
                        Task { await appState.requestSystemAudioAccess() }
                    } openSettings: {
                        appState.openPrivacy(.systemAudio)
                    }
                } else {
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Meeting audio uses System Audio Recording Only. Oat does not capture your screen.")
            }

            Section {
                LabeledContent("Version") {
                    Text(appState.currentVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                updateRow
            } header: {
                Text("Updates")
            } footer: {
                Text("Oat checks GitHub for new releases automatically.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.clear)
        .onChange(of: appState.settings.apiKey) { _, _ in
            appState.persistSettings()
        }
        .onChange(of: appState.settings.model) { _, _ in
            appState.persistSettings()
        }
        .onChange(of: appState.settings.engine) { _, _ in
            appState.persistSettings()
        }
        .onChange(of: appState.settings.localModel) { _, _ in
            appState.persistSettings()
        }
        .task {
            await appState.checkForUpdates()
        }
        .confirmationDialog(
            "Delete \(modelPendingDelete?.label ?? "model")?",
            isPresented: Binding(
                get: { modelPendingDelete != nil },
                set: { if !$0 { modelPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete model", role: .destructive) {
                if let model = modelPendingDelete {
                    Task { await appState.deleteLocalModel(model) }
                }
                modelPendingDelete = nil
            }
        } message: {
            Text("Removes the downloaded \(modelPendingDelete?.label ?? "Whisper") files from this Mac. You can download it again later.")
        }
    }

    private var folderLabel: String {
        guard let path = appState.settings.storageDir, !path.isEmpty else {
            return "Choose a folder"
        }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private var otherDownloadedModels: [LocalWhisperModel] {
        appState.downloadedLocalModels.filter { $0 != appState.settings.localModel }
    }

    @ViewBuilder
    private var updateRow: some View {
        switch appState.updateStatus {
        case .idle:
            Button("Check for Updates") {
                Task { await appState.checkForUpdates(userInitiated: true) }
            }
            .oatGlassButtonStyle()
        case .checking:
            HStack {
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        case .upToDate:
            HStack {
                Text("You’re up to date")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check") {
                    Task { await appState.checkForUpdates(userInitiated: true) }
                }
                .controlSize(.small)
                .oatGlassButtonStyle()
            }
        case .available(let update):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(update.version) is available")
                    Text("You’re on \(appState.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(update.downloadURL == nil ? "Open Release" : "Update") {
                    Task { await appState.installAvailableUpdate() }
                }
                .controlSize(.small)
                .oatGlassButtonStyle(prominent: true)
                .disabled(appState.isRecording)
            }
        case .downloading(let fraction):
            HStack {
                Text("Downloading…")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 120)
                if let fraction, fraction > 0 {
                    Text("\(Int(fraction * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        case .installing:
            HStack {
                Text("Installing…")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .foregroundStyle(.orange)
                HStack {
                    Button("Try again") {
                        Task { await appState.checkForUpdates(userInitiated: true) }
                    }
                    .controlSize(.small)
                    .oatGlassButtonStyle()
                    if appState.availableUpdate != nil {
                        Button("Update") {
                            Task { await appState.installAvailableUpdate() }
                        }
                        .controlSize(.small)
                        .oatGlassButtonStyle(prominent: true)
                        .disabled(appState.isRecording)
                    }
                }
            }
        }
    }

    private func permissionRow(
        title: String,
        systemImage: String,
        state: PermissionState,
        busy: Bool,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(permissionLabel(state))
                .foregroundStyle(.secondary)
            if state == .granted {
                Button("Settings", action: openSettings)
                    .controlSize(.small)
                    .oatGlassButtonStyle()
            } else {
                Button(busy ? "Requesting…" : actionTitle(state), action: state == .denied ? openSettings : request)
                    .controlSize(.small)
                    .oatGlassButtonStyle()
                    .disabled(busy || state == .unavailable)
            }
        }
    }

    private func actionTitle(_ state: PermissionState) -> String {
        switch state {
        case .notDetermined: return "Request"
        case .denied: return "Open Settings"
        case .unavailable: return "Unavailable"
        case .granted: return "Settings"
        }
    }

    private func permissionLabel(_ state: PermissionState) -> String {
        switch state {
        case .granted: return "Granted"
        case .denied: return "Not granted"
        case .notDetermined: return "Not requested"
        case .unavailable: return "Unavailable"
        }
    }
}
