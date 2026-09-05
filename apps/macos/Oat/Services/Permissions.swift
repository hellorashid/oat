import AppKit
import AVFoundation
import EventKit
import Foundation

enum PrivacyPane {
    case calendar
    case microphone
    case systemAudio
}

enum PermissionState: String, Equatable {
    case granted
    case denied
    case notDetermined = "not_determined"
    case unavailable
}

struct PermissionSnapshot: Equatable {
    var calendar: PermissionState
    var microphone: PermissionState
    var systemAudio: PermissionState
}

enum Permissions {
    static let systemAudioHelp =
        "System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only"

    private static let lock = NSLock()
    private static var cachedSystemAudio: PermissionState = .notDetermined

    static func snapshot() async -> PermissionSnapshot {
        PermissionSnapshot(
            calendar: calendarState(),
            microphone: microphoneState(),
            systemAudio: systemAudioState()
        )
    }

    static func calendarState() -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return .granted
        case .denied, .restricted, .writeOnly:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable
        }
    }

    static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable
        }
    }

    static func systemAudioState() -> PermissionState {
        if #unavailable(macOS 14.2) {
            return .unavailable
        }
        lock.lock()
        defer { lock.unlock() }
        return cachedSystemAudio
    }

    static func markSystemAudio(_ state: PermissionState) {
        lock.lock()
        cachedSystemAudio = state
        lock.unlock()
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    @discardableResult
    static func requestSystemAudio() async -> PermissionState {
        let state = await SystemAudioCapture.probe()
        markSystemAudio(state)
        return state
    }

    static func open(_ pane: PrivacyPane) {
        let urls: [String]
        switch pane {
        case .calendar:
            urls = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
            ]
        case .microphone:
            urls = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            ]
        case .systemAudio:
            urls = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            ]
        }
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
