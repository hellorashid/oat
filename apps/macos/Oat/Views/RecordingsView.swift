import SwiftUI

struct RecordingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            RecordHeader()
            Divider().opacity(0.35)
            RecordingsLibrary()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.clear)
    }
}

private struct RecordHeader: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 10) {
            OatGlassContainer {
                Button {
                    Task { await appState.toggleRecording() }
                } label: {
                    Image(systemName: appState.isRecording ? "stop.fill" : "circle.fill")
                        .font(.system(size: appState.isRecording ? 13 : 14, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: appState.isRecording)
                        .frame(width: 52, height: 52)
                }
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .oatGlassButtonStyle(prominent: true)
                .tint(appState.isRecording ? Color.red : Color.accentColor)
                .disabled(!appState.canRecord && !appState.isRecording)
                .opacity((!appState.canRecord && !appState.isRecording) ? 0.45 : 1)
                .help(appState.isRecording ? "Stop recording" : "Start recording")
            }

            Text(appState.isRecording ? Markdown.formatElapsed(appState.elapsedMs) : "Start recording")
                .font(.body)
                .foregroundStyle(.primary)

            if appState.isRecording {
                MicMeterView(level: appState.meterLevel)
                    .frame(width: 52, height: 22)
            }

            if let error = appState.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .oatGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}

private struct RecordingsLibrary: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.recordings.isEmpty {
            ContentUnavailableView {
                Label("Library", systemImage: "waveform")
            } description: {
                Text("Nothing here yet. Start a recording and Oat will keep the audio and markdown in your chosen folder.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(appState.recordings.enumerated()), id: \.element.id) { index, item in
                        RecordingRow(item: item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        if index < appState.recordings.count - 1 {
                            Divider()
                                .opacity(0.28)
                                .padding(.leading, 16)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
        }
    }
}

private struct RecordingRow: View {
    @Environment(AppState.self) private var appState
    let item: Recording
    @State private var confirmDelete = false
    @State private var deleteHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(item.durationSeconds.map(Markdown.formatDuration) ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                actions
                if item.id != appState.recordingId, let duration = item.durationSeconds, duration > 0 {
                    WaveformView(url: item.wavURL, durationSeconds: duration)
                        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 32)
                } else {
                    Spacer(minLength: 0)
                }
            }

            if item.status == .transcribing {
                Text("transcribing")
                    .font(.caption)
                    .foregroundStyle(.accent)
            }
            if let error = item.error, item.status == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .contextMenu {
            Button("Show audio in Finder") {
                appState.revealAudio(item)
            }
            Menu("Transcript") {
                Button("Retry transcription") {
                    retryTranscription()
                }
                .disabled(!canRetry)
                Button("Show in Finder") {
                    appState.revealTranscript(item)
                }
                .disabled(item.markdownURL == nil)
                Button("Open in Markdown app") {
                    appState.openTranscript(item)
                }
                .disabled(item.markdownURL == nil)
            }
            Divider()
            Button("Delete", role: .destructive) {
                confirmDelete = true
            }
            .disabled(!canDelete)
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                appState.delete(item)
            }
        } message: {
            Text("This removes the audio and transcript from your folder.")
        }
    }

    private var actions: some View {
        OatGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    appState.revealAudio(item)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.body.weight(.semibold))
                        .padding(.leading, 1)
                }
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .oatGlassButtonStyle()
                .help("Show audio in Finder")

                Menu {
                    Button("Retry transcription", systemImage: "arrow.clockwise") {
                        retryTranscription()
                    }
                    .disabled(!canRetry)
                    Button("Show in Finder", systemImage: "folder") {
                        appState.revealTranscript(item)
                    }
                    .disabled(item.markdownURL == nil)
                    Button("Open in Markdown app", systemImage: "arrow.up.forward") {
                        appState.openTranscript(item)
                    }
                    .disabled(item.markdownURL == nil)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text")
                        Text("Transcript")
                    }
                }
                .menuIndicator(.visible)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .oatGlassButtonStyle()
                .fixedSize()
                .help("Transcript")

                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .oatGlassButtonStyle()
                .foregroundStyle(deleteHovered ? Color.red : Color.primary)
                .disabled(!canDelete)
                .onHover { hovering in
                    deleteHovered = hovering && canDelete
                }
            }
        }
    }

    private func retryTranscription() {
        if item.status == .needsKey, appState.settings.engine == .openai, !appState.settings.hasAPIKey {
            appState.tab = .settings
            return
        }
        appState.retryTranscription(item)
    }

    private var canRetry: Bool {
        appState.settings.engine != .off
            && item.status != .transcribing
            && item.id != appState.recordingId
    }

    private var canDelete: Bool {
        item.id != appState.recordingId && item.status != .transcribing
    }
}
