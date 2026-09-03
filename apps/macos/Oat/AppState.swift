import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum Tab: String {
        case recordings
        case settings
    }

    var tab: Tab = .recordings
    var settings = Settings()
    var recordings: [Recording] = []
    var isRecording = false
    var recordingId: String?
    var elapsedMs = 0
    var meterLevel: Float = 0
    var transcribing: Set<String> = []
    var errorMessage: String?
    var permission: PermissionSnapshot?
    var requestingMicrophone = false
    var requestingSystemAudio = false
    var localModelReady = false
    var downloadedLocalModels: [LocalWhisperModel] = []
    var isDownloadingModel = false
    var modelDownloadProgress: Double?
    var updateStatus: UpdateStatus = .idle

    private let store = SettingsStore()
    private let recorder = Recorder()
    private var elapsedTask: Task<Void, Never>?
    private var lastRecordedAt: Date?
    private var lastUpdateCheck: Date?
    private var updateCheckTask: Task<Void, Never>?
    private var pendingUpdate: AppUpdate?
    private var isCheckingUpdates = false
    private var libraryGeneration = 0
    private var didActivate = false

    var canRecord: Bool { settings.storageURL != nil }
    var currentVersion: String { Updater.currentVersion }
    var availableUpdate: AppUpdate? { pendingUpdate }
    var canInstallUpdate: Bool {
        guard pendingUpdate != nil else { return false }
        switch updateStatus {
        case .downloading, .installing: return false
        default: return true
        }
    }

    init() {
        settings = store.load()
        if OpenAIModel(rawValue: settings.model) == nil {
            settings.model = OpenAIModel.gpt4oMiniTranscribe.rawValue
        }
        settings.provider = .openai
        if settings.storageURL == nil {
            tab = .settings
        }
    }

    /// Runs once after the UI is up: library scan, permissions, and background update checks.
    func activate() {
        guard !didActivate else { return }
        didActivate = true
        refreshLibrary()
        Task { await refreshPermissions() }
        if settings.engine == .local || tab == .settings {
            refreshLocalModelStatus()
        }
        startUpdateChecks()
        if tab == .settings {
            Task { await checkForUpdates() }
        }
    }

    func prepareSettings() {
        // Defer past the tab-switch frame so the segmented control can settle
        // before we touch the filesystem / network on the main actor.
        Task {
            await Task.yield()
            refreshLocalModelStatus()
            await refreshPermissions()
            await checkForUpdates()
        }
    }

    func refreshLibrary() {
        guard let directory = settings.storageURL else {
            recordings = []
            return
        }
        libraryGeneration += 1
        let generation = libraryGeneration
        let transcribing = transcribing
        Task {
            let fastItems = await Task.detached {
                Library.list(in: directory, transcribing: transcribing, includeDurations: false)
            }.value
            guard generation == libraryGeneration else { return }
            recordings = fastItems

            let fullItems = await Task.detached {
                Library.list(in: directory, transcribing: transcribing, includeDurations: true)
            }.value
            guard generation == libraryGeneration else { return }
            recordings = fullItems
        }
    }

    func refreshPermissions() async {
        permission = await Permissions.snapshot()
    }

    func toggleRecording() async {
        errorMessage = nil
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func chooseFolder() {
        errorMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for recordings and transcripts."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.storageDir = url.path
        do {
            try store.save(settings)
            refreshLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openStorageFolder() {
        guard let url = settings.storageURL else { return }
        NSWorkspace.shared.open(url)
    }

    func persistSettings() {
        errorMessage = nil
        var snapshot = settings
        snapshot.provider = .openai
        snapshot.baseURL = ""
        do {
            try store.save(snapshot)
            if snapshot.engine == .local {
                refreshLocalModelStatus()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLocalModelStatus() {
        localModelReady = LocalWhisperStorage.isDownloaded(settings.localModel)
        downloadedLocalModels = LocalWhisperStorage.downloadedModels()
    }

    func downloadLocalModel() async {
        guard !isDownloadingModel else { return }
        errorMessage = nil
        isDownloadingModel = true
        modelDownloadProgress = 0
        do {
            try await LocalWhisper.shared.download(settings.localModel) { [weak self] fraction in
                Task { @MainActor in
                    self?.modelDownloadProgress = fraction
                }
            }
            refreshLocalModelStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
        isDownloadingModel = false
        modelDownloadProgress = nil
    }

    func deleteLocalModel(_ model: LocalWhisperModel? = nil) async {
        guard !isDownloadingModel, transcribing.isEmpty else { return }
        errorMessage = nil
        do {
            try await LocalWhisper.shared.delete(model ?? settings.localModel)
            refreshLocalModelStatus()
        } catch {
            errorMessage = error.localizedDescription
            refreshLocalModelStatus()
        }
    }

    func revealAudio(_ recording: Recording) {
        Library.revealAudio(recording)
    }

    func revealTranscript(_ recording: Recording) {
        Library.revealTranscript(recording)
    }

    func openTranscript(_ recording: Recording) {
        Library.openTranscript(recording)
    }

    func retryTranscription(_ recording: Recording) {
        Task { await transcribe(id: recording.id, recordedAt: recording.createdAt, stats: nil) }
    }

    func delete(_ recording: Recording) {
        guard recording.id != recordingId else { return }
        Library.delete(recording)
        transcribing.remove(recording.id)
        refreshLibrary()
    }

    func requestMicrophoneAccess() async {
        requestingMicrophone = true
        errorMessage = nil
        _ = await Permissions.requestMicrophone()
        permission = await Permissions.snapshot()
        requestingMicrophone = false
    }

    func requestSystemAudioAccess() async {
        requestingSystemAudio = true
        errorMessage = nil
        let system = await Permissions.requestSystemAudio()
        permission = await Permissions.snapshot()
        if system != .granted {
            errorMessage = "Allow Oat under \(Permissions.systemAudioHelp)."
        }
        requestingSystemAudio = false
    }

    func openPrivacy(_ pane: PrivacyPane) {
        Permissions.open(pane)
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refreshPermissions()
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func checkForUpdates(userInitiated: Bool = false) async {
        if isCheckingUpdates { return }
        if case .downloading = updateStatus { return }
        if case .installing = updateStatus { return }
        if !userInitiated, let lastUpdateCheck, Date().timeIntervalSince(lastUpdateCheck) < 10 * 60 {
            return
        }

        isCheckingUpdates = true
        if userInitiated || pendingUpdate == nil {
            updateStatus = .checking
        }
        defer { isCheckingUpdates = false }

        do {
            lastUpdateCheck = Date()
            if let update = try await Updater.check() {
                pendingUpdate = update
                updateStatus = .available(update)
            } else {
                pendingUpdate = nil
                updateStatus = .upToDate
            }
        } catch {
            if userInitiated {
                updateStatus = .failed(error.localizedDescription)
            } else if let update = pendingUpdate {
                updateStatus = .available(update)
            } else {
                updateStatus = .idle
            }
        }
    }

    func installAvailableUpdate() async {
        guard let update = pendingUpdate else { return }
        if isRecording {
            errorMessage = "Stop recording before updating."
            return
        }
        guard update.downloadURL != nil else {
            Updater.openRelease(update)
            return
        }

        updateStatus = .downloading(0)
        do {
            let package = try await Updater.download(update) { [weak self] fraction in
                Task { @MainActor in
                    self?.updateStatus = .downloading(fraction)
                }
            }
            updateStatus = .installing
            try Updater.install(from: package)
        } catch {
            updateStatus = .failed(error.localizedDescription)
        }
    }

    private func startUpdateChecks() {
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            // Let the window appear before hitting the network.
            try? await Task.sleep(for: .seconds(45))
            await self?.checkForUpdates()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                await self?.checkForUpdates()
            }
        }
    }

    private func startRecording() async {
        guard let directory = settings.storageURL else {
            errorMessage = "Choose a folder for recordings in Settings"
            tab = .settings
            AppWindow.show()
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        _ = await Permissions.requestMicrophone()
        let id = RecordingId.make()
        let url = directory.appendingPathComponent("\(id).wav")
        do {
            if let warning = try await recorder.start(to: url) {
                errorMessage = warning
            }
            recordingId = id
            lastRecordedAt = Date()
            isRecording = true
            startElapsed()
            refreshLibrary()
        } catch {
            errorMessage = error.localizedDescription
            isRecording = false
        }
    }

    private func stopRecording() async {
        let id = recordingId
        let recordedAt = lastRecordedAt ?? Date()
        stopElapsed()
        isRecording = false
        do {
            let stats = try await recorder.stop()
            recordingId = nil
            refreshLibrary()
            if let id {
                await transcribe(id: id, recordedAt: recordedAt, stats: stats)
            }
        } catch {
            errorMessage = error.localizedDescription
            recordingId = nil
            refreshLibrary()
        }
    }

    private func transcribe(id: String, recordedAt: Date, stats: MixStats?) async {
        guard settings.engine != .off else { return }
        guard let directory = settings.storageURL else { return }
        let wavURL = directory.appendingPathComponent("\(id).wav")
        transcribing.insert(id)
        Library.clearError(directory: directory, id: id)
        refreshLibrary()

        do {
            let transcript = try await Transcriber.transcribe(wav: wavURL, settings: settings)
            let duration = stats?.durationSeconds ?? WavIO.durationSeconds(at: wavURL) ?? 0
            let context = TranscriptContext(
                id: id,
                recordedAt: recordedAt,
                durationSeconds: duration,
                audioFilename: wavURL.lastPathComponent,
                microphone: stats?.microphone,
                system: stats?.system
            )
            let markdown = Markdown.render(context: context, transcript: transcript)
            let mdURL = directory.appendingPathComponent("\(id).md")
            try markdown.write(to: mdURL, atomically: true, encoding: .utf8)
            refreshLocalModelStatus()
        } catch {
            Library.writeError(directory: directory, id: id, message: error.localizedDescription)
        }

        transcribing.remove(id)
        refreshLibrary()
    }

    private func startElapsed() {
        elapsedMs = 0
        meterLevel = 0
        let started = Date()
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                self.meterLevel = self.recorder.meterLevel()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopElapsed() {
        elapsedTask?.cancel()
        elapsedTask = nil
        elapsedMs = 0
        meterLevel = 0
    }
}
